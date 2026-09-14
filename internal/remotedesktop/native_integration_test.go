package remotedesktop

import (
	"bytes"
	"context"
	"io"
	"os"
	"os/exec"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/webrtc/v4/pkg/media"
)

// Runs the real signed helper and hardware VideoToolbox encoder. Synthetic
// pixels and dry-run injection keep this test independent of desktop permissions.
func TestNativeHelperHardwareLifecycle(t *testing.T) {
	path := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if path == "" {
		t.Skip("set DIETER_TEST_CAPTURE_HELPER to the built macOS helper")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	source, err := NewFrameSource(SourceOptions{Kind: "native-synthetic", HelperPath: path, Profile: "high", Control: true, FPS: 60, MaxWidth: 1920, MaxHeight: 1080, Bitrate: 4000})
	if err != nil {
		t.Fatal(err)
	}
	frames := make(chan media.Sample, 32)
	done := make(chan error, 1)
	go func() {
		done <- source.Stream(ctx, func(s media.Sample) error {
			select {
			case frames <- s:
			case <-ctx.Done():
				return ctx.Err()
			}
			return nil
		})
	}()
	waitFrame := func(predicate func(FrameMetadata) bool) FrameMetadata {
		t.Helper()
		for {
			select {
			case f := <-frames:
				m := f.Metadata.(FrameMetadata)
				if predicate(m) {
					return m
				}
			case err := <-done:
				t.Fatalf("helper exited: %v", err)
			case <-ctx.Done():
				t.Fatal("hardware frame deadline exceeded")
			}
		}
	}
	first := waitFrame(func(m FrameMetadata) bool { return m.KeyFrame })
	if first.Width != 1920 || first.Height != 1080 {
		t.Fatalf("initial geometry: %+v", first)
	}
	measurement := waitFrame(func(m FrameMetadata) bool { return m.ID > first.ID+5 })
	var totalEncode time.Duration
	var measured FrameMetadata
	for range 60 {
		measured = waitFrame(func(FrameMetadata) bool { return true })
		totalEncode += measured.EncodeTime
	}
	t.Logf("1080p hardware throughput %.1f fps, mean encode %s (synthetic changing NV12)", 60/(measured.PTS-measurement.PTS).Seconds(), totalEncode/60)
	sink := source.(InputSink)
	for _, down := range []bool{true, false} {
		input := &dieterv1.RemoteDesktopInput{DisplayGeneration: first.Generation, Payload: &dieterv1.RemoteDesktopInput_Key{Key: &dieterv1.RemoteDesktopKey{KeyCode: 0, PhysicalKey: 4, Down: down}}}
		if err := sink.SendInput(ctx, input); err != nil {
			t.Fatalf("key down=%t not acknowledged: %v", down, err)
		}
		input.Payload = &dieterv1.RemoteDesktopInput_PointerButton{PointerButton: &dieterv1.RemoteDesktopPointerButton{Button: dieterv1.RemoteDesktopPointerButton_BUTTON_LEFT, Down: down, NormalizedX: 0, NormalizedY: 0}}
		if err := sink.SendInput(ctx, input); err != nil {
			t.Fatalf("button down=%t not acknowledged: %v", down, err)
		}
	}
	adaptive := source.(AdaptiveFrameSource)
	if err := adaptive.Configure(ctx, StreamConfiguration{DisplayID: "primary", MaxWidth: 1280, MaxHeight: 720, FPS: 15, BitrateKbps: 1500}); err != nil {
		t.Fatal(err)
	}
	changed := waitFrame(func(m FrameMetadata) bool { return m.Generation > first.Generation && m.KeyFrame })
	if changed.Width != 1280 || changed.Height != 720 || changed.PTS <= first.PTS {
		t.Fatalf("reconfigured frame: %+v", changed)
	}
	stale := &dieterv1.RemoteDesktopInput{DisplayGeneration: first.Generation, Payload: &dieterv1.RemoteDesktopInput_Key{Key: &dieterv1.RemoteDesktopKey{Down: true}}}
	if err := sink.SendInput(ctx, stale); err == nil {
		t.Fatal("stale display input was accepted")
	}
	sink.ReleaseInput(ctx)
	time.Sleep(250 * time.Millisecond)
	adaptive.RequestKeyFrame()
	refreshed := waitFrame(func(m FrameMetadata) bool { return m.KeyFrame && m.PTS > changed.PTS })
	t.Logf("hardware frame %dx%d encode=%s capture=%s; reconfigured %dx%d; refresh PTS=%s", first.Width, first.Height, first.EncodeTime, first.CaptureDelay, changed.Width, changed.Height, refreshed.PTS)
	cancel()
	select {
	case <-done:
	case <-time.After(4 * time.Second):
		t.Fatal("native helper did not reap after cancellation")
	}
}

func TestNativeHelperKeepsInputResponsiveUnderMediaBackpressure(t *testing.T) {
	path := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if path == "" {
		t.Skip("native helper not configured")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	source, err := NewFrameSource(SourceOptions{Kind: "native-synthetic", HelperPath: path, Profile: "high", Control: true, FPS: 60, MaxWidth: 1280, MaxHeight: 720, Bitrate: 4000})
	if err != nil {
		t.Fatal(err)
	}
	held := make(chan struct{})
	resume := make(chan struct{})
	observed := make(chan FrameMetadata, 1)
	done := make(chan error, 1)
	go func() {
		first := true
		done <- source.Stream(ctx, func(sample media.Sample) error {
			if first {
				first = false
				close(held)
				select {
				case <-resume:
				case <-ctx.Done():
					return ctx.Err()
				}
			} else {
				select {
				case observed <- sample.Metadata.(FrameMetadata):
				default:
				}
			}
			return nil
		})
	}()
	select {
	case <-held:
	case err := <-done:
		t.Fatal(err)
	case <-ctx.Done():
		t.Fatal("first frame timeout")
	}
	time.Sleep(200 * time.Millisecond)
	started := time.Now()
	if err := source.(InputSink).SendInput(ctx, &dieterv1.RemoteDesktopInput{DisplayGeneration: 1, Payload: &dieterv1.RemoteDesktopInput_Key{Key: &dieterv1.RemoteDesktopKey{KeyCode: 0, Down: false}}}); err != nil {
		t.Fatal(err)
	}
	if time.Since(started) > 500*time.Millisecond {
		t.Fatal("video backpressure blocked input")
	}
	close(resume)
	select {
	case metadata := <-observed:
		if !metadata.Discontinuity || metadata.Dropped == 0 {
			t.Fatalf("replacement lost reference discontinuity: %+v", metadata)
		}
	case <-ctx.Done():
		t.Fatal("replacement frame missing")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(4 * time.Second):
		t.Fatal("helper did not stop")
	}
}

func TestNativeHelperWatchdogExitsWithoutDaemonHeartbeat(t *testing.T) {
	path := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if path == "" {
		t.Skip("native helper not configured")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, path, "--synthetic", "true")
	stdin, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	defer stdin.Close()
	command.Stdout = io.Discard
	var stderr bytes.Buffer
	command.Stderr = &stderr
	started := time.Now()
	if err := command.Run(); err != nil {
		t.Fatalf("watchdog: %v %s", err, stderr.String())
	}
	if elapsed := time.Since(started); elapsed < 2500*time.Millisecond || elapsed > 6*time.Second {
		t.Fatalf("watchdog deadline: %s", elapsed)
	}
}
