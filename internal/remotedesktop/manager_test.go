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
}

func (s *blockingFrameSource) Description() string { return "blocking test source" }

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
	deadline := time.After(10 * time.Second)
	for binding == nil || !answerApplied {
		select {
		case <-deadline:
			t.Fatal("timed out waiting for signed binding and SDP answer")
		case signal := <-subscription.Signals:
			switch payload := signal.GetPayload().(type) {
			case *dieterv1.RemoteDesktopSignal_Binding:
				binding = payload.Binding
				offerHash := sha256.Sum256([]byte(request.GetOffer().GetSdp()))
				message := SessionBindingMessage(signal.GetSessionId(), binding.GetClientNonce(), binding.GetHelperDtlsFingerprint(), binding.GetExpiresAt(), offerHash[:])
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
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for a synthetic VP8 frame")
	}
	if err := manager.Signal(&dieterv1.RemoteDesktopSignal{SessionId: subscription.SessionID, Payload: &dieterv1.RemoteDesktopSignal_LeaseHeartbeat{LeaseHeartbeat: &emptypb.Empty{}}}); err != nil {
		t.Fatal(err)
	}
	if err := manager.Close(subscription.SessionID, "test complete"); err != nil {
		t.Fatal(err)
	}
}

func TestManagerRejectsRTCConfigurationFromAnotherOperator(t *testing.T) {
	manager, request, _ := testManagerAndRequest(t, "github:7")
	viewer := testViewer(t, request)
	defer viewer.Close()
	if _, err := manager.Start(request, true, false, "github:8"); err == nil {
		t.Fatal("expected operator-bound RTC configuration to be rejected")
	}
	if _, err := manager.Start(request, true, true, "github:7"); err != nil {
		// A view-only request remains valid even if the future control setting is on.
		t.Fatal(err)
	}
	manager.CloseActive("test complete")
	request.Control = true
	if _, err := manager.Start(request, true, true, "github:7"); err != ErrControlDisabled {
		t.Fatalf("control request error=%v, want %v", err, ErrControlDisabled)
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
	if _, err := manager.Start(request, true, false, "github:8"); !errors.Is(err, ErrBusy) {
		t.Fatalf("other operator reattach error=%v, want %v", err, ErrBusy)
	}
	manager.CloseActive("test complete")
}

func TestManagerCapabilityRequiresRealCaptureProbe(t *testing.T) {
	t.Setenv("DISPLAY", ":99")
	manager, _, _ := testManagerAndRequest(t, "github:7")
	manager.options.Source = SourceOptions{Kind: "screen", FFmpegPath: "/usr/bin/true"}
	manager.options.CaptureProbe = func(context.Context, SourceOptions) error {
		return errors.New("macOS Screen Recording permission is not granted to FFmpeg")
	}
	capabilities := manager.Capabilities(true, false)
	if capabilities.GetReady() || capabilities.GetCapturePermission() != "denied" {
		t.Fatalf("capabilities=%#v", capabilities)
	}
	if capabilities.GetUnavailableReason() != "macOS Screen Recording permission is not granted to FFmpeg" {
		t.Fatalf("unavailable reason=%q", capabilities.GetUnavailableReason())
	}

	manager.probe = captureProbeResult{}
	manager.options.CaptureProbe = func(context.Context, SourceOptions) error { return nil }
	capabilities = manager.Capabilities(true, false)
	if !capabilities.GetReady() || capabilities.GetCapturePermission() != "granted" {
		t.Fatalf("capabilities after permission=%#v", capabilities)
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
