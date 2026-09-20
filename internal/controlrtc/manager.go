package controlrtc

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net"
	"strings"
	"sync"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/trust"
	"github.com/pion/webrtc/v4"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

const Capability = "control_webrtc_v1"
const MaxSessions = 16
const SetupTimeout = 20 * time.Second
const SessionLifetime = time.Hour

type Identity struct {
	DaemonID, GatewayURL    string
	Generation              uint64
	GatewaySigningPublicKey []byte
}
type Manager struct {
	mu       sync.Mutex
	sessions map[string]*session
	identity Identity
	target   string
	closed   bool
}
type session struct {
	pc        *webrtc.PeerConnection
	owner     string
	relayOnly bool
	expires   time.Time
	answer    string
	once      sync.Once
	close     func()
	setup     *time.Timer
	lifetime  *time.Timer
	stream    net.Conn
}

// target is the daemon-owned authenticated loopback TLS listener, never a
// caller-supplied address or the unauthenticated raw API.
func New(identity Identity, target string) *Manager {
	return &Manager{identity: identity, target: target, sessions: map[string]*session{}}
}

func (m *Manager) verify(c *gatewayv1.RTCConfiguration, subject string) error {
	if c == nil || c.GetDaemonId() != m.identity.DaemonID || c.GetDaemonGeneration() != m.identity.Generation || subject == "" || c.GetOperatorSubject() != subject {
		return status.Error(codes.PermissionDenied, "RTC configuration does not match daemon and operator")
	}
	copy := proto.Clone(c).(*gatewayv1.RTCConfiguration)
	copy.SignedEnvelope = nil
	raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(copy)
	if err != nil {
		return err
	}
	digest := sha256.Sum256(raw)
	public, err := trust.PublicKeyFromPEM(m.identity.GatewaySigningPublicKey)
	if err != nil {
		return err
	}
	_, err = trust.ParseAndVerifyRTCConfiguration(public, string(c.GetSignedEnvelope()), m.identity.GatewayURL, m.identity.DaemonID, subject, c.GetConfigurationId(), digest[:], m.identity.Generation, time.Now())
	if err != nil {
		return status.Error(codes.Unauthenticated, "RTC configuration is invalid or expired")
	}
	return nil
}

func Configuration(c *gatewayv1.RTCConfiguration) webrtc.Configuration {
	servers := []webrtc.ICEServer{}
	for _, s := range c.GetIceServers() {
		servers = append(servers, webrtc.ICEServer{URLs: s.GetUrls(), Username: s.GetUsername(), Credential: s.GetCredential()})
	}
	return webrtc.Configuration{ICEServers: servers}
}

func (m *Manager) Start(ctx context.Context, r *dieterv1.StartControlConnectionRequest, owner string) (*dieterv1.ControlConnection, error) {
	if m == nil || m.target == "" {
		return nil, status.Error(codes.Unimplemented, ErrUnavailable.Error())
	}
	if len(r.GetOfferSdp()) == 0 || len(r.GetOfferSdp()) > 64<<10 {
		return nil, status.Error(codes.InvalidArgument, "control SDP must be between 1 byte and 64 KiB")
	}
	if err := m.verify(r.GetRtcConfiguration(), owner); err != nil {
		return nil, err
	}
	m.mu.Lock()
	if m.closed || len(m.sessions) >= MaxSessions {
		m.mu.Unlock()
		return nil, status.Error(codes.ResourceExhausted, "control session capacity exhausted")
	}
	pc, err := webrtc.NewPeerConnection(Configuration(r.GetRtcConfiguration()))
	if err != nil {
		m.mu.Unlock()
		return nil, err
	}
	nonce := make([]byte, 24)
	_, _ = rand.Read(nonce)
	id := hex.EncodeToString(nonce)
	s := &session{pc: pc, owner: owner, relayOnly: offerUsesOnlyRelayCandidates(r.GetOfferSdp()), expires: time.Now().Add(SessionLifetime)}
	s.close = func() {
		s.once.Do(func() {
			m.mu.Lock()
			delete(m.sessions, id)
			if s.setup != nil {
				s.setup.Stop()
			}
			if s.lifetime != nil {
				s.lifetime.Stop()
			}
			stream := s.stream
			m.mu.Unlock()
			if stream != nil {
				_ = stream.Close()
			}
			_ = pc.Close()
		})
	}
	m.sessions[id] = s
	s.setup = time.AfterFunc(SetupTimeout, s.close)
	s.lifetime = time.AfterFunc(SessionLifetime, s.close)
	m.mu.Unlock()
	success := false
	defer func() {
		if !success {
			s.close()
		}
	}()
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		if state == webrtc.PeerConnectionStateFailed || state == webrtc.PeerConnectionStateClosed {
			go s.close()
		}
	})
	pc.OnDataChannel(func(dc *webrtc.DataChannel) {
		if dc.Label() != Label || !dc.Ordered() || dc.MaxRetransmits() != nil || dc.MaxPacketLifeTime() != nil {
			go s.close()
			return
		}
		m.mu.Lock()
		if s.stream != nil || m.sessions[id] != s {
			m.mu.Unlock()
			go s.close()
			return
		}
		stream := Stream(dc, s.close)
		s.stream = stream
		m.mu.Unlock()
		go func() {
			defer s.close()
			socket, err := net.DialTimeout("tcp", m.target, 3*time.Second)
			if err != nil {
				return
			}
			// Setup is complete only when the TLS peer actually begins using its
			// stream; merely creating a channel must not retain a slot indefinitely.
			_ = stream.SetReadDeadline(time.Now().Add(SetupTimeout))
			first := make([]byte, ChunkSize)
			n, err := stream.Read(first)
			if err != nil {
				socket.Close()
				return
			}
			m.mu.Lock()
			s.setup.Stop()
			m.mu.Unlock()
			_ = stream.SetReadDeadline(time.Time{})
			_ = socket.SetWriteDeadline(time.Now().Add(SetupTimeout))
			if _, err = socket.Write(first[:n]); err != nil {
				socket.Close()
				return
			}
			_ = socket.SetWriteDeadline(time.Time{})
			CopyStream(stream, socket)
		}()
	})
	if err = pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeOffer, SDP: r.GetOfferSdp()}); err != nil {
		return nil, status.Error(codes.InvalidArgument, "invalid control SDP offer")
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		return nil, err
	}
	gathering := webrtc.GatheringCompletePromise(pc)
	if err = pc.SetLocalDescription(answer); err != nil {
		return nil, err
	}
	// Non-trickle bootstrap is bounded. A partial host/STUN/TURN candidate set
	// is usable when slow ICE servers exceed the gathering budget.
	timer := time.NewTimer(3 * time.Second)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-gathering:
	case <-timer.C:
	}
	m.mu.Lock()
	s.answer = pc.LocalDescription().SDP
	m.mu.Unlock()
	result, err := m.Get(id, owner)
	if err != nil {
		return nil, err
	}
	success = true
	return result, nil
}

func (m *Manager) Get(id, owner string) (*dieterv1.ControlConnection, error) {
	if m == nil {
		return nil, status.Error(codes.Unimplemented, ErrUnavailable.Error())
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	s := m.sessions[id]
	if s == nil || (owner != "" && s.owner != owner) {
		return nil, status.Error(codes.NotFound, "control connection not found")
	}
	connectionState := s.pc.ConnectionState()
	result := &dieterv1.ControlConnection{SessionId: id, AnswerSdp: s.answer, ExpiresAt: s.expires.UTC().Format(time.RFC3339Nano), State: connectionState.String(), Mode: "unknown"}
	// Pion starts its ICE transport asynchronously from SetRemoteDescription.
	// Reading the selected pair before the peer reaches connected can race with
	// that initialization; the pair is meaningful only after connection anyway.
	if connectionState == webrtc.PeerConnectionStateConnected && s.pc.SCTP() != nil && s.pc.SCTP().Transport() != nil {
		pair, err := s.pc.SCTP().Transport().ICETransport().GetSelectedCandidatePair()
		if err == nil && pair != nil {
			result.LocalCandidateType = pair.Local.Typ.String()
			result.RemoteCandidateType = pair.Remote.Typ.String()
			result.Mode = "direct"
			if s.relayOnly || pair.Local.Typ == webrtc.ICECandidateTypeRelay || pair.Remote.Typ == webrtc.ICECandidateTypeRelay {
				result.Mode = "turn"
			}
		}
	}
	return result, nil
}

func offerUsesOnlyRelayCandidates(value string) bool {
	found := false
	for _, line := range strings.Split(value, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "a=candidate:") {
			continue
		}
		found = true
		if !strings.Contains(" "+line+" ", " typ relay ") {
			return false
		}
	}
	return found
}
func (m *Manager) CloseSession(id, owner string) error {
	if m == nil {
		return status.Error(codes.Unimplemented, ErrUnavailable.Error())
	}
	m.mu.Lock()
	s := m.sessions[id]
	m.mu.Unlock()
	if s == nil {
		return nil
	}
	if owner != "" && s.owner != owner {
		return status.Error(codes.NotFound, "control connection not found")
	}
	s.close()
	return nil
}
func (m *Manager) Close() {
	if m == nil {
		return
	}
	m.mu.Lock()
	m.closed = true
	items := make([]*session, 0, len(m.sessions))
	for _, s := range m.sessions {
		items = append(items, s)
	}
	m.mu.Unlock()
	for _, s := range items {
		s.close()
	}
}

// Dial negotiates one byte stream. TLS identity and RPC bearer validation are
// still performed by the ordinary direct transport above this connection.
func Dial(ctx context.Context, configuration *gatewayv1.RTCConfiguration, start func(context.Context, *dieterv1.StartControlConnectionRequest) (*dieterv1.ControlConnection, error)) (net.Conn, *dieterv1.ControlConnection, error) {
	return DialWithPolicy(ctx, configuration, start, false)
}

// DialWithPolicy allows a caller to require TURN without changing signed remote
// configuration. TLS and RPC authorization remain mandatory on the returned stream.
func DialWithPolicy(ctx context.Context, configuration *gatewayv1.RTCConfiguration, start func(context.Context, *dieterv1.StartControlConnectionRequest) (*dieterv1.ControlConnection, error), relayOnly bool) (net.Conn, *dieterv1.ControlConnection, error) {
	config := Configuration(configuration)
	if relayOnly {
		config.ICETransportPolicy = webrtc.ICETransportPolicyRelay
	}
	pc, err := webrtc.NewPeerConnection(config)
	if err != nil {
		return nil, nil, err
	}
	dc, err := pc.CreateDataChannel(Label, nil)
	if err != nil {
		pc.Close()
		return nil, nil, err
	}
	stream := Stream(dc, func() { _ = pc.Close() })
	good := false
	defer func() {
		if !good {
			stream.Close()
		}
	}()
	pc.OnConnectionStateChange(func(s webrtc.PeerConnectionState) {
		if s == webrtc.PeerConnectionStateFailed || s == webrtc.PeerConnectionStateClosed {
			go stream.Close()
		}
	})
	offer, err := pc.CreateOffer(nil)
	if err != nil {
		return nil, nil, err
	}
	complete := webrtc.GatheringCompletePromise(pc)
	if err = pc.SetLocalDescription(offer); err != nil {
		return nil, nil, err
	}
	timer := time.NewTimer(3 * time.Second)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return nil, nil, ctx.Err()
	case <-complete:
	case <-timer.C:
	}
	result, err := start(ctx, &dieterv1.StartControlConnectionRequest{RtcConfiguration: configuration, OfferSdp: pc.LocalDescription().SDP})
	if err != nil {
		return nil, nil, err
	}
	if result.GetSessionId() == "" || len(result.GetAnswerSdp()) > 64<<10 {
		return nil, nil, errors.New("invalid control answer")
	}
	if err = pc.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: result.GetAnswerSdp()}); err != nil {
		return nil, nil, err
	}
	good = true
	return stream, result, nil
}
