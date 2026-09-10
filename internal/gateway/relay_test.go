package gateway

import (
	"context"
	"io"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
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

func TestRelayPreservesCompletedExecutionBurstBeforeReceiverRuns(t *testing.T) {
	hub, link := newTestRelayHub(t)
	relay, err := hub.Open(t.Context(), link.id, &gatewayv1.DaemonLinkFrame{Method: "/dieter.v1.DieterService/WatchExecution"})
	if err != nil {
		t.Fatal(err)
	}
	defer relay.Close()

	// A completed command can replay its initial state, stdin EOF, stdout,
	// stderr, and exit state between the transport header and trailer. Dispatch
	// all of them before scheduling the receiver, as a busy CI host may do.
	want := []*gatewayv1.DaemonLinkFrame{{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_HEADER}}
	for _, payload := range []string{"started", "stdin closed", "stdout", "stderr", "exited"} {
		want = append(want, &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_MESSAGE, Payload: []byte(payload)})
	}
	want = append(want, &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_END})
	for _, frame := range want {
		frame.StreamId = relay.id
		link.dispatch(frame)
	}
	for i, expected := range want {
		actual, err := relay.Recv()
		if err != nil || !proto.Equal(actual, expected) {
			t.Fatalf("frame %d = %v, %v; want %v", i, actual, err, expected)
		}
	}
	if _, err := relay.Recv(); err != io.EOF {
		t.Fatalf("after completed burst = %v; want EOF", err)
	}
	if got := relay.queue.bytes.Load(); got != 0 {
		t.Fatalf("buffered bytes after EOF = %d; want 0", got)
	}
}

func TestRelayBurstLimitsIsolateSlowConsumers(t *testing.T) {
	for _, limit := range []string{"frames", "bytes"} {
		t.Run(limit, func(t *testing.T) {
			hub, link := newTestRelayHub(t)
			slow, err := hub.Open(t.Context(), link.id, &gatewayv1.DaemonLinkFrame{Method: "/dieter.v1.DieterService/WatchExecution"})
			if err != nil {
				t.Fatal(err)
			}
			healthy, err := hub.Open(t.Context(), link.id, &gatewayv1.DaemonLinkFrame{Method: "/dieter.v1.DieterService/GetState"})
			if err != nil {
				t.Fatal(err)
			}
			defer healthy.Close()
			payload := []byte("small event")
			count := cap(slow.queue.frames) + 1
			if limit == "bytes" {
				// Each encoded frame fits the 16 MiB transport limit. Reusing
				// the immutable payload keeps this regression test inexpensive.
				payload = make([]byte, maxRelayPayload-128)
				count = 5
			}
			for i := 0; i < count; i++ {
				link.dispatch(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_MESSAGE, StreamId: slow.id, Payload: payload})
			}
			failure, err := slow.Recv()
			if err != nil || failure.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RPC_ERROR || failure.GetStatusCode() != int32(codes.ResourceExhausted) {
				t.Fatalf("overflow kind=%v code=%d err=%v; want ResourceExhausted", failure.GetKind(), failure.GetStatusCode(), err)
			}
			if _, err := slow.Recv(); err != io.EOF {
				t.Fatalf("after overflow = %v; want EOF", err)
			}
			if got := slow.queue.bytes.Load(); got != 0 {
				t.Fatalf("buffered bytes after overflow = %d; want 0", got)
			}
			response := &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_MESSAGE, StreamId: healthy.id, Payload: []byte("healthy response")}
			link.dispatch(response)
			link.dispatch(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_END, StreamId: healthy.id})
			if got, err := healthy.Recv(); err != nil || !proto.Equal(got, response) {
				t.Fatalf("unrelated stream = %v, %v; want %v", got, err, response)
			}
		})
	}
}

func TestRelayPreservesEntireRetainedExecutionReplay(t *testing.T) {
	hub, link := newTestRelayHub(t)
	relay, err := hub.Open(t.Context(), link.id, &gatewayv1.DaemonLinkFrame{Method: "/dieter.v1.DieterService/WatchExecution"})
	if err != nil {
		t.Fatal(err)
	}
	defer relay.Close()
	want := []*gatewayv1.DaemonLinkFrame{{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_HEADER, StreamId: relay.id}}
	// remoteexec retains at most 4096 events. Reset is a flag on the first
	// event and exit is the final event, so only header/trailer add frames.
	for i := 0; i < 4096; i++ {
		want = append(want, &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_MESSAGE, StreamId: relay.id, Payload: []byte("replayed output")})
	}
	want = append(want, &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_END, StreamId: relay.id})
	for _, frame := range want {
		link.dispatch(frame)
	}
	for i, expected := range want {
		if got, err := relay.Recv(); err != nil || got != expected {
			t.Fatalf("replay frame %d = %v, %v; want retained frame", i, got.GetKind(), err)
		}
	}
	if _, err := relay.Recv(); err != io.EOF {
		t.Fatalf("after retained replay = %v; want EOF", err)
	}
	if got := relay.queue.bytes.Load(); got != 0 {
		t.Fatalf("buffered bytes after replay = %d; want 0", got)
	}
}

func TestRelayReleasesByteBudgetWhileConsumingAndClosing(t *testing.T) {
	hub, link := newTestRelayHub(t)
	relay, err := hub.Open(t.Context(), link.id, &gatewayv1.DaemonLinkFrame{Method: "/dieter.v1.DieterService/WatchExecution"})
	if err != nil {
		t.Fatal(err)
	}
	payload := make([]byte, maxRelayPayload-128)
	frame := &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_MESSAGE, StreamId: relay.id, Payload: payload}
	for round := 0; round < 2; round++ {
		for i := 0; i < 4; i++ {
			link.dispatch(frame)
		}
		if round == 1 {
			relay.Close()
		}
		for i := 0; i < 4; i++ {
			if got, err := relay.Recv(); err != nil || got != frame {
				t.Fatalf("round %d frame %d = %v, %v; want buffered response", round, i, got.GetKind(), err)
			}
		}
		if got := relay.queue.bytes.Load(); got != 0 {
			t.Fatalf("round %d buffered bytes = %d; want 0", round, got)
		}
	}
	if _, err := relay.Recv(); err != io.EOF {
		t.Fatalf("after close = %v; want EOF", err)
	}
}

func TestRelayFailureDrainsWhileReceiverIsActive(t *testing.T) {
	hub, link := newTestRelayHub(t)
	for attempt := 0; attempt < 100; attempt++ {
		relay, err := hub.Open(t.Context(), link.id, &gatewayv1.DaemonLinkFrame{Method: "/dieter.v1.DieterService/WatchExecution"})
		if err != nil {
			t.Fatal(err)
		}
		<-link.send
		for i := 0; i < defaultRelayFrameBuffer; i++ {
			link.dispatch(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_MESSAGE, StreamId: relay.id, Payload: []byte("queued output")})
		}
		consumed := make(chan error, 1)
		go func() {
			for {
				if _, err := relay.Recv(); err != nil {
					consumed <- err
					return
				}
			}
		}()
		failed := make(chan struct{})
		go func() {
			link.failStream(relay.id, status.Error(codes.ResourceExhausted, "slow consumer"))
			close(failed)
		}()
		select {
		case <-failed:
		case <-time.After(5 * time.Second):
			t.Fatal("failure drain blocked against the active receiver")
		}
		select {
		case err := <-consumed:
			if err != io.EOF {
				t.Fatalf("receiver finished with %v; want EOF", err)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("receiver did not finish after failure")
		}
		if got := relay.queue.bytes.Load(); got != 0 {
			t.Fatalf("buffered bytes after concurrent drain = %d; want 0", got)
		}
	}
}

func newTestRelayHub(t *testing.T) (*Hub, *daemonLink) {
	t.Helper()
	hub := NewHub(nil, Config{})
	link := &daemonLink{
		id: "isolated-test-daemon", send: make(chan *gatewayv1.DaemonLinkFrame, 8),
		done: make(chan struct{}), streams: map[uint64]*relayFrameQueue{},
	}
	link.markSeen(time.Now())
	hub.register(link)
	t.Cleanup(func() { hub.unregister(link) })
	return hub, link
}
