package cli

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"google.golang.org/protobuf/encoding/protojson"
)

type configurableScreenFixture struct {
	mu    sync.Mutex
	event func(remotedesktop.SourceEvent)
}

func (*configurableScreenFixture) Codec() remotedesktop.VideoCodec {
	return remotedesktop.VideoCodecVP8
}
func (*configurableScreenFixture) Description() string { return "screen configuration fixture" }
func (*configurableScreenFixture) Stream(ctx context.Context, _ func(media.Sample) error) error {
	<-ctx.Done()
	return nil
}
func (*configurableScreenFixture) SendInput(context.Context, *dieterv1.RemoteDesktopInput) error {
	return nil
}
func (*configurableScreenFixture) ReleaseInput(context.Context) {}
func (*configurableScreenFixture) RequestKeyFrame()             {}
func (*configurableScreenFixture) SetBitrateKbps(int)           {}
func (s *configurableScreenFixture) SetEventHandler(event func(remotedesktop.SourceEvent)) {
	s.mu.Lock()
	s.event = event
	s.mu.Unlock()
}
func (s *configurableScreenFixture) Configure(_ context.Context, c remotedesktop.StreamConfiguration) error {
	s.mu.Lock()
	event := s.event
	s.mu.Unlock()
	if event != nil {
		event(remotedesktop.SourceEvent{State: &dieterv1.RemoteDesktopSessionState{Width: int32(c.MaxWidth), Height: int32(c.MaxHeight), Fps: int32(c.FPS), BitrateKbps: int32(c.BitrateKbps), DisplayId: c.DisplayID, DisplayGeneration: 1}})
	}
	return nil
}

func assertScreenSessionCLI(t *testing.T, client *CLI, output *bytes.Buffer, configuration *gatewayv1.RTCConfiguration) {
	t.Helper()
	var permissions dieterv1.RemoteDesktopPermissionProbe
	if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "screen", "permissions")), &permissions); err != nil {
		t.Fatal(err)
	}
	if !permissions.CaptureVerified || !permissions.ControlVerified || permissions.DaemonExecutable == "" {
		t.Fatalf("route permission probe: %v", &permissions)
	}
	runDaemonCLI(t, client, output, "daemon", "permissions", "--check")
	runDaemonCLI(t, client, output, "screen", "update", "--enabled=true", "--control=true")
	if configuration == nil {
		configuration = &gatewayv1.RTCConfiguration{}
		if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "machine", "rtc")), configuration); err != nil {
			t.Fatal(err)
		}
	}
	viewer, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer viewer.Close()
	if _, err = viewer.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo); err != nil {
		t.Fatal(err)
	}
	offer, err := viewer.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	request := &dieterv1.StartRemoteDesktopRequest{Control: true, Clipboard: true, InputProtocolVersion: 3, ClientName: "CLI fixture", ClientNonce: "cli-screen-" + client.transport.route, RtcConfiguration: configuration, Offer: &dieterv1.RemoteDesktopSessionDescription{Type: "offer", Sdp: offer.SDP}, MaxWidth: 1920, MaxHeight: 1080, MaxFps: 60, MaxBitrateKbps: 6000}
	raw, _ := protojson.Marshal(request)
	file := filepath.Join(t.TempDir(), "request.json")
	if err = os.WriteFile(file, raw, 0600); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(runDaemonCLI(t, client, output, "screen", "start", "--request", file, "--count", "2")), "\n")
	signal := &dieterv1.RemoteDesktopSignal{}
	if err = protojson.Unmarshal([]byte(lines[0]), signal); err != nil {
		t.Fatal(err)
	}
	id := signal.SessionId
	if id == "" {
		t.Fatal("missing session")
	}
	var state dieterv1.RemoteDesktopSessionState
	if err = protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "screen", "status", id)), &state); err != nil {
		t.Fatal(err)
	}
	if state.GetConfiguration().GetMaxFps() != 60 {
		t.Fatalf("initial state: %v", &state)
	}
	raw = []byte(runDaemonCLI(t, client, output, "screen", "configure", id, "--quality", "detail", "--fps", "24", "--bitrate", "2000", "--display", "2"))
	if err = protojson.Unmarshal(raw, &state); err != nil {
		t.Fatal(err)
	}
	if state.GetConfiguration().GetMaxFps() != 24 || state.GetConfiguration().GetMaxWidth() != 1920 || state.GetConfiguration().GetDisplayId() != "2" || state.GetConfiguration().GetQuality() != dieterv1.RemoteDesktopQuality_REMOTE_DESKTOP_QUALITY_DETAIL {
		t.Fatalf("changed state: %v", &state)
	}
	raw = []byte(runDaemonCLI(t, client, output, "screen", "configure", id, "--quality", "motion", "--fps", "120", "--width", "3840", "--height", "2160"))
	if err = protojson.Unmarshal(raw, &state); err != nil {
		t.Fatal(err)
	}
	if state.GetConfiguration().GetMaxFps() != 120 || state.GetConfiguration().GetMaxWidth() != 1920 || state.GetConfiguration().GetMaxHeight() != 1080 {
		t.Fatalf("high refresh configuration over %s: %v", client.transport.route, &state)
	}
	var sessions dieterv1.RemoteDesktopSessions
	if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "screen", "sessions")), &sessions); err != nil {
		t.Fatal(err)
	}
	if len(sessions.Sessions) != 1 || sessions.MaxClients != 4 || !sessions.Sessions[0].ControlActive {
		t.Fatalf("sessions: %v", &sessions)
	}
	for _, action := range []string{"release", "take"} {
		if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "screen", "control", action, id)), &state); err != nil {
			t.Fatal(err)
		}
		if state.ControlActive != (action == "take") {
			t.Fatalf("control %s: %v", action, &state)
		}
	}
	clipboardFile := filepath.Join(t.TempDir(), "clipboard.txt")
	clipboardText := "CLI clipboard\nUnicode: Grüße 🦊 日本語\n"
	if err := os.WriteFile(clipboardFile, []byte(clipboardText), 0600); err != nil {
		t.Fatal(err)
	}
	for _, action := range []string{"write", "paste"} {
		runDaemonCLI(t, client, output, "screen", "clipboard", action, id, "--file", clipboardFile)
		var result dieterv1.RemoteDesktopClipboardResponse
		if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "screen", "clipboard", "read", id)), &result); err != nil {
			t.Fatal(err)
		}
		if result.Text != clipboardText {
			t.Fatalf("clipboard round trip: %q", result.Text)
		}
	}
	runDaemonCLI(t, client, output, "screen", "clipboard", "disable", id)
	if err := client.Run([]string{"screen", "clipboard", "read", id}); err == nil {
		t.Fatal("disabled clipboard read succeeded")
	}
	runDaemonCLI(t, client, output, "screen", "clipboard", "enable", id)
	runDaemonCLI(t, client, output, "screen", "clipboard", "copy", id)
	runDaemonCLI(t, client, output, "screen", "refresh", id)
	runDaemonCLI(t, client, output, "screen", "close", id)
	output.Reset()
	if err = client.Run([]string{"screen", "status", id}); err == nil {
		t.Fatal("closed session still accessible")
	}
}
