package testkit

import (
	"fmt"
	"testing"
	"time"
)

// PollInterval is how often Eventually re-evaluates its condition.
const PollInterval = 10 * time.Millisecond

// Budget scales a wall-clock budget for the race detector. Use it for every
// deadline that waits on real goroutines, processes, or sockets.
func Budget(d time.Duration) time.Duration { return d * raceScale }

// Eventually polls condition until it holds or Budget(timeout) elapses, then
// fails the test with the formatted description.
func Eventually(tb testing.TB, timeout time.Duration, condition func() bool, format string, args ...any) {
	tb.Helper()
	if !Poll(timeout, condition) {
		tb.Fatalf("timed out after %s waiting for %s", Budget(timeout), fmt.Sprintf(format, args...))
	}
}

// Poll reports whether condition held within Budget(timeout).
func Poll(timeout time.Duration, condition func() bool) bool {
	deadline := time.Now().Add(Budget(timeout))
	for {
		if condition() {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(PollInterval)
	}
}
