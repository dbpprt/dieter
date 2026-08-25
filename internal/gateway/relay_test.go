package gateway

import (
	"context"
	"testing"
	"time"
)

func TestRelayDeadlineOnlyPropagatesClientDeadline(t *testing.T) {
	if got := relayDeadlineUnixMillis(context.Background()); got != 0 {
		t.Fatalf("background relay deadline = %d, want 0", got)
	}

	deadline := time.Now().Add(time.Minute).Truncate(time.Millisecond)
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()
	if got := relayDeadlineUnixMillis(ctx); got != deadline.UnixMilli() {
		t.Fatalf("relay deadline = %d, want %d", got, deadline.UnixMilli())
	}
}

func TestDaemonLinkHeartbeatLease(t *testing.T) {
	link := &daemonLink{}
	now := time.Now()
	link.markSeen(now)
	if !link.isAlive(now.Add(daemonHeartbeatLease - time.Millisecond)) {
		t.Fatal("daemon link should remain online inside its heartbeat lease")
	}
	if link.isAlive(now.Add(daemonHeartbeatLease)) {
		t.Fatal("daemon link should be offline once its heartbeat lease expires")
	}
}

func TestRemoteDesktopRelayAllowsBoundedSignalingBurst(t *testing.T) {
	if got := relayFrameBuffer("/dieter.v1.DieterService/StartRemoteDesktop"); got != remoteDesktopRelayFrameBuffer {
		t.Fatalf("remote desktop relay buffer = %d, want %d", got, remoteDesktopRelayFrameBuffer)
	}
	if got := relayFrameBuffer("/dieter.v1.DieterService/WatchSync"); got != defaultRelayFrameBuffer {
		t.Fatalf("default relay buffer = %d, want %d", got, defaultRelayFrameBuffer)
	}
}
