package remotedesktop

import (
	"context"
	"errors"
	"testing"
	"testing/synctest"
	"time"
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
