package daemon

import (
	"testing"
	"time"
)

func TestGatewayHeartbeatIntervalBacksOffAndResetsOnActivity(t *testing.T) {
	interval := gatewayHeartbeatActiveInterval
	for _, want := range []time.Duration{10 * time.Second, 20 * time.Second, 20 * time.Second} {
		interval = nextGatewayHeartbeatInterval(interval, false)
		if interval != want {
			t.Fatalf("idle heartbeat interval = %s, want %s", interval, want)
		}
	}
	if got := nextGatewayHeartbeatInterval(interval, true); got != gatewayHeartbeatActiveInterval {
		t.Fatalf("active heartbeat interval = %s, want %s", got, gatewayHeartbeatActiveInterval)
	}
}

func TestGatewayReconnectBackoffResetsAfterStableSession(t *testing.T) {
	delay, next := gatewayReconnectBackoff(16*time.Second, gatewayReconnectStableAfter-time.Millisecond)
	if delay != 16*time.Second || next != gatewayReconnectMaximumBackoff {
		t.Fatalf("unstable reconnect backoff = (%s, %s)", delay, next)
	}

	delay, next = gatewayReconnectBackoff(gatewayReconnectMaximumBackoff, gatewayReconnectStableAfter)
	if delay != gatewayReconnectInitialBackoff || next != 2*gatewayReconnectInitialBackoff {
		t.Fatalf("stable reconnect backoff = (%s, %s)", delay, next)
	}

	delay, next = gatewayReconnectBackoff(gatewayReconnectMaximumBackoff, 0)
	if delay != gatewayReconnectMaximumBackoff || next != gatewayReconnectMaximumBackoff {
		t.Fatalf("capped reconnect backoff = (%s, %s)", delay, next)
	}
}

func TestRelayMethodPriorityKeepsCommandsAheadOfStreams(t *testing.T) {
	for _, method := range []string{
		"/dieter.v1.DieterService/StartCard",
		"/dieter.v1.DieterService/MoveCard",
		"/dieter.v1.DieterService/Health",
	} {
		if !relayMethodPriority(method) {
			t.Fatalf("%s should use the priority relay queue", method)
		}
	}
	for _, method := range []string{
		"/dieter.v1.DieterService/WatchSync",
		"/dieter.v1.DieterService/WatchConversation",
		"/dieter.v1.DieterService/WatchState",
		"/dieter.v1.DieterService/WatchTerminal",
		"/dieter.v1.DieterService/WatchExecution",
	} {
		if relayMethodPriority(method) {
			t.Fatalf("%s should use the bounded streaming relay queue", method)
		}
	}
}
