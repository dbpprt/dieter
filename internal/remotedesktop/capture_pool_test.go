package remotedesktop

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/pion/webrtc/v4/pkg/media"
)

type wakeCaptureSource struct {
	wakeErr   error
	wakes     chan struct{}
	started   chan struct{}
	startOnce sync.Once
}

func (*wakeCaptureSource) Description() string { return "wake capture fixture" }
func (*wakeCaptureSource) Codec() VideoCodec   { return VideoCodecH264 }
func (s *wakeCaptureSource) WakeDisplay(context.Context) error {
	s.wakes <- struct{}{}
	return s.wakeErr
}
func (s *wakeCaptureSource) Stream(ctx context.Context, _ func(media.Sample) error) error {
	s.startOnce.Do(func() { close(s.started) })
	<-ctx.Done()
	return ctx.Err()
}

func TestSharedCaptureWakesDisplayForEveryConnection(t *testing.T) {
	backend := &wakeCaptureSource{wakes: make(chan struct{}, 2), started: make(chan struct{})}
	pool := newCapturePool(func(SourceOptions) (FrameSource, error) { return backend, nil })
	t.Cleanup(pool.Close)
	options := SourceOptions{Display: "primary", Profile: "high", FPS: 30, Bitrate: 2_000, MaxWidth: 640, MaxHeight: 360}
	first, err := pool.Subscribe(options)
	if err != nil {
		t.Fatal(err)
	}
	second, err := pool.Subscribe(options)
	if err != nil {
		t.Fatal(err)
	}
	if first.(*sharedSource).variant != second.(*sharedSource).variant {
		t.Fatal("matching viewers did not share a capture variant")
	}

	start := func(source FrameSource) (context.CancelFunc, <-chan error) {
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() { done <- source.Stream(ctx, func(media.Sample) error { return nil }) }()
		return cancel, done
	}
	wait := func(label string, ready <-chan struct{}) {
		t.Helper()
		select {
		case <-ready:
		case <-time.After(2 * time.Second):
			t.Fatalf("timed out waiting for %s", label)
		}
	}
	waitDone := func(label string, done <-chan error) error {
		t.Helper()
		select {
		case err := <-done:
			return err
		case <-time.After(2 * time.Second):
			t.Fatalf("timed out waiting for %s to stop", label)
			return nil
		}
	}
	firstCancel, firstDone := start(first)
	wait("first display wake", backend.wakes)
	wait("shared capture start", backend.started)
	secondCancel, secondDone := start(second)
	wait("second display wake", backend.wakes)

	firstCancel()
	secondCancel()
	if err := waitDone("first stream", firstDone); !errors.Is(err, context.Canceled) {
		t.Fatalf("first stream stopped with %v", err)
	}
	if err := waitDone("second stream", secondDone); !errors.Is(err, context.Canceled) {
		t.Fatalf("second stream stopped with %v", err)
	}
	first.(*sharedSource).Close()
	second.(*sharedSource).Close()
}

func TestSharedCaptureDoesNotStartWhenDisplayWakeFails(t *testing.T) {
	wakeErr := errors.New("display wake failed")
	backend := &wakeCaptureSource{wakeErr: wakeErr, wakes: make(chan struct{}, 1), started: make(chan struct{})}
	pool := newCapturePool(func(SourceOptions) (FrameSource, error) { return backend, nil })
	t.Cleanup(pool.Close)
	source, err := pool.Subscribe(SourceOptions{Display: "primary", Profile: "high", FPS: 30, Bitrate: 2_000, MaxWidth: 640, MaxHeight: 360})
	if err != nil {
		t.Fatal(err)
	}
	if err := source.Stream(context.Background(), func(media.Sample) error { return nil }); !errors.Is(err, wakeErr) {
		t.Fatalf("stream wake failure = %v", err)
	}
	select {
	case <-backend.started:
		t.Fatal("capture started after display wake failed")
	default:
	}
	source.(*sharedSource).Close()
}
