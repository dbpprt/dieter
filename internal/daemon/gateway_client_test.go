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
	} {
		if relayMethodPriority(method) {
			t.Fatalf("%s should use the bounded streaming relay queue", method)
		}
	}
}
