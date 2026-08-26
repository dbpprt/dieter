package remotedesktop

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/trust"
	"github.com/pion/rtcp"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"google.golang.org/protobuf/proto"
)

const (
	maxSDPBytes          = 256 << 10
	maxCandidateBytes    = 4 << 10
	maxInitialCandidates = 64
	maxSignalHistory     = 96
	maxSubscribers       = 4
	defaultSessionLease  = 15 * time.Second
	defaultDetachGrace   = 5 * time.Second
)

var (
	ErrDisabled        = errors.New("remote desktop is disabled")
	ErrControlDisabled = errors.New("remote desktop control is disabled")
	ErrBusy            = errors.New("another remote desktop session is active")
	ErrNotFound        = errors.New("remote desktop session not found")
	ErrInvalidSignal   = errors.New("invalid remote desktop signal")
)

type Identity struct {
	DaemonID                string
	GatewayURL              string
	Generation              uint64
	PrivateKey              ed25519.PrivateKey
	GatewaySigningPublicKey []byte
}

type Options struct {
	Identity        Identity
	Source          SourceOptions
	SessionLease    time.Duration
	DetachGrace     time.Duration
	MonitorInterval time.Duration
	CaptureProbe    func(context.Context, SourceOptions) error
	ControlProbe    func(context.Context, SourceOptions, bool) error
	SourceFactory   func(SourceOptions) (FrameSource, error)
	Logger          *slog.Logger
	Now             func() time.Time
}

type Manager struct {
	options      Options
	mu           sync.Mutex
	session      *Session
	probeMu      sync.Mutex
	probe        captureProbeResult
	controlProbe captureProbeResult
}

type captureProbeResult struct {
	permission string
	reason     string
	checkedAt  time.Time
}

type Subscription struct {
	SessionID string
	Signals   <-chan *dieterv1.RemoteDesktopSignal
	close     func()
	once      sync.Once
}

func (s *Subscription) Close() {
	if s != nil {
		s.once.Do(s.close)
	}
}

func New(options Options) *Manager {
	if options.SessionLease <= 0 {
		options.SessionLease = defaultSessionLease
	}
	if options.DetachGrace <= 0 {
		options.DetachGrace = defaultDetachGrace
	}
	if options.MonitorInterval <= 0 {
		options.MonitorInterval = time.Second
	}
	if options.CaptureProbe == nil {
		options.CaptureProbe = ProbeCapture
	}
	if options.ControlProbe == nil {
		options.ControlProbe = ProbeControl
	}
	if options.SourceFactory == nil {
		options.SourceFactory = NewFrameSource
	}
	if options.Logger == nil {
		options.Logger = slog.Default()
	}
	if options.Now == nil {
		options.Now = time.Now
	}
	return &Manager{options: options}
}

func (m *Manager) Capabilities(enabled, controlEnabled bool) *dieterv1.RemoteDesktopCapabilities {
	return m.capabilities(enabled, controlEnabled, false)
}

func (m *Manager) capabilities(enabled, controlEnabled, forceProbe bool) *dieterv1.RemoteDesktopCapabilities {
	available, reason := SourceAvailable(m.options.Source)
	m.mu.Lock()
	session := m.session
	m.mu.Unlock()
	active := false
	if session != nil {
		session.mu.Lock()
		active = !session.closed
		session.mu.Unlock()
	}
	permission := "unknown"
	if strings.TrimSpace(m.options.Source.Kind) == "synthetic" {
		permission = "granted"
	} else if enabled && available {
		permission, reason = m.captureReadiness(forceProbe)
	}
	controlSupported := runtime.GOOS == "darwin" || strings.TrimSpace(m.options.Source.Kind) == "synthetic"
	controlPermission := "not_requested"
	if controlEnabled && controlSupported {
		controlPermission, _ = m.controlReadiness(false)
	} else if !controlSupported {
		controlPermission = "unsupported"
	}
	ready := enabled && available && permission == "granted" && m.options.Identity.DaemonID != "" && len(m.options.Identity.PrivateKey) == ed25519.PrivateKeySize
	if !enabled {
		reason = "Remote desktop is disabled on this machine"
	} else if !available {
		// SourceAvailable already supplied the actionable dependency/session reason.
	} else if permission != "granted" {
		if reason == "" {
			reason = "Screen capture permission has not been verified"
		}
	} else if m.options.Identity.DaemonID == "" {
		reason = "The daemon is not enrolled"
	}
	return &dieterv1.RemoteDesktopCapabilities{
		Platform: runtime.GOOS, GraphicalSessionActive: available, Enabled: enabled,
		Ready: ready, UnavailableReason: reason, HelperVersion: remoteDesktopHelperVersion(m.options.Source),
		CapturePermission: permission, ControlPermission: controlPermission,
		Displays: []*dieterv1.RemoteDesktopDisplay{{Id: "primary", Name: "Primary display", Primary: true, Scale: 1}},
		Codecs:   []string{string(preferredVideoCodec(m.options.Source))}, HardwareEncoderAvailable: runtime.GOOS == "darwin" && strings.TrimSpace(m.options.Source.Kind) != "synthetic",
		ControlSupported: controlSupported, ClipboardSupported: false,
		AudioSupported: false, FileTransferSupported: false, ActiveSession: active,
	}
}

func (m *Manager) captureReadiness(force bool) (string, string) {
	m.probeMu.Lock()
	defer m.probeMu.Unlock()
	now := m.options.Now().UTC()
	if !force && m.probe.permission != "" {
		return m.probe.permission, m.probe.reason
	}
	ctx, cancel := context.WithTimeout(context.Background(), captureProbeTimeout+time.Second)
	defer cancel()
	result := captureProbeResult{permission: "granted", checkedAt: now}
	if err := m.options.CaptureProbe(ctx, m.options.Source); err != nil {
		result.permission = "denied"
		result.reason = err.Error()
		m.options.Logger.Warn("remote desktop capture readiness check failed", "error", err)
	}
	m.probe = result
	return result.permission, result.reason
}

func (m *Manager) controlReadiness(force bool) (string, string) {
	m.probeMu.Lock()
	defer m.probeMu.Unlock()
	if !force && m.controlProbe.permission != "" {
		return m.controlProbe.permission, m.controlProbe.reason
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	result := captureProbeResult{permission: "granted", checkedAt: m.options.Now().UTC()}
	if err := m.options.ControlProbe(ctx, m.options.Source, false); err != nil {
		result.permission = "denied"
		result.reason = err.Error()
	}
	m.controlProbe = result
	return result.permission, result.reason
}

func (m *Manager) Start(request *dieterv1.StartRemoteDesktopRequest, enabled, controlEnabled bool, operatorSubject string) (*Subscription, error) {
	if !enabled {
		return nil, ErrDisabled
	}
	if request.GetControl() && !controlEnabled {
		return nil, ErrControlDisabled
	}
	if err := validateStartRequest(request); err != nil {
		return nil, err
	}

	m.mu.Lock()
	if current := m.session; current != nil && current.active() {
		offerHash := sha256.Sum256([]byte(request.GetOffer().GetSdp()))
		if current.clientNonce != request.GetClientNonce() || current.operatorSubject != operatorSubject || current.offerHash != offerHash || current.control != request.GetControl() || current.displayID != normalizedDisplayID(request.GetDisplayId()) {
			m.mu.Unlock()
			return nil, ErrBusy
		}
		subscription, err := current.subscribe(m.options.Now())
		m.mu.Unlock()
		return subscription, err
	}
	m.mu.Unlock()
	// Capabilities probes the exact production capture path once per daemon
	// lifetime. Reusing that result here avoids opening and encoding the screen
	// twice immediately before every session; the real stream still reports any
	// permission or device change when it starts.
	capabilities := m.capabilities(enabled, controlEnabled, false)
	if !capabilities.GetReady() {
		return nil, errors.New(capabilities.GetUnavailableReason())
	}
	controlPermission := capabilities.GetControlPermission()
	if request.GetControl() {
		controlPermission, _ = m.controlReadiness(true)
	}
	if request.GetControl() && (!capabilities.GetControlSupported() || controlPermission != "granted") {
		return nil, errors.New("remote desktop control requires macOS Accessibility permission; run `dieter daemon permissions`")
	}
	if _, err := m.verifyRTCConfiguration(request.GetRtcConfiguration(), operatorSubject); err != nil {
		return nil, err
	}

	session, err := newSession(m, request, operatorSubject)
	if err != nil {
		return nil, err
	}
	m.mu.Lock()
	if current := m.session; current != nil && current.active() {
		m.mu.Unlock()
		session.close("replaced before admission")
		return nil, ErrBusy
	}
	m.session = session
	subscription, err := session.subscribe(m.options.Now())
	m.mu.Unlock()
	if err != nil {
		session.close(err.Error())
		return nil, err
	}
	go session.monitor()
	return subscription, nil
}

func (m *Manager) Signal(value *dieterv1.RemoteDesktopSignal) error {
	m.mu.Lock()
	session := m.session
	m.mu.Unlock()
	if session == nil || session.id != strings.TrimSpace(value.GetSessionId()) {
		return ErrNotFound
	}
	return session.signal(value)
}

func (m *Manager) Close(id, reason string) error {
	m.mu.Lock()
	session := m.session
	m.mu.Unlock()
	if session == nil || session.id != strings.TrimSpace(id) {
		return nil
	}
	session.close(reason)
	return nil
}

func (m *Manager) CloseActive(reason string) {
	m.mu.Lock()
	session := m.session
	m.mu.Unlock()
	if session != nil {
		session.close(reason)
	}
}

func (m *Manager) CloseControlActive(reason string) {
	m.mu.Lock()
	session := m.session
	m.mu.Unlock()
	if session != nil && session.control {
		session.close(reason)
	}
}

func (m *Manager) Shutdown(context.Context) { m.CloseActive("daemon shutdown") }

func (m *Manager) Presence(enabled, controlEnabled bool) *gatewayv1.RemoteDesktopPresence {
	capabilities := m.Capabilities(enabled, controlEnabled)
	return &gatewayv1.RemoteDesktopPresence{
		Platform: capabilities.GetPlatform(), HelperVersion: capabilities.GetHelperVersion(),
		Ready: capabilities.GetReady(), Reason: capabilities.GetUnavailableReason(),
		ActiveSession: capabilities.GetActiveSession(),
	}
}

func (m *Manager) clear(session *Session) {
	m.mu.Lock()
	if m.session == session {
		m.session = nil
	}
	m.mu.Unlock()
}

func (m *Manager) verifyRTCConfiguration(configuration *gatewayv1.RTCConfiguration, operatorSubject string) (trust.RTCConfigurationClaims, error) {
	var claims trust.RTCConfigurationClaims
	if strings.TrimSpace(operatorSubject) == "" || configuration.GetOperatorSubject() != operatorSubject {
		return claims, errors.New("RTC configuration belongs to another operator")
	}
	if configuration == nil || configuration.GetDaemonId() != m.options.Identity.DaemonID || configuration.GetDaemonGeneration() != m.options.Identity.Generation {
		return claims, errors.New("RTC configuration targets another daemon")
	}
	copy := proto.Clone(configuration).(*gatewayv1.RTCConfiguration)
	copy.SignedEnvelope = nil
	raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(copy)
	if err != nil {
		return claims, err
	}
	digest := sha256.Sum256(raw)
	public, err := trust.PublicKeyFromPEM(m.options.Identity.GatewaySigningPublicKey)
	if err != nil {
		return claims, errors.New("gateway signing key is invalid")
	}
	claims, err = trust.ParseAndVerifyRTCConfiguration(
		public, string(configuration.GetSignedEnvelope()), m.options.Identity.GatewayURL,
		m.options.Identity.DaemonID, configuration.GetOperatorSubject(), configuration.GetConfigurationId(),
		digest[:], m.options.Identity.Generation, m.options.Now().UTC(),
	)
	if err != nil {
		return claims, fmt.Errorf("verify RTC configuration: %w", err)
	}
	return claims, nil
}

type Session struct {
	manager         *Manager
	id              string
	clientNonce     string
	operatorSubject string
	offerHash       [sha256.Size]byte
	pc              *webrtc.PeerConnection
	track           *webrtc.TrackLocalStaticSample
	source          FrameSource
	codec           VideoCodec
	ctx             context.Context
	cancel          context.CancelFunc
	startOnce       sync.Once
	closeOnce       sync.Once

	mu                   sync.Mutex
	closed               bool
	sequence             uint64
	history              []*dieterv1.RemoteDesktopSignal
	subscribers          map[uint64]chan *dieterv1.RemoteDesktopSignal
	nextSubscriber       uint64
	leaseExpiresAt       time.Time
	detachedAt           time.Time
	peerDetachedAt       time.Time
	control              bool
	displayID            string
	inputEpoch           []byte
	pointerInputSequence atomic.Uint64
	stateInputSequence   atomic.Uint64
	pointerInput         chan *dieterv1.RemoteDesktopInput
	stateInput           chan *dieterv1.RemoteDesktopInput
}

func (s *Session) active() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return !s.closed
}

func newSession(manager *Manager, request *dieterv1.StartRemoteDesktopRequest, operatorSubject string) (*Session, error) {
	sourceOptions := manager.options.Source
	if request.GetDisplayId() != "" {
		sourceOptions.Display = request.GetDisplayId()
	}
	if request.GetMaxFps() > 0 {
		sourceOptions.FPS = int(request.GetMaxFps())
	}
	if request.GetMaxBitrateKbps() > 0 {
		sourceOptions.Bitrate = int(request.GetMaxBitrateKbps())
	}
	if request.GetMaxWidth() > 0 {
		sourceOptions.MaxWidth = int(request.GetMaxWidth())
	}
	if request.GetMaxHeight() > 0 {
		sourceOptions.MaxHeight = int(request.GetMaxHeight())
	}
	source, err := manager.options.SourceFactory(sourceOptions)
	if err != nil {
		return nil, err
	}
	if request.GetControl() {
		if _, ok := source.(InputSink); !ok {
			return nil, errors.New("remote desktop capture source does not support control")
		}
	}
	iceServers := make([]webrtc.ICEServer, 0, len(request.GetRtcConfiguration().GetIceServers()))
	for _, server := range request.GetRtcConfiguration().GetIceServers() {
		iceServers = append(iceServers, webrtc.ICEServer{URLs: append([]string(nil), server.GetUrls()...), Username: server.GetUsername(), Credential: server.GetCredential()})
	}
	settingEngine := webrtc.SettingEngine{}
	settingEngine.SetIncludeLoopbackCandidate(true)
	api := webrtc.NewAPI(webrtc.WithSettingEngine(settingEngine))
	pc, err := api.NewPeerConnection(webrtc.Configuration{ICEServers: iceServers})
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	now := manager.options.Now().UTC()
	offerHash := sha256.Sum256([]byte(request.GetOffer().GetSdp()))
	session := &Session{
		manager: manager, id: randomID(), clientNonce: request.GetClientNonce(), operatorSubject: operatorSubject, pc: pc,
		ctx: ctx, cancel: cancel, subscribers: make(map[uint64]chan *dieterv1.RemoteDesktopSignal),
		leaseExpiresAt: now.Add(manager.options.SessionLease), offerHash: offerHash,
		source: source, codec: source.Codec(), control: request.GetControl(), displayID: normalizedDisplayID(sourceOptions.Display), inputEpoch: randomBytes(16),
		pointerInput: make(chan *dieterv1.RemoteDesktopInput, 1), stateInput: make(chan *dieterv1.RemoteDesktopInput, 128),
	}
	fail := func(cause error) (*Session, error) {
		session.close(cause.Error())
		return nil, cause
	}
	track, err := webrtc.NewTrackLocalStaticSample(codecCapability(source.Codec()), "screen", "dieter-remote-desktop")
	if err != nil {
		return fail(err)
	}
	session.track = track
	sender, err := pc.AddTrack(track)
	if err != nil {
		return fail(err)
	}
	go handleRTCP(sender, source, manager.options.Logger)
	session.installInputChannels()
	go session.runInput()

	pc.OnICECandidate(func(candidate *webrtc.ICECandidate) {
		if candidate == nil {
			return
		}
		value := candidate.ToJSON()
		var index int32
		if value.SDPMLineIndex != nil {
			index = int32(*value.SDPMLineIndex)
		}
		session.emit(&dieterv1.RemoteDesktopSignal{Payload: &dieterv1.RemoteDesktopSignal_Candidate{Candidate: &dieterv1.RemoteDesktopICECandidate{
			Candidate: value.Candidate, SdpMid: stringValue(value.SDPMid), SdpMlineIndex: index, UsernameFragment: stringValue(value.UsernameFragment),
		}}})
	})
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		switch state {
		case webrtc.PeerConnectionStateConnected:
			session.mu.Lock()
			session.peerDetachedAt = time.Time{}
			session.mu.Unlock()
			session.emitState("streaming", "")
			session.startOnce.Do(func() { go session.streamSource(request) })
		case webrtc.PeerConnectionStateDisconnected:
			session.releaseInput()
			session.mu.Lock()
			if session.peerDetachedAt.IsZero() {
				session.peerDetachedAt = manager.options.Now().UTC()
			}
			session.mu.Unlock()
			session.emitState("reconnecting", "ICE disconnected")
		case webrtc.PeerConnectionStateFailed:
			session.emitError("peer_failed", "WebRTC peer connection failed", false)
			session.close("peer connection failed")
		case webrtc.PeerConnectionStateClosed:
			session.close("peer connection closed")
		default:
			session.emitState(state.String(), "")
		}
	})

	if err := pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: request.GetOffer().GetSdp()}); err != nil {
		return fail(fmt.Errorf("set remote desktop offer: %w", err))
	}
	for _, candidate := range request.GetInitialCandidates() {
		if err := pc.AddICECandidate(candidateInit(candidate)); err != nil {
			return fail(fmt.Errorf("add initial ICE candidate: %w", err))
		}
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		return fail(err)
	}
	if err := pc.SetLocalDescription(answer); err != nil {
		return fail(err)
	}
	local := pc.LocalDescription()
	if local == nil {
		return fail(errors.New("local remote desktop description is missing"))
	}
	fingerprint := sdpFingerprint(local.SDP)
	expiresAt := session.leaseExpiresAt.Format(time.RFC3339Nano)
	bindingMessage := SessionBindingMessage(session.id, session.clientNonce, fingerprint, expiresAt, offerHash[:], session.control, session.displayID, inputProtocolVersion, session.inputEpoch)
	signature := ed25519.Sign(manager.options.Identity.PrivateKey, bindingMessage)
	session.emit(&dieterv1.RemoteDesktopSignal{Payload: &dieterv1.RemoteDesktopSignal_Binding{Binding: &dieterv1.RemoteDesktopSessionBinding{
		ClientNonce: session.clientNonce, HelperDtlsFingerprint: fingerprint, ExpiresAt: expiresAt,
		OfferSha256: offerHash[:], DaemonSignature: signature, ControlGranted: session.control,
		DisplayId: session.displayID, InputProtocolVersion: inputProtocolVersion, InputEpoch: session.inputEpoch,
	}}})
	session.emit(&dieterv1.RemoteDesktopSignal{Payload: &dieterv1.RemoteDesktopSignal_Description{Description: &dieterv1.RemoteDesktopSessionDescription{Type: "answer", Sdp: local.SDP}}})
	session.emitState("connecting", "")
	return session, nil
}

func stringValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func normalizedDisplayID(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return "primary"
	}
	return value
}

func validateStartRequest(request *dieterv1.StartRemoteDesktopRequest) error {
	if request == nil || strings.TrimSpace(request.GetClientNonce()) == "" || len(request.GetClientNonce()) > 128 {
		return errors.New("client_nonce is required and must be at most 128 bytes")
	}
	if request.GetOffer().GetType() != "offer" || strings.TrimSpace(request.GetOffer().GetSdp()) == "" || len(request.GetOffer().GetSdp()) > maxSDPBytes {
		return errors.New("a bounded SDP offer is required")
	}
	if len(request.GetInitialCandidates()) > maxInitialCandidates {
		return errors.New("too many initial ICE candidates")
	}
	for _, candidate := range request.GetInitialCandidates() {
		if len(candidate.GetCandidate()) > maxCandidateBytes {
			return errors.New("initial ICE candidate is too large")
		}
	}
	if fps := request.GetMaxFps(); fps < 0 || fps > 120 {
		return errors.New("max_fps must be at most 120")
	}
	if bitrate := request.GetMaxBitrateKbps(); bitrate < 0 || bitrate > 100_000 {
		return errors.New("max_bitrate_kbps must be at most 100000")
	}
	if width := request.GetMaxWidth(); width != 0 && (width < 320 || width > 16_384) {
		return errors.New("max_width must be zero or between 320 and 16384")
	}
	if height := request.GetMaxHeight(); height != 0 && (height < 180 || height > 16_384) {
		return errors.New("max_height must be zero or between 180 and 16384")
	}
	return nil
}

func (s *Session) subscribe(now time.Time) (*Subscription, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return nil, ErrNotFound
	}
	if len(s.subscribers) >= maxSubscribers {
		return nil, errors.New("too many remote desktop observers")
	}
	s.nextSubscriber++
	id := s.nextSubscriber
	channel := make(chan *dieterv1.RemoteDesktopSignal, maxSignalHistory+8)
	for _, signal := range s.history {
		channel <- proto.Clone(signal).(*dieterv1.RemoteDesktopSignal)
	}
	s.subscribers[id] = channel
	s.detachedAt = time.Time{}
	s.leaseExpiresAt = now.Add(s.manager.options.SessionLease)
	return &Subscription{SessionID: s.id, Signals: channel, close: func() { s.unsubscribe(id) }}, nil
}

func (s *Session) unsubscribe(id uint64) {
	s.mu.Lock()
	channel := s.subscribers[id]
	delete(s.subscribers, id)
	if len(s.subscribers) == 0 && !s.closed {
		s.detachedAt = s.manager.options.Now().UTC()
	}
	if channel != nil {
		close(channel)
	}
	s.mu.Unlock()
}

func (s *Session) emit(signal *dieterv1.RemoteDesktopSignal) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.sequence++
	signal.SessionId, signal.Sequence = s.id, s.sequence
	copy := proto.Clone(signal).(*dieterv1.RemoteDesktopSignal)
	s.history = append(s.history, copy)
	if len(s.history) > maxSignalHistory {
		s.history = append([]*dieterv1.RemoteDesktopSignal(nil), s.history[len(s.history)-maxSignalHistory:]...)
	}
	for id, subscriber := range s.subscribers {
		select {
		case subscriber <- proto.Clone(signal).(*dieterv1.RemoteDesktopSignal):
		default:
			close(subscriber)
			delete(s.subscribers, id)
		}
	}
	if len(s.subscribers) == 0 && s.detachedAt.IsZero() {
		s.detachedAt = s.manager.options.Now().UTC()
	}
	s.mu.Unlock()
}

func (s *Session) emitState(phase, reason string) {
	s.emit(&dieterv1.RemoteDesktopSignal{Payload: &dieterv1.RemoteDesktopSignal_State{State: &dieterv1.RemoteDesktopSessionState{Phase: phase, Reason: reason, Codec: string(s.codec)}}})
}

func (s *Session) emitError(code, message string, recoverable bool) {
	s.emit(&dieterv1.RemoteDesktopSignal{Payload: &dieterv1.RemoteDesktopSignal_Error{Error: &dieterv1.RemoteDesktopSessionError{Code: code, Message: message, Recoverable: recoverable}}})
}

func (s *Session) signal(value *dieterv1.RemoteDesktopSignal) error {
	if value == nil {
		return ErrInvalidSignal
	}
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return ErrNotFound
	}
	s.mu.Unlock()
	switch payload := value.GetPayload().(type) {
	case *dieterv1.RemoteDesktopSignal_LeaseHeartbeat:
		s.mu.Lock()
		s.leaseExpiresAt = s.manager.options.Now().UTC().Add(s.manager.options.SessionLease)
		s.mu.Unlock()
		return nil
	case *dieterv1.RemoteDesktopSignal_Candidate:
		if len(payload.Candidate.GetCandidate()) > maxCandidateBytes {
			return ErrInvalidSignal
		}
		return s.pc.AddICECandidate(candidateInit(payload.Candidate))
	case *dieterv1.RemoteDesktopSignal_Description:
		if payload.Description.GetType() != "offer" || len(payload.Description.GetSdp()) > maxSDPBytes {
			return ErrInvalidSignal
		}
		if err := s.pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: payload.Description.GetSdp()}); err != nil {
			return err
		}
		answer, err := s.pc.CreateAnswer(nil)
		if err != nil {
			return err
		}
		if err := s.pc.SetLocalDescription(answer); err != nil {
			return err
		}
		if local := s.pc.LocalDescription(); local != nil {
			s.emit(&dieterv1.RemoteDesktopSignal{Payload: &dieterv1.RemoteDesktopSignal_Description{Description: &dieterv1.RemoteDesktopSessionDescription{Type: "answer", Sdp: local.SDP}}})
		}
		return nil
	default:
		return ErrInvalidSignal
	}
}

func (s *Session) streamSource(request *dieterv1.StartRemoteDesktopRequest) {
	err := s.source.Stream(s.ctx, func(sample media.Sample) error { return s.track.WriteSample(sample) })
	if err != nil && s.ctx.Err() == nil {
		s.emitError("capture_failed", err.Error(), false)
		s.close(err.Error())
	}
}

func (s *Session) monitor() {
	ticker := time.NewTicker(s.manager.options.MonitorInterval)
	defer ticker.Stop()
	for {
		select {
		case <-s.ctx.Done():
			return
		case <-ticker.C:
			now := s.manager.options.Now().UTC()
			s.mu.Lock()
			leaseExpired := !now.Before(s.leaseExpiresAt)
			detachedExpired := !s.detachedAt.IsZero() && now.Sub(s.detachedAt) >= s.manager.options.DetachGrace
			peerDetachedExpired := !s.peerDetachedAt.IsZero() && now.Sub(s.peerDetachedAt) >= s.manager.options.DetachGrace
			s.mu.Unlock()
			if leaseExpired {
				s.close("session lease expired")
				return
			}
			if detachedExpired {
				s.close("signaling observer did not reconnect")
				return
			}
			if peerDetachedExpired {
				s.close("WebRTC peer did not reconnect")
				return
			}
		}
	}
}

func (s *Session) close(reason string) {
	s.closeOnce.Do(func() {
		s.releaseInput()
		s.emitState("closed", reason)
		s.mu.Lock()
		s.closed = true
		for id, subscriber := range s.subscribers {
			close(subscriber)
			delete(s.subscribers, id)
		}
		s.mu.Unlock()
		s.cancel()
		_ = s.pc.Close()
		s.manager.clear(s)
	})
}

func candidateInit(candidate *dieterv1.RemoteDesktopICECandidate) webrtc.ICECandidateInit {
	mid := candidate.GetSdpMid()
	index := uint16(max(0, int(candidate.GetSdpMlineIndex())))
	username := candidate.GetUsernameFragment()
	return webrtc.ICECandidateInit{Candidate: candidate.GetCandidate(), SDPMid: &mid, SDPMLineIndex: &index, UsernameFragment: &username}
}

func sdpFingerprint(sdp string) string {
	for _, line := range strings.Split(sdp, "\n") {
		line = strings.TrimSpace(line)
		if value, ok := strings.CutPrefix(line, "a=fingerprint:"); ok {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func SessionBindingMessage(sessionID, nonce, fingerprint, expiresAt string, offerHash []byte, control bool, displayID string, protocolVersion uint32, inputEpoch []byte) []byte {
	return []byte(strings.Join([]string{
		"dieter-remote-desktop-v2", sessionID, nonce, fingerprint, expiresAt,
		base64.RawURLEncoding.EncodeToString(offerHash), fmt.Sprintf("%t", control), displayID,
		fmt.Sprintf("%d", protocolVersion), base64.RawURLEncoding.EncodeToString(inputEpoch),
	}, "\n"))
}

func handleRTCP(sender *webrtc.RTPSender, source FrameSource, logger *slog.Logger) {
	for {
		packets, _, err := sender.ReadRTCP()
		if err != nil {
			return
		}
		for _, packet := range packets {
			switch value := packet.(type) {
			case *rtcp.PictureLossIndication, *rtcp.FullIntraRequest:
				if controlled, ok := source.(ControlledFrameSource); ok {
					controlled.RequestKeyFrame()
				}
				if logger != nil {
					logger.Debug("remote desktop keyframe requested", "feedback", fmt.Sprintf("%T", packet))
				}
			case *rtcp.ReceiverEstimatedMaximumBitrate:
				bitrate := int(value.Bitrate / 1_000)
				if controlled, ok := source.(ControlledFrameSource); ok && bitrate >= 100 {
					controlled.SetBitrateKbps(bitrate)
				}
				if logger != nil {
					logger.Debug("remote desktop receiver bitrate", "bitrate_kbps", bitrate)
				}
			}
		}
	}
}

func codecCapability(codec VideoCodec) webrtc.RTPCodecCapability {
	if codec == VideoCodecH264 {
		return webrtc.RTPCodecCapability{
			MimeType: webrtc.MimeTypeH264, ClockRate: 90_000,
			SDPFmtpLine:  "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
			RTCPFeedback: []webrtc.RTCPFeedback{{Type: "goog-remb"}, {Type: "ccm", Parameter: "fir"}, {Type: "nack"}, {Type: "nack", Parameter: "pli"}},
		}
	}
	return webrtc.RTPCodecCapability{MimeType: webrtc.MimeTypeVP8, ClockRate: 90_000}
}

func preferredVideoCodec(options SourceOptions) VideoCodec {
	if strings.TrimSpace(options.Kind) == "synthetic" || runtime.GOOS != "darwin" {
		return VideoCodecVP8
	}
	return VideoCodecH264
}

func remoteDesktopHelperVersion(options SourceOptions) string {
	if preferredVideoCodec(options) == VideoCodecH264 {
		return "screencapturekit-videotoolbox-v1"
	}
	return "pion-vp8-v1"
}

func randomID() string {
	return "rd_" + base64.RawURLEncoding.EncodeToString(randomBytes(12))
}

func randomBytes(size int) []byte {
	value := make([]byte, size)
	if _, err := io.ReadFull(rand.Reader, value); err != nil {
		panic(fmt.Sprintf("read system randomness: %v", err))
	}
	return value
}
