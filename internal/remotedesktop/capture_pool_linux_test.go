//go:build linux

package remotedesktop

import (
	"context"
	"testing"
)

func TestLinuxNativeProcessesIsolatePortalCursorAndControlModes(t *testing.T) {
	pool := newCapturePool(func(options SourceOptions) (FrameSource, error) {
		return &nativeHelperSource{
			path: "not-started", display: options.Display, profile: options.Profile, codec: options.Codec,
			fps: options.FPS, bitrateKbps: options.Bitrate, maxWidth: options.MaxWidth, maxHeight: options.MaxHeight,
			embeddedCursor: options.EmbeddedCursor, inputAllowed: options.Control,
		}, nil
	})
	t.Cleanup(pool.Close)

	subscribe := func(control, embeddedCursor bool, width int) *nativeMultiplexer {
		t.Helper()
		source, err := pool.Subscribe(SourceOptions{
			Kind: "screen", Display: "primary", Profile: "high", Control: control,
			EmbeddedCursor: embeddedCursor, FPS: 30, Bitrate: 2_000,
			MaxWidth: width, MaxHeight: 360,
		})
		if err != nil {
			t.Fatal(err)
		}
		shared := source.(*sharedSource)
		return shared.variant.source.(*nativeRendition).mux
	}

	viewLocal := subscribe(false, false, 640)
	if sameMode := subscribe(false, false, 800); sameMode != viewLocal {
		t.Fatal("matching Linux portal modes did not share a helper")
	}
	if controlledLocal := subscribe(true, false, 640); controlledLocal == viewLocal {
		t.Fatal("control and view-only portal sessions shared a helper")
	}
	if viewEmbedded := subscribe(false, true, 640); viewEmbedded == viewLocal {
		t.Fatal("embedded and local-cursor portal sessions shared a helper")
	}
}

func TestLinuxCursorModeChangeMovesToMatchingPortalProcess(t *testing.T) {
	pool := newCapturePool(func(options SourceOptions) (FrameSource, error) {
		return &nativeHelperSource{
			path: "not-started", display: options.Display, profile: options.Profile, codec: options.Codec,
			fps: options.FPS, bitrateKbps: options.Bitrate, maxWidth: options.MaxWidth, maxHeight: options.MaxHeight,
			embeddedCursor: options.EmbeddedCursor, inputAllowed: options.Control,
		}, nil
	})
	t.Cleanup(pool.Close)
	options := SourceOptions{
		Kind: "screen", Display: "primary", Profile: "high", Control: true,
		FPS: 30, Bitrate: 2_000, MaxWidth: 640, MaxHeight: 360,
	}
	source, err := pool.Subscribe(options)
	if err != nil {
		t.Fatal(err)
	}
	shared := source.(*sharedSource)
	before := shared.variant.source.(*nativeRendition).mux
	configuration := sourceConfiguration(options)
	configuration.EmbeddedCursor = true
	if err := shared.Configure(context.Background(), configuration); err != nil {
		t.Fatal(err)
	}
	after := shared.variant.source.(*nativeRendition).mux
	if after == before {
		t.Fatal("cursor-mode reconfiguration reused a fixed-mode portal helper")
	}
}
