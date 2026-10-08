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

func TestPeerFailuresAndActiveAttemptsDoNotDelayHealthyPeer(t *testing.T) {
	now := time.Unix(1000, 0)
	p := &PeerSync{now: func() time.Time { return now }}
	if peers := p.selectPeers([]string{"failed", "healthy", "stalled"}, 3); len(peers) != 3 {
		t.Fatal(peers)
	}
	p.finishPeer("failed", context.DeadlineExceeded)
	p.finishPeer("healthy", nil)
	for range 5 {
		if peers := p.selectPeers([]string{"failed", "healthy", "stalled"}, 3); len(peers) != 1 || peers[0] != "healthy" {
			t.Fatalf("healthy peer blocked by failed/stalled peers: %v", peers)
		}
		p.finishPeer("healthy", nil)
	}
	now = now.Add(15 * time.Second)
	if peers := p.selectPeers([]string{"failed", "healthy", "stalled"}, 3); len(peers) != 2 {
		t.Fatalf("peer retry deadline ignored: %v", peers)
	}
	p.finishPeer("failed", context.DeadlineExceeded)
	p.finishPeer("healthy", nil)
	if p.syncRetry["failed"].retryAt.Sub(now) != 30*time.Second {
		t.Fatal("target retry did not back off")
	}
	p.finishPeer("stalled", nil)
}
func TestPeerAdmissionIsBoundedAndRemovedPeersArePruned(t *testing.T) {
	p := &PeerSync{}
	if peers := p.selectPeers([]string{"a", "b", "c", "d", "e"}, 10); len(peers) != maxConcurrentPeerExchanges {
		t.Fatal(peers)
	}
	if peers := p.selectPeers([]string{"a", "b", "c", "d", "e"}, 10); len(peers) != 0 {
		t.Fatal("exchange concurrency exceeded")
	}
	for _, id := range []string{"a", "b", "c", "d"} {
		p.finishPeer(id, nil)
	}
	p.selectPeers([]string{"e"}, 1)
	if len(p.syncRetry) != 1 {
		t.Fatal("removed peer state retained")
	}
	p.finishPeer("e", nil)
}
