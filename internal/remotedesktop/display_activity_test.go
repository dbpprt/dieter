package remotedesktop

import (
	"context"
	"errors"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"

	"github.com/pion/webrtc/v4/pkg/media"
)

func TestDisplayActivityOwnership(t *testing.T) {
	var actions []string
	held := map[uint32]bool{}
	var next uint32
	driver := displayPowerDriver{
		create: func() (uint32, error) {
			next++
			held[next] = true
			actions = append(actions, "create")
			return next, nil
		},
		wake: func() error { actions = append(actions, "wake"); return nil },
		release: func(id uint32) error {
			if !held[id] {
				t.Errorf("assertion %d released twice", id)
			}
			delete(held, id)
			actions = append(actions, "release")
			return nil
		},
	}
	first, err := holdDisplayActivity(t.Context(), driver)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(actions, []string{"create", "wake"}) {
		t.Fatalf("order=%v", actions)
	}
	second, err := holdDisplayActivity(t.Context(), driver)
	if err != nil {
		t.Fatal(err)
	}
	if err := first(); err != nil {
		t.Fatal(err)
	}
	if err := first(); err != nil {
		t.Fatal(err)
	}
	if len(held) != 1 {
		t.Fatal("one capture released another's assertion")
	}
	if err := second(); err != nil {
		t.Fatal(err)
	}
	if len(held) != 0 {
		t.Fatal("assertions leaked")
	}
}

func TestDisplayActivityFailureAndCancellation(t *testing.T) {
	failure := errors.New("power operation failed")
	for _, phase := range []string{"create", "wake", "cancel-before", "cancel-create", "cancel-wake"} {
		t.Run(phase, func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			if phase == "cancel-before" {
				cancel()
			}
			var creates, wakes, releases int
			driver := displayPowerDriver{
				create: func() (uint32, error) {
					creates++
					if phase == "create" {
						return 0, failure
					}
					if phase == "cancel-create" {
						cancel()
					}
					return 42, nil
				},
				wake: func() error {
					wakes++
					if phase == "wake" {
						return failure
					}
					if phase == "cancel-wake" {
						cancel()
					}
					return nil
				},
				release: func(id uint32) error {
					if id != 42 {
						t.Errorf("id=%d", id)
					}
					releases++
					return nil
				},
			}
			release, err := holdDisplayActivity(ctx, driver)
			want := failure
			if phase != "create" && phase != "wake" {
				want = context.Canceled
			}
			if !errors.Is(err, want) {
				t.Fatalf("error=%v", err)
			}
			if release != nil {
				if err := release(); err != nil {
					t.Fatal(err)
				}
			}
			switch phase {
			case "cancel-before":
				if creates+wakes+releases != 0 {
					t.Fatal("cancelled capture touched power state")
				}
			case "create":
				if creates != 1 || wakes+releases != 0 {
					t.Fatal("failed acquire woke or released the display")
				}
			case "cancel-create":
				if wakes != 0 || releases != 1 {
					t.Fatal("cancelled acquisition did not roll back")
				}
			default:
				if creates != 1 || wakes != 1 || releases != 1 {
					t.Fatal("failed wake did not roll back")
				}
			}
		})
	}
}

func TestDisplayActivityReleaseRetryAndConcurrentClose(t *testing.T) {
	calls := 0
	failure := errors.New("release failed")
	release, err := holdDisplayActivity(t.Context(), displayPowerDriver{
		create: func() (uint32, error) { return 42, nil }, wake: func() error { return nil },
		release: func(uint32) error {
			calls++
			if calls == 1 {
				return failure
			}
			return nil
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !errors.Is(release(), failure) {
		t.Fatal("failed release lost its cause")
	}
	var wg sync.WaitGroup
	for range 20 {
		wg.Go(func() {
			if err := release(); err != nil {
				t.Error(err)
			}
		})
	}
	wg.Wait()
	if calls != 2 {
		t.Fatalf("release calls=%d", calls)
	}
}

func TestNativeDisplayActivityStartupFailures(t *testing.T) {
	wakeFailure := errors.New("wake failed")
	cleanupFailure := errors.New("release failed")
	for _, phase := range []string{"wake", "exec", "cleanup", "synthetic"} {
		t.Run(phase, func(t *testing.T) {
			var acquired, releases int
			s := &nativeHelperSource{path: filepath.Join(t.TempDir(), "missing-helper"), ready: make(chan struct{}), synthetic: phase == "synthetic"}
			s.displayActivity = func(ctx context.Context) (func() error, error) {
				acquired++
				return holdDisplayActivity(ctx, displayPowerDriver{
					create: func() (uint32, error) { return 1, nil },
					wake: func() error {
						if phase == "wake" {
							return wakeFailure
						}
						return nil
					},
					release: func(uint32) error {
						releases++
						if phase == "cleanup" && releases == 1 {
							return cleanupFailure
						}
						return nil
					},
				})
			}
			err := s.Stream(t.Context(), func(media.Sample) error { t.Fatal("failed startup emitted media"); return nil })
			if err == nil {
				t.Fatal("missing helper accepted")
			}
			if phase == "synthetic" {
				if acquired+releases != 0 {
					t.Fatal("synthetic capture touched host power")
				}
			} else if acquired != 1 || releases < 1 {
				t.Fatal("failed startup leaked power ownership")
			}
			if phase == "wake" && !errors.Is(err, wakeFailure) {
				t.Fatalf("error=%v", err)
			}
			if phase == "cleanup" && (!errors.Is(err, cleanupFailure) || releases != 2) {
				t.Fatalf("error=%v releases=%d", err, releases)
			}
			select {
			case <-s.ready:
			default:
				t.Fatal("startup failure did not publish readiness")
			}
			if _, readyErr := waitNativeReady(t.Context(), s); !errors.Is(readyErr, err) {
				t.Fatalf("startup cause lost: %v", readyErr)
			}
		})
	}
}

func TestNativeDisplayActivityMultiplexerStartupFailure(t *testing.T) {
	failure := errors.New("keep-awake denied")
	mux := newNativeMultiplexer()
	t.Cleanup(mux.Close)
	template := &nativeHelperSource{displayActivity: func(context.Context) (func() error, error) { return nil, failure }}
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	if _, err := mux.process(ctx, template); !errors.Is(err, failure) {
		t.Fatalf("startup cause=%v", err)
	}
	mux.mu.Lock()
	finished := mux.finished
	mux.mu.Unlock()
	select {
	case <-finished:
	case <-ctx.Done():
		t.Fatal("failed startup did not finish")
	}
}

type displayActivityTestSource struct {
	started, finished chan struct{}
	released          chan struct{}
}

func (*displayActivityTestSource) Description() string { return "display activity fixture" }
func (*displayActivityTestSource) Codec() VideoCodec   { return VideoCodecH264 }
func (s *displayActivityTestSource) Stream(ctx context.Context, _ func(media.Sample) error) error {
	release, err := holdDisplayActivity(ctx, displayPowerDriver{
		create: func() (uint32, error) { return 1, nil }, wake: func() error { return nil },
		release: func(uint32) error { close(s.released); return nil },
	})
	defer close(s.finished)
	if release != nil {
		defer release()
	}
	if err != nil {
		return err
	}
	close(s.started)
	<-ctx.Done()
	return ctx.Err()
}

func TestDisplayActivitySharedViewersRetainOwnership(t *testing.T) {
	backend := &displayActivityTestSource{started: make(chan struct{}), finished: make(chan struct{}), released: make(chan struct{})}
	pool := newCapturePool(func(SourceOptions) (FrameSource, error) { return backend, nil })
	t.Cleanup(pool.Close)
	first, err := pool.Subscribe(SourceOptions{})
	if err != nil {
		t.Fatal(err)
	}
	second, err := pool.Subscribe(SourceOptions{})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	firstDone := make(chan error, 1)
	secondDone := make(chan error, 1)
	go func() { firstDone <- first.Stream(ctx, func(media.Sample) error { return nil }) }()
	go func() { secondDone <- second.Stream(ctx, func(media.Sample) error { return nil }) }()
	select {
	case <-backend.started:
	case <-ctx.Done():
		t.Fatal("shared capture did not start")
	}
	first.(*sharedSource).Close()
	select {
	case <-backend.released:
		t.Fatal("first viewer released shared ownership")
	default:
	}
	second.(*sharedSource).Close()
	select {
	case <-backend.finished:
	case <-ctx.Done():
		t.Fatal("last viewer did not release ownership")
	}
	select {
	case <-backend.released:
	default:
		t.Fatal("keep-awake leaked")
	}
	select {
	case <-firstDone:
	case <-ctx.Done():
		t.Fatal("first viewer did not stop")
	}
	select {
	case <-secondDone:
	case <-ctx.Done():
		t.Fatal("second viewer did not stop")
	}
}
