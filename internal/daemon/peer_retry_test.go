package daemon

import (
	"context"
	"errors"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestPeerRTCCooldownBacksOffAndCaps(t *testing.T) {
	now := time.Unix(1_000, 0)
	syncer := &PeerSync{now: func() time.Time { return now }}
	want := []time.Duration{2 * time.Minute, 4 * time.Minute, 8 * time.Minute, 15 * time.Minute, 15 * time.Minute}
	for index, delay := range want {
		state := syncer.recordRTCFallback("office")
		if state.failures != index+1 || state.retryAt.Sub(now) != delay {
			t.Fatalf("failure %d: got %#v, want delay %s", index+1, state, delay)
		}
		if syncer.rtcAttemptAllowed("office") {
			t.Fatalf("failure %d did not enter cooldown", index+1)
		}
		now = state.retryAt
		if !syncer.rtcAttemptAllowed("office") {
			t.Fatalf("failure %d remained blocked at retry deadline", index+1)
		}
	}
}

func TestPeerRTCSuccessClearsOnlyTargetCooldown(t *testing.T) {
	syncer := &PeerSync{}
	syncer.recordRTCFallback("office")
	syncer.recordRTCFallback("home")
	syncer.clearRTCFallback("office")
	if !syncer.rtcAttemptAllowed("office") {
		t.Fatal("successful peer remained in cooldown")
	}
	if syncer.rtcAttemptAllowed("home") {
		t.Fatal("clearing one peer changed another peer")
	}
}

func TestSanitizedRTCReasonNeverIncludesErrorText(t *testing.T) {
	if got := sanitizedRTCReason(context.DeadlineExceeded); got != "deadline" {
		t.Fatalf("deadline reason = %q", got)
	}
	if got := sanitizedRTCReason(status.Error(codes.Unavailable, "secret endpoint")); got != "Unavailable" {
		t.Fatalf("status reason = %q", got)
	}
	if got := sanitizedRTCReason(errors.New("turn:username:password@example.invalid")); got != "unavailable" {
		t.Fatalf("raw error escaped sanitization: %q", got)
	}
}
