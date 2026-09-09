package daemon

import (
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
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

func TestGatewayHeartbeatAcknowledgementNegotiationAndCorrelation(t *testing.T) {
	legacy := &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO_ACK}
	if supportsGatewayCapability(legacy, gatewayHeartbeatAckCapability) {
		t.Fatal("legacy gateway unexpectedly enabled acknowledged heartbeats")
	}
	negotiated := &gatewayv1.DaemonLinkFrame{
		Kind:         gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO_ACK,
		Capabilities: []string{"another_capability", gatewayHeartbeatAckCapability},
	}
	if !supportsGatewayCapability(negotiated, gatewayHeartbeatAckCapability) {
		t.Fatal("gateway heartbeat acknowledgement capability was not detected")
	}

	valid := &gatewayv1.DaemonLinkFrame{
		Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG,
		DaemonId: "daemon", RequestId: "hb_4",
	}
	if !matchesGatewayHeartbeatAck(valid, "daemon", "hb_4") {
		t.Fatal("matching heartbeat acknowledgement was rejected")
	}
	if gatewayFrameMarksRelayActivity(valid) {
		t.Fatal("heartbeat acknowledgement was counted as relay activity")
	}
	if !gatewayFrameMarksRelayActivity(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_OPEN_RPC}) {
		t.Fatal("relayed RPC was not counted as activity")
	}
	for name, frame := range map[string]*gatewayv1.DaemonLinkFrame{
		"empty outstanding request": valid,
		"wrong daemon":              {Kind: valid.Kind, DaemonId: "other", RequestId: "hb_4"},
		"stale request":             {Kind: valid.Kind, DaemonId: "daemon", RequestId: "hb_3"},
		"wrong frame kind":          {Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PING, DaemonId: "daemon", RequestId: "hb_4"},
	} {
		requestID := "hb_4"
		if name == "empty outstanding request" {
			requestID = ""
		}
		if matchesGatewayHeartbeatAck(frame, "daemon", requestID) {
			t.Fatalf("%s unexpectedly matched", name)
		}
	}
}

func TestGatewayTimingUsesProductionDefaultsAndBoundedOverrides(t *testing.T) {
	defaults := (&GatewayClient{}).timing()
	if defaults.HeartbeatActiveInterval != gatewayHeartbeatActiveInterval ||
		defaults.HeartbeatIdleMaxInterval != gatewayHeartbeatIdleMaxInterval ||
		defaults.HeartbeatAckTimeout != gatewayHeartbeatAckTimeout || defaults.HandshakeTimeout != gatewayHandshakeTimeout {
		t.Fatalf("gateway timing defaults=%#v", defaults)
	}
	overrides := (&GatewayClient{Timing: GatewayTiming{
		HeartbeatActiveInterval: 10 * time.Millisecond, HeartbeatIdleMaxInterval: 20 * time.Millisecond,
		HeartbeatAckTimeout: 50 * time.Millisecond, HandshakeTimeout: 40 * time.Millisecond,
		ReconnectInitialBackoff: time.Millisecond, ReconnectMaximumBackoff: 2 * time.Millisecond,
		ReconnectStableAfter: 3 * time.Millisecond,
	}}).timing()
	if overrides.HeartbeatAckTimeout != 50*time.Millisecond || overrides.ReconnectMaximumBackoff != 2*time.Millisecond {
		t.Fatalf("gateway timing overrides=%#v", overrides)
	}
}
