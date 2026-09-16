package remotedesktop

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/webrtc/v4/pkg/media"
)

func TestNativeHelperBaselineUsesLowLatencyHardware(t *testing.T) {
	path := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if path == "" {
		t.Skip("native helper not configured")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	source, err := NewFrameSource(SourceOptions{Kind: "native-synthetic", HelperPath: path, Profile: "baseline", FPS: 60, MaxWidth: 1280, MaxHeight: 720, Bitrate: 4000})
	if err != nil {
		t.Fatal(err)
	}
	complete := errors.New("baseline frames verified")
	frames := 0
	err = source.Stream(ctx, func(sample media.Sample) error {
		if frames == 0 && (len(sample.Data) < 7 || !bytes.Equal(sample.Data[:4], []byte{0, 0, 0, 1}) || sample.Data[4]&0x1f != 7 || sample.Data[5] != 66 || sample.Data[6]&0x40 == 0) {
			t.Errorf("baseline negotiation produced a different SPS profile: %x", sample.Data[:min(64, len(sample.Data))])
		}
		frames++
		if frames == 12 {
			return complete
		}
		return nil
	})
	if !errors.Is(err, complete) {
		t.Fatalf("baseline capture failed after %d frames: %v", frames, err)
	}
}

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
	// Rate recovery must update the live encoder without an IDR burst or a
	// display-generation reset. Observe well inside the ten-second IDR interval.
	if err := adaptive.Configure(ctx, StreamConfiguration{DisplayID: "primary", MaxWidth: 1920, MaxHeight: 1080, FPS: 45, BitrateKbps: 6000}); err != nil {
		t.Fatal(err)
	}
	for range 30 {
		m := waitFrame(func(FrameMetadata) bool { return true })
		if m.Generation != first.Generation || m.KeyFrame || m.Width != 1920 || m.Height != 1080 {
			t.Fatalf("bitrate/FPS-only update reset the hardware stream: %+v", m)
		}
	}
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
		if metadata.Discontinuity || metadata.KeyFrame || metadata.ID != 2 || metadata.Dropped == 0 {
			t.Fatalf("backpressure must replace raw frames without breaking H.264 references: %+v", metadata)
		}
		if metadata.CaptureDelay > 100*time.Millisecond {
			t.Fatalf("resumed encoder used a stale raw frame: %+v", metadata)
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

func TestNativeMultiplexSharesEncoderAndIsolatesRenditions(t *testing.T) {
	path := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if path == "" {
		t.Skip("native helper not configured")
	}
	pool := newCapturePool(NewFrameSource)
	defer pool.Close()
	options := SourceOptions{Kind: "native-synthetic", HelperPath: path, Profile: "high", Control: true, FPS: 60, MaxWidth: 1280, MaxHeight: 720, Bitrate: 4000}
	first, err := pool.Subscribe(options)
	if err != nil {
		t.Fatal(err)
	}
	second, err := pool.Subscribe(options)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	frames := make(chan FrameMetadata, 128)
	slowFrames := make(chan FrameMetadata, 128)
	failures := make(chan error, 2)
	first.(AdaptiveFrameSource).SetEventHandler(func(SourceEvent) {})
	second.(AdaptiveFrameSource).SetEventHandler(func(SourceEvent) {})
	go func() {
		failures <- first.Stream(ctx, func(s media.Sample) error {
			select {
			case frames <- s.Metadata.(FrameMetadata):
			default:
			}
			return nil
		})
	}()
	go func() {
		failures <- second.Stream(ctx, func(s media.Sample) error {
			select {
			case slowFrames <- s.Metadata.(FrameMetadata):
			default:
			}
			return nil
		})
	}()
	waitFrame := func(ch <-chan FrameMetadata, width int) {
		t.Helper()
		for {
			select {
			case frame := <-ch:
				if int(frame.Width) == width {
					return
				}
			case err := <-failures:
				if err != nil {
					t.Fatalf("native stream: %v", err)
				}
			case <-ctx.Done():
				t.Fatal("native multiplex frame timeout")
			}
		}
	}
	waitFrame(frames, 1280)
	waitFrame(slowFrames, 1280)
	if _, n := pool.Counts(); n != 1 {
		t.Fatal("duplicate native encoder")
	}
	config := sourceConfiguration(options)
	config.MaxWidth = 640
	config.MaxHeight = 360
	if err := second.(AdaptiveFrameSource).Configure(ctx, config); err != nil {
		t.Fatal(err)
	}
	waitFrame(slowFrames, 640)
	waitFrame(frames, 1280)
	if _, n := pool.Counts(); n != 2 {
		t.Fatal("rendition split missing")
	}
	if err := second.(AdaptiveFrameSource).Configure(ctx, sourceConfiguration(options)); err != nil {
		t.Fatal(err)
	}
	waitFrame(slowFrames, 1280)
	if _, n := pool.Counts(); n != 1 {
		t.Fatal("native rendition not merged")
	}
	second.(*sharedSource).Close()
	waitFrame(frames, 1280)
	// Retire an encoder while its next callback may already be in flight.
	// The primary lane must survive; this catches native refcon lifetime bugs.
	for i := 0; i < 16; i++ {
		options.MaxWidth = 640
		options.MaxHeight = 360
		other, e := pool.Subscribe(options)
		if e != nil {
			t.Fatal(e)
		}
		incoming := make(chan FrameMetadata, 1)
		go func() {
			_ = other.Stream(ctx, func(s media.Sample) error {
				select {
				case incoming <- s.Metadata.(FrameMetadata):
				default:
				}
				return nil
			})
		}()
		waitFrame(incoming, 640)
		other.(*sharedSource).Close()
		for j := 0; j < 4; j++ {
			waitFrame(frames, 1280)
		}
	}
}

func TestNativeFourIndependentHardwareRenditions(t *testing.T) {
	path := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if path == "" {
		t.Skip("native helper not configured")
	}
	pool := newCapturePool(NewFrameSource)
	defer pool.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	frames := make(chan int, 4)
	failures := make(chan error, 4)
	for i, width := range []int{640, 960, 1280, 1920} {
		source, err := pool.Subscribe(SourceOptions{Kind: "native-synthetic", HelperPath: path, Profile: "high", FPS: 30, MaxWidth: width, MaxHeight: width * 9 / 16, Bitrate: 4000})
		if err != nil {
			t.Fatal(err)
		}
		go func() {
			count := 0
			failures <- source.Stream(ctx, func(sample media.Sample) error {
				count++
				if count == 5 {
					frames <- i
				}
				return nil
			})
		}()
	}
	received := map[int]bool{}
	for len(received) < 4 {
		select {
		case i := <-frames:
			received[i] = true
		case err := <-failures:
			t.Fatalf("four native encoders: %v", err)
		case <-ctx.Done():
			t.Fatal("four native encoders timed out")
		}
	}
	if _, encoders := pool.Counts(); encoders != 4 {
		t.Fatalf("encoders=%d", encoders)
	}
	if _, err := pool.Subscribe(SourceOptions{Kind: "native-synthetic", HelperPath: path, Profile: "baseline", FPS: 30, MaxWidth: 640, MaxHeight: 360, Bitrate: 4000}); err == nil {
		t.Fatal("unbounded fifth encoder")
	}
}

func TestNativeCancelledLifecyclePreservesExistingViewer(t *testing.T) {
	path := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if path == "" {
		t.Skip("native helper not configured")
	}
	mux := newNativeMultiplexer()
	defer mux.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	makeSource := func() *nativeRendition {
		t.Helper()
		source, err := mux.Source(&nativeHelperSource{path: path, synthetic: true, profile: "high", fps: 30, maxWidth: 640, maxHeight: 360, bitrateKbps: 2000})
		if err != nil {
			t.Fatal(err)
		}
		return source.(*nativeRendition)
	}
	primary := makeSource()
	defer primary.Close()
	frames := make(chan struct{}, 1)
	failure := make(chan error, 1)
	go func() {
		failure <- primary.Stream(ctx, func(media.Sample) error {
			select {
			case frames <- struct{}{}:
			default:
			}
			return nil
		})
	}()
	waitFrame := func() {
		t.Helper()
		select {
		case <-frames:
		case err := <-failure:
			t.Fatalf("existing viewer stopped: %v", err)
		case <-ctx.Done():
			t.Fatal("existing viewer stalled")
		}
	}
	waitFrame()
	for iteration := range 32 {
		source := makeSource()
		finished := make(chan error, 1)
		ready := make(chan struct{}, 1)
		go func() {
			finished <- source.Stream(ctx, func(media.Sample) error {
				select {
				case ready <- struct{}{}:
				default:
				}
				return nil
			})
		}()
		for {
			mux.mu.Lock()
			creating := source.createSent
			mux.mu.Unlock()
			if creating {
				break
			}
			select {
			case err := <-finished:
				t.Fatalf("encoder failed before admission: %v", err)
			case <-ctx.Done():
				t.Fatal("encoder admission timed out")
			case <-time.After(time.Millisecond):
			}
		}
		var configured chan error
		if iteration%2 == 1 {
			select {
			case <-ready:
			case err := <-finished:
				t.Fatalf("encoder startup failed: %v", err)
			case <-ctx.Done():
				t.Fatal("encoder produced no media")
			}
			configured = make(chan error, 1)
			go func() {
				configured <- source.Configure(ctx, StreamConfiguration{DisplayID: "primary", MaxWidth: 1920, MaxHeight: 1080, FPS: 30, BitrateKbps: 4000})
			}()
			time.Sleep(time.Millisecond)
		}
		// Alternate cancellation during creation and a hardware encoder reset.
		// A replacement must wait for fully completed removal in both cases.
		source.Close()
		select {
		case <-finished:
		case <-ctx.Done():
			t.Fatal("cancelled encoder did not finish")
		}
		if configured != nil {
			select {
			case <-configured:
			case <-ctx.Done():
				t.Fatal("cancelled configuration did not finish")
			}
		}
		waitFrame()
	}
	// Demand fresh media after the final retirement, not a previously buffered frame.
	waitFrame()
	waitFrame()
}
