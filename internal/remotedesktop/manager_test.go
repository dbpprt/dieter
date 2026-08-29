package remotedesktop

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"strings"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/trust"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

type blockingFrameSource struct {
	started chan struct{}
	stopped chan struct{}
	codec   VideoCodec
}

type inputFrameSource struct {
	blockingFrameSource
	inputs   chan *dieterv1.RemoteDesktopInput
	released chan struct{}
}

func (s *inputFrameSource) SendInput(_ context.Context, input *dieterv1.RemoteDesktopInput) error {
	s.inputs <- proto.Clone(input).(*dieterv1.RemoteDesktopInput)
	return nil
}

func (s *inputFrameSource) ReleaseInput(context.Context) {
	select {
	case s.released <- struct{}{}:
	default:
	}
}

func (s *blockingFrameSource) Description() string { return "blocking test source" }
func (s *blockingFrameSource) Codec() VideoCodec {
	if s.codec == "" {
		return VideoCodecVP8
	}
	return s.codec
}

func (s *blockingFrameSource) Stream(ctx context.Context, _ func(media.Sample) error) error {
	close(s.started)
	<-ctx.Done()
	close(s.stopped)
	return nil
}

func TestManagerStreamsSyntheticVP8AndSignsBinding(t *testing.T) {
	manager, request, daemonPublic := testManagerAndRequest(t, "github:7")
	client := testViewer(t, request)
	defer client.Close()

	subscription, err := manager.Start(request, true, false, "github:7")
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()

	trackReceived := make(chan struct{}, 1)
	client.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		if track.Codec().MimeType != webrtc.MimeTypeVP8 {
			return
		}
		go func() {
			if _, _, err := track.ReadRTP(); err == nil {
				trackReceived <- struct{}{}
			}
		}()
	})

	var binding *dieterv1.RemoteDesktopSessionBinding
	answerApplied := false
	var pendingCandidates []*dieterv1.RemoteDesktopICECandidate
	deadline := time.After(30 * time.Second)
	for binding == nil || !answerApplied {
		select {
		case <-deadline:
			t.Fatal("timed out waiting for signed binding and SDP answer")
		case signal := <-subscription.Signals:
			switch payload := signal.GetPayload().(type) {
			case *dieterv1.RemoteDesktopSignal_Binding:
				binding = payload.Binding
				if binding.GetControlGranted() || binding.GetInputProtocolVersion() != inputProtocolVersion || len(binding.GetInputEpoch()) != 16 || binding.GetDisplayId() != "primary" {
					t.Fatalf("binding did not include bounded input authorization: %#v", binding)
				}
				offerHash := sha256.Sum256([]byte(request.GetOffer().GetSdp()))
				message := SessionBindingMessage(signal.GetSessionId(), binding.GetClientNonce(), binding.GetHelperDtlsFingerprint(), binding.GetExpiresAt(), offerHash[:], binding.GetControlGranted(), binding.GetDisplayId(), binding.GetInputProtocolVersion(), binding.GetInputEpoch())
				if !ed25519.Verify(daemonPublic, message, binding.GetDaemonSignature()) {
					t.Fatal("daemon session binding signature did not verify")
				}
			case *dieterv1.RemoteDesktopSignal_Description:
				if err := client.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: payload.Description.GetSdp()}); err != nil {
					t.Fatal(err)
				}
				answerApplied = true
				for _, candidate := range pendingCandidates {
					if err := client.AddICECandidate(candidateInit(candidate)); err != nil {
						t.Fatal(err)
					}
				}
				pendingCandidates = nil
			case *dieterv1.RemoteDesktopSignal_Candidate:
				if answerApplied {
					if err := client.AddICECandidate(candidateInit(payload.Candidate)); err != nil {
						t.Fatal(err)
					}
				} else {
					pendingCandidates = append(pendingCandidates, payload.Candidate)
				}
			}
		}
	}

	select {
	case <-trackReceived:
	case <-time.After(30 * time.Second):
		t.Fatal("timed out waiting for a synthetic VP8 frame")
	}
	if err := manager.Signal(&dieterv1.RemoteDesktopSignal{SessionId: subscription.SessionID, Payload: &dieterv1.RemoteDesktopSignal_LeaseHeartbeat{LeaseHeartbeat: &emptypb.Empty{}}}); err != nil {
		t.Fatal(err)
	}
	if err := manager.Close(subscription.SessionID, "test complete"); err != nil {
		t.Fatal(err)
	}
}

func TestManagerCarriesAuthorizedInputAndReleasesItOnChannelClose(t *testing.T) {
	manager, request, _ := testManagerAndRequest(t, "github:7")
	request.Control = true
	source := &inputFrameSource{
		blockingFrameSource: blockingFrameSource{started: make(chan struct{}), stopped: make(chan struct{})},
		inputs:              make(chan *dieterv1.RemoteDesktopInput, 1), released: make(chan struct{}, 1),
	}
	manager.options.SourceFactory = func(SourceOptions) (FrameSource, error) { return source, nil }
	manager.options.CaptureProbe = func(context.Context, SourceOptions) error { return nil }
	manager.options.ControlProbe = func(context.Context, SourceOptions, bool) error { return nil }

	viewer, stateChannel := testControlViewer(t, request)
	defer viewer.Close()
	subscription, err := manager.Start(request, true, true, "github:7")
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()

	var binding *dieterv1.RemoteDesktopSessionBinding
	answerApplied := false
	var pending []*dieterv1.RemoteDesktopICECandidate
	for binding == nil || !answerApplied {
		select {
		case signal := <-subscription.Signals:
			switch payload := signal.GetPayload().(type) {
			case *dieterv1.RemoteDesktopSignal_Binding:
				binding = payload.Binding
			case *dieterv1.RemoteDesktopSignal_Description:
				if err := viewer.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: payload.Description.GetSdp()}); err != nil {
					t.Fatal(err)
				}
				answerApplied = true
				for _, candidate := range pending {
					if err := viewer.AddICECandidate(candidateInit(candidate)); err != nil {
						t.Fatal(err)
					}
				}
			case *dieterv1.RemoteDesktopSignal_Candidate:
				if answerApplied {
					if err := viewer.AddICECandidate(candidateInit(payload.Candidate)); err != nil {
						t.Fatal(err)
					}
				} else {
					pending = append(pending, payload.Candidate)
				}
			}
		case <-time.After(30 * time.Second):
			t.Fatal("timed out negotiating controlled desktop")
		}
	}
	deadline := time.Now().Add(30 * time.Second)
	for stateChannel.ReadyState() != webrtc.DataChannelStateOpen && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if stateChannel.ReadyState() != webrtc.DataChannelStateOpen {
		t.Fatal("reliable input channel did not open")
	}
	input := &dieterv1.RemoteDesktopInput{
		ProtocolVersion: inputProtocolVersion, InputEpoch: binding.GetInputEpoch(), Sequence: 1,
		Payload: &dieterv1.RemoteDesktopInput_Key{Key: &dieterv1.RemoteDesktopKey{KeyCode: 55, Down: true, Modifiers: 8}},
	}
	raw, err := proto.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	if err := stateChannel.Send(raw); err != nil {
		t.Fatal(err)
	}
	select {
	case received := <-source.inputs:
		if received.GetKey().GetKeyCode() != 55 || !received.GetKey().GetDown() {
			t.Fatalf("received input=%#v", received)
		}
	case <-time.After(time.Second):
		t.Fatal("authorized input did not reach the helper source")
	}
	if err := stateChannel.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-source.released:
	case <-time.After(time.Second):
		t.Fatal("closing the input channel did not release held input")
	}
	manager.CloseActive("test complete")
}

func TestManagerRejectsRTCConfigurationFromAnotherOperator(t *testing.T) {
	manager, request, _ := testManagerAndRequest(t, "github:7")
	viewer := testViewer(t, request)
	defer viewer.Close()
	if _, err := manager.Start(request, true, false, "github:8"); err == nil {
		t.Fatal("expected operator-bound RTC configuration to be rejected")
	}
	if _, err := manager.Start(request, true, true, "github:7"); err != nil {
		// A viewing-only request remains valid when host control is also enabled.
		t.Fatal(err)
	}
	manager.CloseActive("test complete")
	request.Control = true
	controlled, err := manager.Start(request, true, true, "github:7")
	if err != nil {
		t.Fatalf("control request failed: %v", err)
	}
	manager.CloseControlActive("control disabled")
	if manager.Capabilities(true, true).GetActiveSession() {
		t.Fatal("controlled session survived host control disable")
	}
	controlled.Close()
	if _, err := manager.Start(request, true, false, "github:7"); err != ErrControlDisabled {
		t.Fatalf("disabled control request error=%v, want %v", err, ErrControlDisabled)
	}
}

func TestManagerReattachesSameOperatorWithoutReusingGatewayAdmission(t *testing.T) {
	manager, request, _ := testManagerAndRequest(t, "github:7")
	viewer := testViewer(t, request)
	defer viewer.Close()
	first, err := manager.Start(request, true, false, "github:7")
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()

	// Reattachment resumes the admitted session. It must not depend on the
	// short-lived gateway configuration still being valid after a signaling
	// transport interruption.
	request.RtcConfiguration.SignedEnvelope = []byte("expired-or-already-consumed")
	second, err := manager.Start(request, true, false, "github:7")
	if err != nil {
		t.Fatalf("reattach failed: %v", err)
	}
	defer second.Close()
	if second.SessionID != first.SessionID {
		t.Fatalf("reattach session=%q, want %q", second.SessionID, first.SessionID)
	}
	differentOffer := proto.Clone(request).(*dieterv1.StartRemoteDesktopRequest)
	differentOffer.Offer.Sdp += "\r\n"
	if _, err := manager.Start(differentOffer, true, false, "github:7"); !errors.Is(err, ErrBusy) {
		t.Fatalf("different offer reattach error=%v, want %v", err, ErrBusy)
	}
	differentControl := proto.Clone(request).(*dieterv1.StartRemoteDesktopRequest)
	differentControl.Control = true
	if _, err := manager.Start(differentControl, true, true, "github:7"); !errors.Is(err, ErrBusy) {
		t.Fatalf("different control grant reattach error=%v, want %v", err, ErrBusy)
	}
	if _, err := manager.Start(request, true, false, "github:8"); !errors.Is(err, ErrBusy) {
		t.Fatalf("other operator reattach error=%v, want %v", err, ErrBusy)
	}
	manager.CloseActive("test complete")
}

func TestManagerCapabilityRequiresRealCaptureProbe(t *testing.T) {
	t.Setenv("DISPLAY", ":99")
	manager, _, _ := testManagerAndRequest(t, "github:7")
	manager.options.Source = SourceOptions{Kind: "screen", HelperPath: "/usr/bin/true", FFmpegPath: "/usr/bin/true"}
	manager.options.CaptureProbe = func(context.Context, SourceOptions) error {
		return errors.New("macOS Screen Recording permission is not granted to Dieter's capture helper")
	}
	capabilities := manager.Capabilities(true, false)
	if capabilities.GetReady() || capabilities.GetCapturePermission() != "denied" {
		t.Fatalf("capabilities=%#v", capabilities)
	}
	if capabilities.GetUnavailableReason() != "macOS Screen Recording permission is not granted to Dieter's capture helper" {
		t.Fatalf("unavailable reason=%q", capabilities.GetUnavailableReason())
	}

	manager.probe = captureProbeResult{}
	manager.options.CaptureProbe = func(context.Context, SourceOptions) error { return nil }
	capabilities = manager.Capabilities(true, false)
	if !capabilities.GetReady() || capabilities.GetCapturePermission() != "granted" {
		t.Fatalf("capabilities after permission=%#v", capabilities)
	}
}

func TestManagerReportsControlPermissionWithoutDisablingViewing(t *testing.T) {
	manager, _, _ := testManagerAndRequest(t, "github:7")
	manager.options.ControlProbe = func(context.Context, SourceOptions, bool) error {
		return errors.New("Accessibility permission denied")
	}
	capabilities := manager.Capabilities(true, true)
	if !capabilities.GetReady() || !capabilities.GetControlSupported() || capabilities.GetControlPermission() != "denied" {
		t.Fatalf("control permission capabilities=%#v", capabilities)
	}
}

func TestH264CodecCapabilityUsesWebRTCRealtimeProfile(t *testing.T) {
	codec := codecCapability(VideoCodecH264)
	if codec.MimeType != webrtc.MimeTypeH264 || codec.ClockRate != 90_000 {
		t.Fatalf("codec=%#v", codec)
	}
	if !strings.Contains(codec.SDPFmtpLine, "packetization-mode=1") || !strings.Contains(codec.SDPFmtpLine, "profile-level-id=42e01f") {
		t.Fatalf("H264 fmtp=%q", codec.SDPFmtpLine)
	}
}

func TestManagerNegotiatesNativeH264Source(t *testing.T) {
	manager, request, _ := testManagerAndRequest(t, "github:7")
	viewer := testViewer(t, request)
	defer viewer.Close()
	source := &blockingFrameSource{
		started: make(chan struct{}), stopped: make(chan struct{}), codec: VideoCodecH264,
	}
	manager.options.CaptureProbe = func(context.Context, SourceOptions) error { return nil }
	manager.options.SourceFactory = func(SourceOptions) (FrameSource, error) { return source, nil }

	subscription, err := manager.Start(request, true, false, "github:7")
	if err != nil {
		t.Fatalf("negotiate H264 source: %v", err)
	}
	defer subscription.Close()
	manager.mu.Lock()
	codec := manager.session.codec
	manager.mu.Unlock()
	if codec != VideoCodecH264 {
		t.Fatalf("session codec=%q, want %q", codec, VideoCodecH264)
	}
}

func TestStartRequestRejectsUnsafeCaptureDimensions(t *testing.T) {
	_, request, _ := testManagerAndRequest(t, "github:7")
	viewer := testViewer(t, request)
	defer viewer.Close()
	request.MaxWidth = 20_000
	if err := validateStartRequest(request); err == nil || !strings.Contains(err.Error(), "max_width") {
		t.Fatalf("dimension validation error=%v", err)
	}
}

func TestManagerStopsCaptureWhenSignalingObserverDisconnects(t *testing.T) {
	manager, request, _ := testManagerAndRequest(t, "github:7")
	viewer := testViewer(t, request)
	defer viewer.Close()
	source := &blockingFrameSource{started: make(chan struct{}), stopped: make(chan struct{})}
	manager.options.CaptureProbe = func(context.Context, SourceOptions) error { return nil }
	manager.options.SourceFactory = func(SourceOptions) (FrameSource, error) { return source, nil }
	manager.options.DetachGrace = 25 * time.Millisecond
	manager.options.MonitorInterval = 5 * time.Millisecond
	subscription, err := manager.Start(request, true, false, "github:7")
	if err != nil {
		t.Fatal(err)
	}
	manager.mu.Lock()
	session := manager.session
	manager.mu.Unlock()
	session.startOnce.Do(func() { go session.streamSource(request) })
	select {
	case <-source.started:
	case <-time.After(time.Second):
		t.Fatal("capture source did not start")
	}

	subscription.Close()
	select {
	case <-source.stopped:
	case <-time.After(time.Second):
		t.Fatal("capture source was not canceled after the signaling observer disconnected")
	}
	if capabilities := manager.Capabilities(true, false); capabilities.GetActiveSession() {
		t.Fatalf("session remained active after disconnect: %#v", capabilities)
	}
}

func TestManagerStopsCaptureWhenWebRTCPeerDoesNotReconnect(t *testing.T) {
	manager, request, _ := testManagerAndRequest(t, "github:7")
	viewer := testViewer(t, request)
	defer viewer.Close()
	source := &blockingFrameSource{started: make(chan struct{}), stopped: make(chan struct{})}
	manager.options.CaptureProbe = func(context.Context, SourceOptions) error { return nil }
	manager.options.SourceFactory = func(SourceOptions) (FrameSource, error) { return source, nil }
	manager.options.DetachGrace = 25 * time.Millisecond
	manager.options.MonitorInterval = 5 * time.Millisecond
	subscription, err := manager.Start(request, true, false, "github:7")
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	manager.mu.Lock()
	session := manager.session
	manager.mu.Unlock()
	session.startOnce.Do(func() { go session.streamSource(request) })
	select {
	case <-source.started:
	case <-time.After(time.Second):
		t.Fatal("capture source did not start")
	}
	session.mu.Lock()
	session.peerDetachedAt = time.Now().Add(-manager.options.DetachGrace)
	session.mu.Unlock()

	select {
	case <-source.stopped:
	case <-time.After(time.Second):
		t.Fatal("capture source was not canceled after the WebRTC peer disconnected")
	}
}

func testManagerAndRequest(t *testing.T, operator string) (*Manager, *dieterv1.StartRemoteDesktopRequest, ed25519.PublicKey) {
	t.Helper()
	gatewayPublic, gatewayPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	daemonPublic, daemonPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	publicDER, err := x509.MarshalPKIXPublicKey(gatewayPublic)
	if err != nil {
		t.Fatal(err)
	}
	gatewayPublicPEM := pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: publicDER})
	now := time.Now().UTC()
	configuration := &gatewayv1.RTCConfiguration{
		ExpiresAt: now.Add(2 * time.Minute).Format(time.RFC3339Nano), DaemonId: "d_test",
		OperatorSubject: operator, ConfigurationId: "rtc_test", DaemonGeneration: 3,
		IssuedAt: now.Format(time.RFC3339Nano),
	}
	raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(configuration)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(raw)
	envelope, err := trust.SignCompact(gatewayPrivate, trust.RTCConfigurationClaims{
		Issuer: "https://gateway.example", Audience: "board-daemon:d_test", Subject: operator,
		ID: "rtc_test", ConfigurationHash: base64.RawURLEncoding.EncodeToString(digest[:]),
		DaemonGeneration: 3, IssuedAt: now.Unix(), ExpiresAt: now.Add(2 * time.Minute).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}
	configuration.SignedEnvelope = []byte(envelope)
	request := &dieterv1.StartRemoteDesktopRequest{
		ClientNonce: "nonce_test", RtcConfiguration: configuration, DisplayId: "primary",
		MaxFps: 10, MaxBitrateKbps: 500,
	}
	return New(Options{
		Identity: Identity{
			DaemonID: "d_test", GatewayURL: "https://gateway.example", Generation: 3,
			PrivateKey: daemonPrivate, GatewaySigningPublicKey: gatewayPublicPEM,
		},
		Source: SourceOptions{Kind: "synthetic", FPS: 10},
	}), request, daemonPublic
}

func testViewer(t *testing.T, request *dieterv1.StartRemoteDesktopRequest) *webrtc.PeerConnection {
	t.Helper()
	settings := webrtc.SettingEngine{}
	settings.SetIncludeLoopbackCandidate(true)
	client, err := webrtc.NewAPI(webrtc.WithSettingEngine(settings)).NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
		client.Close()
		t.Fatal(err)
	}
	offer, err := client.CreateOffer(nil)
	if err != nil {
		client.Close()
		t.Fatal(err)
	}
	gatheringComplete := webrtc.GatheringCompletePromise(client)
	if err := client.SetLocalDescription(offer); err != nil {
		client.Close()
		t.Fatal(err)
	}
	select {
	case <-gatheringComplete:
	case <-time.After(5 * time.Second):
		client.Close()
		t.Fatal("timed out gathering local ICE candidates")
	}
	local := client.LocalDescription()
	if local == nil {
		client.Close()
		t.Fatal("viewer local description is missing")
	}
	request.Offer = &dieterv1.RemoteDesktopSessionDescription{Type: "offer", Sdp: local.SDP}
	return client
}

func testControlViewer(t *testing.T, request *dieterv1.StartRemoteDesktopRequest) (*webrtc.PeerConnection, *webrtc.DataChannel) {
	t.Helper()
	settings := webrtc.SettingEngine{}
	settings.SetIncludeLoopbackCandidate(true)
	client, err := webrtc.NewAPI(webrtc.WithSettingEngine(settings)).NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
		client.Close()
		t.Fatal(err)
	}
	ordered := true
	stateChannel, err := client.CreateDataChannel(stateChannelLabel, &webrtc.DataChannelInit{Ordered: &ordered})
	if err != nil {
		client.Close()
		t.Fatal(err)
	}
	unordered := false
	zero := uint16(0)
	if _, err := client.CreateDataChannel(pointerChannelLabel, &webrtc.DataChannelInit{Ordered: &unordered, MaxRetransmits: &zero}); err != nil {
		client.Close()
		t.Fatal(err)
	}
	offer, err := client.CreateOffer(nil)
	if err != nil {
		client.Close()
		t.Fatal(err)
	}
	gatheringComplete := webrtc.GatheringCompletePromise(client)
	if err := client.SetLocalDescription(offer); err != nil {
		client.Close()
		t.Fatal(err)
	}
	select {
	case <-gatheringComplete:
	case <-time.After(5 * time.Second):
		client.Close()
		t.Fatal("timed out gathering controlled viewer candidates")
	}
	request.Offer = &dieterv1.RemoteDesktopSessionDescription{Type: "offer", Sdp: client.LocalDescription().SDP}
	return client, stateChannel
}
