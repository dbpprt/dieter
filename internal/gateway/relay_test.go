package gateway

import (
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/transport/relay"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// newTestRelayHub registers one in-memory daemon link per lane. Tests drive
// the links directly instead of through a transport.
func newTestRelayHub(t *testing.T) (*Hub, map[relay.Lane]*daemonLink) {
	t.Helper()
	hub := NewHub(nil, Config{})
	links := map[relay.Lane]*daemonLink{}
	for _, lane := range relay.Lanes {
		link := &daemonLink{
			id: "isolated-test-daemon", lane: lane, sessionID: "isolated-session", budget: relay.NewBudget(relay.BufferedBytes, nil),
			control: make(chan *gatewayv1.DaemonLinkFrame, 2*relay.TunnelLimit(lane)+16),
			done:    make(chan struct{}), tunnels: map[uint64]*tunnel{},
		}
		link.outbound = relay.NewQueue(link.budget)
		link.markSeen(time.Now())
		if err := hub.register(link); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { hub.unregister(link) })
		links[lane] = link
	}
	return hub, links
}

func nextOutbound(t *testing.T, link *daemonLink) *gatewayv1.DaemonLinkFrame {
	t.Helper()
	frame, release := link.outbound.Next()
	if frame == nil {
		t.Fatal("no queued daemon link frame")
	}
	release()
	return frame
}

func tunnelReason(t *testing.T, opened *tunnel) *status.Status {
	t.Helper()
	select {
	case <-opened.done:
		return opened.reason
	case <-time.After(5 * time.Second):
		t.Fatal("tunnel did not close")
		return nil
	}
}

func TestDaemonLinkHeartbeatLease(t *testing.T) {
	t.Parallel()
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

func TestTunnelOpenAsksTheDaemonOnItsLane(t *testing.T) {
	t.Parallel()
	hub, links := newTestRelayHub(t)
	opened, err := hub.openTunnel("isolated-test-daemon", relay.Replication)
	if err != nil {
		t.Fatal(err)
	}
	defer opened.close(status.New(codes.Canceled, "test ended"), false)
	frame := nextOutbound(t, links[relay.Replication])
	if frame.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPEN || frame.GetStreamId() != opened.id ||
		frame.GetDaemonId() != "isolated-test-daemon" || frame.GetLane() != relay.Replication {
		t.Fatalf("tunnel open = %v", frame)
	}
	for _, lane := range []relay.Lane{relay.Control, relay.Command, relay.Subscription} {
		if frame, _ := links[lane].outbound.Next(); frame != nil {
			t.Fatalf("tunnel opened on the %s lane as well", lane)
		}
	}
	if _, err := hub.openTunnel("another-daemon", relay.Command); status.Code(err) != codes.Unavailable {
		t.Fatalf("tunnel to an offline daemon = %v", err)
	}
}

func TestTunnelLimitIsPerDaemonLane(t *testing.T) {
	t.Parallel()
	hub, links := newTestRelayHub(t)
	for _, lane := range relay.Lanes {
		for range relay.TunnelLimit(lane) {
			opened, err := hub.openTunnel("isolated-test-daemon", lane)
			if err != nil {
				t.Fatalf("%s tunnel below its limit = %v", lane, err)
			}
			t.Cleanup(func() { opened.close(status.New(codes.Canceled, "test ended"), false) })
		}
		if _, err := hub.openTunnel("isolated-test-daemon", lane); status.Code(err) != codes.ResourceExhausted {
			t.Fatalf("%s tunnel above its limit = %v", lane, err)
		}
	}
	for _, value := range hub.RelayLanes("isolated-test-daemon") {
		if int(value.GetActiveCalls()) != relay.TunnelLimit(value.GetLane()) || int(value.GetCallLimit()) != relay.TunnelLimit(value.GetLane()) || value.GetRejectedCalls() != 1 {
			t.Fatalf("lane status does not report tunnels: %v", value)
		}
	}
	link := links[relay.Command]
	link.mu.RLock()
	var first *tunnel
	for _, value := range link.tunnels {
		first = value
		break
	}
	link.mu.RUnlock()
	first.close(status.New(codes.Canceled, "client ended the tunnel"), true)
	if _, err := hub.openTunnel("isolated-test-daemon", relay.Command); err != nil {
		t.Fatalf("closed tunnel did not free its slot: %v", err)
	}
}

func TestTunnelWithAnUnreadClientClosesAloneAndReleasesItsBytes(t *testing.T) {
	t.Parallel()
	hub, links := newTestRelayHub(t)
	link := links[relay.Command]
	slow, err := hub.openTunnel("isolated-test-daemon", relay.Command)
	if err != nil {
		t.Fatal(err)
	}
	healthy, err := hub.openTunnel("isolated-test-daemon", relay.Command)
	if err != nil {
		t.Fatal(err)
	}
	defer healthy.close(status.New(codes.Canceled, "test ended"), false)
	nextOutbound(t, link)
	nextOutbound(t, link)
	// Nobody consumes the slow tunnel. A daemon that ignores the window fills
	// its bounded queue; delivery never blocks the shared link reader.
	for range relay.QueuedFrames + 1 {
		link.deliver(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_DATA, StreamId: slow.id, Payload: make([]byte, relay.ChunkBytes)})
	}
	if reason := tunnelReason(t, slow); reason.Code() != codes.ResourceExhausted {
		t.Fatalf("overflowing tunnel closed with %v", reason)
	}
	select {
	case frame := <-link.control:
		if frame.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE || frame.GetStreamId() != slow.id {
			t.Fatalf("daemon was told to close %v", frame)
		}
	default:
		t.Fatal("daemon was not told to close the overflowing tunnel")
	}
	if link.budget.Used() != 0 {
		t.Fatalf("closed tunnel retained %d buffered bytes", link.budget.Used())
	}
	link.deliver(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPENED, StreamId: healthy.id})
	select {
	case item := <-healthy.inbound:
		link.budget.Release(item.bytes)
	default:
		t.Fatal("an overflowing tunnel blocked its neighbour")
	}
	if !link.isAlive(time.Now()) {
		t.Fatal("an overflowing tunnel closed the shared link")
	}
}

func TestTunnelCloseDropsQueuedDataAndUsesTheControlQueue(t *testing.T) {
	t.Parallel()
	hub, links := newTestRelayHub(t)
	link := links[relay.Command]
	opened, err := hub.openTunnel("isolated-test-daemon", relay.Command)
	if err != nil {
		t.Fatal(err)
	}
	other, err := hub.openTunnel("isolated-test-daemon", relay.Command)
	if err != nil {
		t.Fatal(err)
	}
	defer other.close(status.New(codes.Canceled, "test ended"), false)
	reserved := int64(relay.BufferedBytes) - link.budget.Used()
	if !link.budget.Reserve(reserved) {
		t.Fatal("cannot fill the lane byte budget")
	}
	defer link.budget.Release(reserved)
	// With the byte budget full, new tunnels fail fast and closing one still
	// reaches the daemon through the bounded control queue.
	if _, err := hub.openTunnel("isolated-test-daemon", relay.Command); status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("tunnel open with a full send budget = %v", err)
	}
	opened.close(status.New(codes.Canceled, "client ended the tunnel"), true)
	select {
	case frame := <-link.control:
		if frame.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE || frame.GetStreamId() != opened.id || frame.GetStatusCode() != int32(codes.Canceled) {
			t.Fatalf("close frame = %v", frame)
		}
	default:
		t.Fatal("close did not use the control queue")
	}
	for {
		frame, release := link.outbound.Next()
		if frame == nil {
			break
		}
		release()
		if frame.GetStreamId() == opened.id {
			t.Fatal("a closed tunnel's queued frames were still scheduled")
		}
	}
	link.mu.RLock()
	defer link.mu.RUnlock()
	if len(link.tunnels) != 1 || link.tunnels[other.id] != other {
		t.Fatal("closing one tunnel affected another")
	}
}

func TestDaemonLinkCloseEndsItsTunnels(t *testing.T) {
	t.Parallel()
	hub, links := newTestRelayHub(t)
	command, err := hub.openTunnel("isolated-test-daemon", relay.Command)
	if err != nil {
		t.Fatal(err)
	}
	replication, err := hub.openTunnel("isolated-test-daemon", relay.Replication)
	if err != nil {
		t.Fatal(err)
	}
	defer replication.close(status.New(codes.Canceled, "test ended"), false)
	links[relay.Command].deliver(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPENED, StreamId: command.id})
	links[relay.Command].close()
	if reason := tunnelReason(t, command); reason.Code() != codes.Unavailable {
		t.Fatalf("tunnel of a closed link ended with %v", reason)
	}
	if links[relay.Command].budget.Used() != 0 {
		t.Fatal("closed link retained tunnel bytes")
	}
	select {
	case <-replication.done:
		t.Fatal("closing one lane ended another lane's tunnel")
	default:
	}
	hub.CloseDaemon("isolated-test-daemon")
	if reason := tunnelReason(t, replication); reason.Code() != codes.Unavailable {
		t.Fatalf("revocation ended a tunnel with %v", reason)
	}
}

func TestRelayClosedDaemonIsImmediatelyOffline(t *testing.T) {
	t.Parallel()
	hub, _ := newTestRelayHub(t)
	hub.CloseDaemon("isolated-test-daemon")
	if hub.Online("isolated-test-daemon") {
		t.Fatal("closed daemon remains online until the heartbeat lease expires")
	}
}

func TestAuthenticatedStreamsAreBoundedPerAccount(t *testing.T) {
	t.Parallel()
	var budget streamBudget
	for range maxAccountStreams {
		if !budget.acquire(1) {
			t.Fatal("account stream below its bound was rejected")
		}
	}
	if budget.acquire(1) {
		t.Fatal("account exceeded its stream bound")
	}
	if !budget.acquire(2) {
		t.Fatal("one account's streams exhausted another's")
	}
	budget.release(1)
	if !budget.acquire(1) {
		t.Fatal("released stream was not returned to its account")
	}
	for account := int64(3); budget.total < maxGatewayStreams; account++ {
		for range maxAccountStreams {
			if budget.total < maxGatewayStreams && !budget.acquire(account) {
				t.Fatal("stream below the gateway bound was rejected")
			}
		}
	}
	if budget.acquire(1 << 40) {
		t.Fatal("gateway exceeded its total stream bound")
	}
}

func TestAuthenticatedSubscriptionCapacityReservesOtherTrafficClasses(t *testing.T) {
	t.Parallel()
	var budget streamBudget
	for range maxAccountStreams {
		if !budget.acquireLane(1, relay.Subscription) {
			t.Fatal("subscription rejected below account ceiling")
		}
	}
	if budget.acquireLane(1, relay.Subscription) {
		t.Fatal("subscription ceiling exceeded")
	}
	for _, lane := range []relay.Lane{relay.Control, relay.Replication, relay.Command} {
		if !budget.acquireLane(1, lane) {
			t.Fatalf("subscriptions consumed %s capacity", lane)
		}
	}
	for range maxAccountStreams {
		budget.releaseLane(1, relay.Subscription)
	}
	if !budget.acquireLane(1, relay.Subscription) {
		t.Fatal("subscription reservation was not released")
	}
}

func TestRelaySessionJoinsRejectStaleProcessesAndPreserveReplacements(t *testing.T) {
	t.Parallel()
	hub := NewHub(nil, Config{})
	link := func(lane relay.Lane, session string) *daemonLink {
		b := relay.NewBudget(relay.BufferedBytes, nil)
		l := &daemonLink{id: "daemon", lane: lane, sessionID: session, budget: b, outbound: relay.NewQueue(b), done: make(chan struct{}), tunnels: map[uint64]*tunnel{}}
		l.markSeen(time.Now())
		t.Cleanup(l.close)
		return l
	}
	a := link(relay.Control, "session-a")
	if err := hub.register(a); err != nil {
		t.Fatal(err)
	}
	auxiliary := link(relay.Subscription, "session-a")
	if err := hub.register(auxiliary); err != nil {
		t.Fatal(err)
	}
	if err := hub.register(link(relay.Command, "unrelated-session")); status.Code(err) != codes.FailedPrecondition {
		t.Fatal("unrelated process joined daemon lanes", err)
	}
	b := link(relay.Control, "session-b")
	if err := hub.register(b); err != nil {
		t.Fatal(err)
	}
	if a.isAlive(time.Now()) || auxiliary.isAlive(time.Now()) {
		t.Fatal("replaced process retained a lane")
	}
	hub.unregister(a)
	if !hub.Online("daemon") {
		t.Fatal("old cleanup removed new control connection")
	}
	if err := hub.register(link(relay.Control, "session-a")); status.Code(err) != codes.FailedPrecondition {
		t.Fatal("stale control resurrected old process", err)
	}
	if err := hub.register(link(relay.Subscription, "session-a")); status.Code(err) != codes.FailedPrecondition {
		t.Fatal("stale subscription joined new process", err)
	}
	if err := hub.register(link(relay.Subscription, "session-b")); err != nil {
		t.Fatal(err)
	}
	hub.CloseDaemon("daemon")
	for _, lane := range hub.RelayLanes("daemon") {
		if lane.Connected {
			t.Fatal("revocation left authenticated lane alive")
		}
	}
}
