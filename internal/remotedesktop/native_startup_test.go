package remotedesktop

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/pion/webrtc/v4/pkg/media"
)

// A cold helper can take longer than the interactive input deadline to begin
// reading commands. The first wake must tolerate that startup; subsequent wakes
// are fast once the helper has loaded.
func TestNativeWakeAllowsColdHelperStartup(t *testing.T) {
	t.Parallel()
	synctest.Test(t, func(t *testing.T) {
		source := &nativeHelperSource{writes: make(chan nativeWrite), stopped: make(chan struct{}), pending: make(map[uint64]chan error)}
		go func() {
			first := true
			for {
				select {
				case job := <-source.writes:
					if first {
						first = false
						time.Sleep(time.Second)
					}
					job.done <- nil
				case <-source.stopped:
					return
				}
			}
		}()
		defer close(source.stopped)
		for attempt := range 2 {
			if err := source.send(context.Background(), nativeCommand{Kind: "wake_display"}, true); err != nil {
				t.Errorf("wake attempt %d: %v", attempt+1, err)
			}
		}
	})
}

func TestNativeWakeRetainsDeadlineAndCancellation(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"wake_display", "input"} {
		t.Run(kind, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				source := &nativeHelperSource{writes: make(chan nativeWrite), stopped: make(chan struct{}), pending: make(map[uint64]chan error)}
				start := time.Now()
				err := source.send(context.Background(), nativeCommand{Kind: kind}, true)
				bound := nativeCommandTimeout
				if kind == "wake_display" {
					bound = nativeStartupTimeout
				}
				if !errors.Is(err, context.DeadlineExceeded) || time.Since(start) != bound {
					t.Fatalf("unresponsive %s: elapsed=%v error=%v", kind, time.Since(start), err)
				}
				ctx, cancel := context.WithCancel(context.Background())
				cancel()
				start = time.Now()
				if err := source.send(ctx, nativeCommand{Kind: kind}, true); !errors.Is(err, context.Canceled) || time.Since(start) != 0 {
					t.Fatalf("cancelled %s: %v", kind, err)
				}
			})
		})
	}
}

// A controlling client configures its session as soon as it exists, which
// first releases held input. A cold helper may still be creating the stream
// and rejects anything addressed to it; that must not fail the client's call.
func TestNativeRenditionDefersStreamCommandsUntilCreated(t *testing.T) {
	t.Parallel()
	root := &nativeHelperSource{writes: make(chan nativeWrite), stopped: make(chan struct{}), pending: make(map[uint64]chan error), ready: make(chan struct{})}
	close(root.ready)
	defer close(root.stopped)
	mux := newNativeMultiplexer()
	mux.root = root
	source, err := mux.Source(&nativeHelperSource{profile: "high", fps: 30, bitrateKbps: 2000, maxWidth: 640, maxHeight: 360})
	if err != nil {
		t.Fatal(err)
	}
	rendition := source.(*nativeRendition)
	creating, release := make(chan struct{}), make(chan struct{})
	delivered := make(chan nativeCommand, 8)
	var created atomic.Bool
	go func() {
		for {
			select {
			case job := <-root.writes:
				switch {
				case job.command.Kind == "create":
					close(creating)
					go func() { <-release; created.Store(true); job.done <- nil }()
				case !created.Load():
					job.done <- errors.New("Unknown native stream")
				default:
					delivered <- job.command
					job.done <- nil
				}
			case <-root.stopped:
				return
			}
		}
	}()
	ctx, cancel := context.WithCancel(context.Background())
	streamed := make(chan error, 1)
	go func() { streamed <- rendition.Stream(ctx, func(media.Sample) error { return nil }) }()
	<-creating

	if err := rendition.ReleaseInputChecked(ctx); err != nil {
		t.Fatalf("release during create: %v", err)
	}
	move := &dieterv1.RemoteDesktopInput{Payload: &dieterv1.RemoteDesktopInput_PointerMove{PointerMove: &dieterv1.RemoteDesktopPointerMove{}}}
	if err := rendition.SendInput(ctx, move); err != nil {
		t.Fatalf("input during create: %v", err)
	}
	rendition.RequestKeyFrame()
	if err := rendition.DisplayModeChanged(ctx); err != nil {
		t.Fatalf("display change during create: %v", err)
	}
	close(release)

	// The display change is replayed to the created stream, then commands flow.
	if command := <-delivered; command.Kind != "display_changed" || command.StreamID != rendition.id {
		t.Fatalf("first command after create = %+v", command)
	}
	if err := rendition.ReleaseInputChecked(ctx); err != nil {
		t.Fatalf("release after create: %v", err)
	}
	if command := <-delivered; command.Kind != "input" || command.Input.Kind != "release_all" {
		t.Fatalf("release after create = %+v", command)
	}
	select {
	case command := <-delivered:
		t.Fatalf("unexpected command %+v", command)
	default:
	}
	cancel()
	if err := <-streamed; !errors.Is(err, context.Canceled) {
		t.Fatalf("stream = %v", err)
	}
}
