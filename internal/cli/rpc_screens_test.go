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
func (*configurableScreenFixture) RequestKeyFrame()   {}
func (*configurableScreenFixture) SetBitrateKbps(int) {}
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
	runDaemonCLI(t, client, output, "screen", "update", "--enabled=true")
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
	request := &dieterv1.StartRemoteDesktopRequest{ClientNonce: "cli-screen-" + client.transport.route, RtcConfiguration: configuration, Offer: &dieterv1.RemoteDesktopSessionDescription{Type: "offer", Sdp: offer.SDP}, MaxWidth: 1920, MaxHeight: 1080, MaxFps: 60, MaxBitrateKbps: 6000}
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
	runDaemonCLI(t, client, output, "screen", "refresh", id)
	runDaemonCLI(t, client, output, "screen", "close", id)
	output.Reset()
	if err = client.Run([]string{"screen", "status", id}); err == nil {
		t.Fatal("closed session still accessible")
	}
}
