//go:build linux

package remotedesktop

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/webrtc/v4/pkg/media"
)

func TestLinuxNativeScreenCapabilitiesRequireInstalledHelper(t *testing.T) {
	capabilities := New(Options{Source: SourceOptions{Kind: "screen", HelperPath: t.TempDir() + "/missing"}}).Capabilities(false, false)
	if capabilities.GetReady() || len(capabilities.GetDisplays()) != 0 || len(capabilities.GetCodecs()) != 0 || capabilities.GetHelperVersion() != "" {
		t.Fatalf("missing Linux helper advertised resources: %#v", capabilities)
	}
	if capabilities.GetUnavailableReason() != "Dieter native screen-capture helper is unavailable" {
		t.Fatalf("reason = %q", capabilities.GetUnavailableReason())
	}
}

func TestLinuxPortalPermissionIsPromptable(t *testing.T) {
	manager, _, _ := testManagerAndRequest(t, "github:7")
	manager.options.Source = SourceOptions{Kind: "screen", HelperPath: "/bin/true"}
	manager.options.CapabilityProbe = func(context.Context, SourceOptions) (*dieterv1.RemoteDesktopCapabilities, error) {
		return &dieterv1.RemoteDesktopCapabilities{
			Platform:                 "linux",
			GraphicalSessionActive:   true,
			CapturePermission:        "not_requested",
			ControlPermission:        "not_requested",
			ControlSupported:         true,
			HardwareEncoderAvailable: true,
			Displays:                 []*dieterv1.RemoteDesktopDisplay{{Id: "portal", Primary: true}},
			Codecs:                   []string{"H264"},
		}, nil
	}
	capabilities := manager.Capabilities(true, true)
	if !capabilities.GetReady() || capabilities.GetCapturePermission() != "not_requested" || capabilities.GetControlPermission() != "not_requested" {
		t.Fatalf("portal capabilities = %#v", capabilities)
	}
}

func TestLinuxPermissionRequestUsesOneCombinedPortalProbe(t *testing.T) {
	var captureControl, controlControl, requested bool
	manager := New(Options{
		Source: SourceOptions{Kind: "screen", HelperPath: "/bin/true"},
		CaptureProbe: func(_ context.Context, options SourceOptions) error {
			captureControl = options.Control
			return nil
		},
		ControlProbe: func(_ context.Context, options SourceOptions, request bool) error {
			controlControl, requested = options.Control, request
			return nil
		},
	})
	result, err := manager.ProbePermissions(context.Background(), true)
	if err != nil {
		t.Fatal(err)
	}
	if !result.GetCaptureVerified() || !result.GetControlVerified() || !captureControl || !controlControl || requested {
		t.Fatalf("combined Linux portal probe = %#v, captureControl=%v controlControl=%v requested=%v", result, captureControl, controlControl, requested)
	}
}

func TestLinuxCapturePoolHonorsHostControlPolicy(t *testing.T) {
	for _, expected := range []bool{false, true} {
		t.Run(map[bool]string{false: "view-only", true: "control"}[expected], func(t *testing.T) {
			observed := !expected
			pool := newCapturePool(func(options SourceOptions) (FrameSource, error) {
				observed = options.Control
				return &syntheticSource{interval: time.Second / 30}, nil
			})
			defer pool.Close()
			_, err := pool.Subscribe(SourceOptions{Kind: "screen", Control: expected, FPS: 30, MaxWidth: 640, MaxHeight: 360, Bitrate: 1500})
			if err != nil {
				t.Fatal(err)
			}
			if observed != expected {
				t.Fatalf("helper control = %v, want %v", observed, expected)
			}
		})
	}
}

func TestLinuxCapturePoolDoesNotReuseViewOnlyHelperForControl(t *testing.T) {
	var observed []bool
	pool := newCapturePool(func(options SourceOptions) (FrameSource, error) {
		observed = append(observed, options.Control)
		return &nativeHelperSource{
			codec: options.Codec, inputAllowed: options.Control,
			fps: options.FPS, bitrateKbps: options.Bitrate,
			maxWidth: options.MaxWidth, maxHeight: options.MaxHeight,
		}, nil
	})
	defer pool.Close()
	base := SourceOptions{Kind: "screen", FPS: 30, MaxWidth: 640, MaxHeight: 360, Bitrate: 1500}
	view, err := pool.Subscribe(base)
	if err != nil {
		t.Fatal(err)
	}
	base.Control = true
	control, err := pool.Subscribe(base)
	if err != nil {
		t.Fatal(err)
	}
	if len(observed) != 2 || observed[0] || !observed[1] {
		t.Fatalf("helper control policies = %v, want [false true]", observed)
	}
	viewMux := view.(*sharedSource).variant.source.(*nativeRendition).mux
	controlMux := control.(*sharedSource).variant.source.(*nativeRendition).mux
	if viewMux == controlMux {
		t.Fatal("view-only and control-capable Linux sources shared one native helper")
	}
}

func TestLinuxNativeRealCaptureProbe(t *testing.T) {
	if os.Getenv("DIETER_TEST_LINUX_CAPTURE_REAL") != "1" {
		t.Skip("set DIETER_TEST_LINUX_CAPTURE_REAL=1 for an authorized disposable frame probe")
	}
	helper := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if helper == "" {
		t.Fatal("DIETER_TEST_CAPTURE_HELPER is required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := ProbeCapture(ctx, SourceOptions{Kind: "screen", HelperPath: helper, FPS: 30, MaxWidth: 640, MaxHeight: 360, Bitrate: 1500}); err != nil {
		t.Fatal(err)
	}
}

func TestLinuxNativeStartupAllowsPortalConsentDelay(t *testing.T) {
	helper := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if helper == "" {
		t.Skip("Linux capture helper not configured")
	}
	t.Setenv("DIETER_TEST_CAPTURE_START_DELAY_MS", "4000")
	options := SourceOptions{Kind: "native-synthetic", HelperPath: helper, FPS: 30, MaxWidth: 640, MaxHeight: 360, Bitrate: 1500}
	t.Run("direct", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := ProbeCapture(ctx, options); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("multiplex", func(t *testing.T) {
		mux := newNativeMultiplexer()
		defer mux.Close()
		source, err := NewFrameSource(options)
		if err != nil {
			t.Fatal(err)
		}
		rendition, err := mux.Source(source.(*nativeHelperSource))
		if err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		err = rendition.Stream(ctx, func(media.Sample) error { return errCaptureProbeComplete })
		if !errors.Is(err, errCaptureProbeComplete) {
			t.Fatal(err)
		}
	})
}

func TestLinuxNativeX11CaptureAndControl(t *testing.T) {
	helper, target := os.Getenv("DIETER_TEST_CAPTURE_HELPER"), os.Getenv("DIETER_TEST_X11_TARGET")
	if helper == "" || target == "" {
		t.Skip("Linux X11 helper target not configured")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, target)
	stdout, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	command.Stderr = &stderr
	if err = command.Start(); err != nil {
		t.Fatal(err)
	}
	scanner := bufio.NewScanner(stdout)
	if !scanner.Scan() || strings.TrimSpace(scanner.Text()) != "READY" {
		t.Fatalf("X11 target did not become ready: %s", stderr.String())
	}

	pool := newCapturePool(NewFrameSource)
	defer pool.Close()
	source, err := pool.Subscribe(SourceOptions{Kind: "screen", HelperPath: helper, Control: true, EmbeddedCursor: false, FPS: 30, MaxWidth: 640, MaxHeight: 360, Bitrate: 1500})
	if err != nil {
		t.Fatal(err)
	}
	streamCtx, stopStream := context.WithCancel(ctx)
	done := make(chan error, 1)
	frames := make(chan FrameMetadata, 1)
	states := make(chan *dieterv1.RemoteDesktopSessionState, 1)
	source.(AdaptiveFrameSource).SetEventHandler(func(event SourceEvent) {
		if event.State != nil {
			select {
			case states <- event.State:
			default:
			}
		}
	})
	go func() {
		done <- source.Stream(streamCtx, func(sample media.Sample) error {
			metadata := sample.Metadata.(FrameMetadata)
			select {
			case frames <- metadata:
			default:
			}
			return nil
		})
	}()
	var frame FrameMetadata
	select {
	case frame = <-frames:
	case err = <-done:
		t.Fatalf("X11 capture stopped: %v", err)
	case <-ctx.Done():
		t.Fatal("X11 capture frame timed out")
	}
	select {
	case state := <-states:
		if state.GetEmbeddedCursor() {
			t.Fatal("X11 helper ignored the requested local-cursor mode")
		}
	case err = <-done:
		t.Fatalf("X11 capture stopped before state: %v", err)
	case <-ctx.Done():
		t.Fatal("X11 capture state timed out")
	}
	sink := source.(InputSink)
	inputs := []*dieterv1.RemoteDesktopInput{
		{DisplayGeneration: frame.Generation, Payload: &dieterv1.RemoteDesktopInput_PointerMove{PointerMove: &dieterv1.RemoteDesktopPointerMove{NormalizedX: 500000, NormalizedY: 500000}}},
		{DisplayGeneration: frame.Generation, Payload: &dieterv1.RemoteDesktopInput_PointerButton{PointerButton: &dieterv1.RemoteDesktopPointerButton{Button: dieterv1.RemoteDesktopPointerButton_BUTTON_LEFT, Down: true, NormalizedX: 500000, NormalizedY: 500000}}},
		{DisplayGeneration: frame.Generation, Payload: &dieterv1.RemoteDesktopInput_PointerButton{PointerButton: &dieterv1.RemoteDesktopPointerButton{Button: dieterv1.RemoteDesktopPointerButton_BUTTON_LEFT, Down: false, NormalizedX: 500000, NormalizedY: 500000}}},
		{DisplayGeneration: frame.Generation, Payload: &dieterv1.RemoteDesktopInput_Key{Key: &dieterv1.RemoteDesktopKey{PhysicalKey: 4, Down: true}}},
		{DisplayGeneration: frame.Generation, Payload: &dieterv1.RemoteDesktopInput_Key{Key: &dieterv1.RemoteDesktopKey{PhysicalKey: 4, Down: false}}},
	}
	for _, input := range inputs {
		if err = sink.SendInput(ctx, input); err != nil {
			t.Fatal(err)
		}
	}
	if !scanner.Scan() || strings.TrimSpace(scanner.Text()) != "PASS" {
		t.Fatalf("X11 target did not observe capture control: %s", stderr.String())
	}
	if err = command.Wait(); err != nil {
		t.Fatalf("X11 target: %v: %s", err, stderr.String())
	}
	stopStream()
	if err = <-done; err != nil && !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}

func TestLinuxNativeHelperCapabilities(t *testing.T) {
	helper := os.Getenv("DIETER_TEST_CAPTURE_HELPER")
	if helper == "" {
		t.Skip("Linux capture helper not configured")
	}
	capabilities := New(Options{Source: SourceOptions{Kind: "native-synthetic", HelperPath: helper}}).Capabilities(false, false)
	if capabilities.GetPlatform() != "linux" || len(capabilities.GetDisplays()) != 1 || capabilities.GetDisplays()[0].GetId() != "synthetic" {
		t.Fatalf("capabilities = %#v", capabilities)
	}
	if len(capabilities.GetCodecs()) != 1 || capabilities.GetCodecs()[0] != "H264" || capabilities.GetHelperVersion() != "linux-native-v1" {
		t.Fatalf("native codec capabilities = %#v", capabilities)
	}
	if !capabilities.GetControlSupported() || !capabilities.GetHardwareEncoderAvailable() {
		t.Fatalf("native input/encoder capabilities = %#v", capabilities)
	}
}
