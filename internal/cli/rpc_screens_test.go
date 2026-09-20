package cli

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/pion/webrtc/v4"
	"github.com/pion/webrtc/v4/pkg/media"
	"google.golang.org/protobuf/encoding/protojson"
)

var errScreenAnswerCollected = errors.New("fixture collected screen answer")

type screenAnswerOutput struct{ *bytes.Buffer }

func (w screenAnswerOutput) Write(raw []byte) (int, error) {
	n, err := w.Buffer.Write(raw)
	var value dieterv1.RemoteDesktopSignal
	if protojson.Unmarshal(bytes.TrimSpace(raw), &value) == nil && value.GetDescription() != nil {
		return n, errScreenAnswerCollected
	}
	return n, err
}

type configurableScreenFixture struct {
	mu    sync.Mutex
	event func(remotedesktop.SourceEvent)
	state *dieterv1.RemoteDesktopSessionState
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
	state := s.state
	s.mu.Unlock()
	if state != nil {
		event(remotedesktop.SourceEvent{State: state})
	}
}
func (s *configurableScreenFixture) Configure(_ context.Context, c remotedesktop.StreamConfiguration) error {
	s.mu.Lock()
	s.state = &dieterv1.RemoteDesktopSessionState{Width: int32(c.MaxWidth), Height: int32(c.MaxHeight), Fps: int32(c.FPS), BitrateKbps: int32(c.BitrateKbps), DisplayId: c.DisplayID, DisplayGeneration: 1, EncoderConfiguration: "fixture accepted realtime"}
	state := s.state
	event := s.event
	s.mu.Unlock()
	if event != nil {
		event(remotedesktop.SourceEvent{State: state})
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
	settings := webrtc.SettingEngine{}
	settings.SetIncludeLoopbackCandidate(true)
	viewer, err := webrtc.NewAPI(webrtc.WithSettingEngine(settings)).NewPeerConnection(webrtc.Configuration{})
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
	gathered := webrtc.GatheringCompletePromise(viewer)
	if err := viewer.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	select {
	case <-gathered:
	case <-time.After(5 * time.Second):
		t.Fatal("fixture ICE gathering timed out")
	}
	offer = *viewer.LocalDescription()
	request := &dieterv1.StartRemoteDesktopRequest{Control: true, Clipboard: true, InputProtocolVersion: 1, ClientName: "CLI fixture", ClientNonce: "cli-screen-" + client.transport.route, RtcConfiguration: configuration, Offer: &dieterv1.RemoteDesktopSessionDescription{Type: "offer", Sdp: offer.SDP}, MaxWidth: 1920, MaxHeight: 1080, MaxFps: 60, MaxBitrateKbps: 6000}
	raw, _ := protojson.Marshal(request)
	file := filepath.Join(t.TempDir(), "request.json")
	if err = os.WriteFile(file, raw, 0600); err != nil {
		t.Fatal(err)
	}
	// Strict HEVC reaches the same core negotiation policy over every CLI route;
	// this VP8 fixture cannot silently satisfy a forced HEVC request.
	if err := client.Run([]string{"screen", "start", "--request", file, "--codec", "hevc", "--count", "2"}); err == nil || !strings.Contains(err.Error(), "HEVC requires") {
		t.Fatalf("strict HEVC over %s: %v", client.transport.route, err)
	}
	// Candidate/state ordering varies with ICE. Stop after the actual answer,
	// not an assumed signal count, without ending the durable screen session.
	output.Reset()
	client.Out = screenAnswerOutput{output}
	err = client.Run([]string{"screen", "start", "--request", file, "--codec", "auto", "--reference-recovery"})
	client.Out = output
	if !errors.Is(err, errScreenAnswerCollected) {
		t.Fatalf("collect screen answer: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	signal := &dieterv1.RemoteDesktopSignal{}
	if err = protojson.Unmarshal([]byte(lines[0]), signal); err != nil {
		t.Fatal(err)
	}
	id := signal.SessionId
	if id == "" {
		t.Fatal("missing session")
	}
	for _, line := range lines {
		var value dieterv1.RemoteDesktopSignal
		if err := protojson.Unmarshal([]byte(line), &value); err != nil {
			t.Fatal(err)
		}
		if answer := value.GetDescription(); answer != nil {
			if err := viewer.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: answer.Sdp}); err != nil {
				t.Fatal(err)
			}
		}
	}
	if viewer.RemoteDescription() == nil {
		t.Fatal("CLI start did not return the answer")
	}
	addCandidate := func(signal *dieterv1.RemoteDesktopSignal) error {
		candidate := signal.GetCandidate()
		if candidate == nil {
			return nil
		}
		mid, username := candidate.GetSdpMid(), candidate.GetUsernameFragment()
		index := uint16(max(0, int(candidate.GetSdpMlineIndex())))
		return viewer.AddICECandidate(webrtc.ICECandidateInit{Candidate: candidate.GetCandidate(), SDPMid: &mid, SDPMLineIndex: &index, UsernameFragment: &username})
	}
	for _, line := range lines {
		var signal dieterv1.RemoteDesktopSignal
		if err = protojson.Unmarshal([]byte(line), &signal); err != nil {
			t.Fatal(err)
		}
		if err = addCandidate(&signal); err != nil {
			t.Fatal(err)
		}
	}
	// Reattach signaling while exercising the unary CLI commands. The initial
	// collector deliberately disconnects after the answer; leaving it detached
	// races the production grace timeout on slower race-enabled test runs.
	request.ReferenceRecovery = true
	observerCtx, cancelObserver := context.WithCancel(context.Background())
	defer cancelObserver()
	observer, err := client.transport.client.StartRemoteDesktop(client.transport.context(observerCtx), request)
	if err != nil {
		t.Fatal(err)
	}
	firstSignal, err := observer.Recv()
	if err != nil {
		t.Fatal(err)
	}
	if err = addCandidate(firstSignal); err != nil {
		t.Fatal(err)
	}
	observerDone := make(chan struct{})
	go func() {
		defer close(observerDone)
		for {
			signal, err := observer.Recv()
			if err != nil {
				return
			}
			_ = addCandidate(signal)
		}
	}()
	defer func() { cancelObserver(); <-observerDone }()
	var modes dieterv1.RemoteDesktopDisplayModes
	if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "screen", "resolution", "modes", id)), &modes); err != nil {
		t.Fatal(err)
	}
	if modes.CurrentModeId != "1080" || len(modes.Modes) != 2 {
		t.Fatalf("display modes: %v", &modes)
	}
	changed := runDaemonCLI(t, client, output, "screen", "resolution", "set", id, "--display", modes.DisplayId, "--mode", "720", "--expected-current", "1080")
	if err := protojson.Unmarshal([]byte(changed), &modes); err != nil || !modes.Temporary || modes.CurrentModeId != "720" {
		t.Fatalf("set display: %v %v", &modes, err)
	}
	if err := client.Run([]string{"screen", "resolution", "set", id, "--display", modes.DisplayId, "--mode", "720", "--expected-current", "1080"}); err == nil {
		t.Fatal("stale display mode accepted")
	}
	restored := runDaemonCLI(t, client, output, "screen", "resolution", "restore", id)
	if err := protojson.Unmarshal([]byte(restored), &modes); err != nil || modes.Temporary || modes.CurrentModeId != "1080" {
		t.Fatalf("restore display: %v %v", &modes, err)
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
	// Encoder diagnostics are asynchronous, and only exist after ICE starts
	// the capture source. Exercise the real status operation on every route.
	for deadline := time.Now().Add(10 * time.Second); state.GetEncoderConfiguration() == "" && time.Now().Before(deadline); {
		time.Sleep(20 * time.Millisecond)
		if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "screen", "status", id)), &state); err != nil {
			t.Fatal(err)
		}
	}
	if state.GetEncoderConfiguration() != "fixture accepted realtime" {
		t.Fatalf("encoder diagnostics lost over %s: %v", client.transport.route, &state)
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

	binary := bytes.Repeat([]byte{0, 255, 10, 17}, 600000)
	binaryFile := filepath.Join(t.TempDir(), "blob.bin")
	if err := os.WriteFile(binaryFile, binary, 0600); err != nil {
		t.Fatal(err)
	}
	emptyFile := filepath.Join(t.TempDir(), "empty.txt")
	if err := os.WriteFile(emptyFile, nil, 0600); err != nil {
		t.Fatal(err)
	}
	runDaemonCLI(t, client, output, "screen", "clipboard", "paste", id, "--attach", binaryFile, "--attach", emptyFile)
	destination := filepath.Join(t.TempDir(), "received")
	runDaemonCLI(t, client, output, "screen", "clipboard", "read", id, "--output-dir", destination)
	received, err := os.ReadFile(filepath.Join(destination, "blob.bin"))
	if err != nil || !bytes.Equal(received, binary) {
		t.Fatalf("binary round trip over %s: %v", client.transport.route, err)
	}
	empty, err := os.ReadFile(filepath.Join(destination, "empty.txt"))
	if err != nil || len(empty) != 0 {
		t.Fatal("empty file lost")
	}
	if err := client.Run([]string{"screen", "clipboard", "read", id, "--output-dir", destination}); err == nil {
		t.Fatal("output directory overwritten")
	}
	png, err := base64.StdEncoding.DecodeString("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aCWQAAAAASUVORK5CYII=")
	if err != nil {
		t.Fatal(err)
	}
	pngFile := filepath.Join(t.TempDir(), "pixel.png")
	if err := os.WriteFile(pngFile, png, 0600); err != nil {
		t.Fatal(err)
	}
	runDaemonCLI(t, client, output, "screen", "clipboard", "paste", id, "--image", pngFile)
	var imageResult dieterv1.RemoteDesktopClipboardResponse
	if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "screen", "clipboard", "read", id)), &imageResult); err != nil {
		t.Fatal(err)
	}
	if len(imageResult.Items) != 1 || imageResult.Items[0].Kind != dieterv1.RemoteDesktopClipboardItem_IMAGE || !bytes.Equal(imageResult.Items[0].Data, png) {
		t.Fatal("clipboard image round trip failed")
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

func TestScreenClipboardRecognizesNativeTIFF(t *testing.T) {
	for _, header := range []string{"II*\x00", "MM\x00*"} {
		if got := screenClipboardMIME([]byte(header)); got != "image/tiff" {
			t.Fatalf("TIFF identified as %s", got)
		}
	}
	if got := screenClipboardMIME([]byte("ordinary text")); got == "image/tiff" {
		t.Fatal("text identified as image")
	}
}

func TestScreenStartRejectsInvalidCodecOffline(t *testing.T) {
	client := &CLI{Out: &bytes.Buffer{}}
	err := client.rpcScreenStart([]string{"--request", "not-read.json", "--codec", "av1"})
	if err == nil || err.Error() != "codec must be auto, h264, or hevc" {
		t.Fatalf("codec validation: %v", err)
	}
}
