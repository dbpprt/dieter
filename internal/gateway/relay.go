package gateway

import (
	"context"
	"errors"
	"io"
	"sync"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/transport/relay"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

const (
	// tunnelOpenedTimeout bounds how long a daemon may take to accept a tunnel.
	tunnelOpenedTimeout = 10 * time.Second
	// maxTunnelStatusMessage bounds the reason a peer attaches to CLOSE.
	maxTunnelStatusMessage = 256
)

// RelayService splices client tunnels onto daemon link lanes. Clients run
// mutually authenticated TLS to the daemon inside a tunnel, so the gateway
// forwards ciphertext: it never parses tunnel contents and has no notion of
// the calls they carry.
type RelayService struct {
	gatewayv1.UnimplementedRelayServiceServer
	store *Store
	hub   *Hub
}

func NewRelayService(store *Store, hub *Hub) *RelayService {
	return &RelayService{store: store, hub: hub}
}

// OpenTunnel admits a tunnel to one of the caller's daemons. The stream
// interceptor already authenticated the caller and charged the tunnel to the
// stream budget of the lane its OPEN frame names.
func (r *RelayService) OpenTunnel(stream grpc.BidiStreamingServer[gatewayv1.TunnelFrame, gatewayv1.TunnelFrame]) error {
	principal, ok := PrincipalFromContext(stream.Context())
	if !ok {
		return status.Error(codes.Unauthenticated, "authentication required")
	}
	open, err := stream.Recv()
	if err != nil {
		return err
	}
	if open.GetKind() != gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPEN || !relay.Valid(open.GetLane()) {
		return stream.Send(tunnelClose(codes.InvalidArgument, "the first tunnel frame must be OPEN with a valid lane"))
	}
	// Another account's daemon is indistinguishable from one that never existed.
	record, err := r.store.Daemon(open.GetDaemonId())
	if err != nil || record.Revoked || record.GitHubID != principal.GitHubID {
		return stream.Send(tunnelClose(codes.NotFound, "daemon not found"))
	}
	opened, err := r.hub.openTunnel(record.ID, open.GetLane())
	if err != nil {
		value := status.Convert(err)
		return stream.Send(tunnelClose(value.Code(), value.Message()))
	}
	return opened.splice(stream)
}

func tunnelClose(code codes.Code, message string) *gatewayv1.TunnelFrame {
	return &gatewayv1.TunnelFrame{Kind: gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_CLOSE, StatusCode: int32(code), StatusMessage: boundedStatusMessage(message)}
}

func boundedStatusMessage(message string) string {
	if len(message) <= maxTunnelStatusMessage {
		return message
	}
	return message[:maxTunnelStatusMessage]
}

type tunnelStream = grpc.BidiStreamingServer[gatewayv1.TunnelFrame, gatewayv1.TunnelFrame]

type queuedTunnelFrame struct {
	frame *gatewayv1.DaemonLinkFrame
	bytes int64
}

// tunnel is one client tunnel on a daemon link lane. The gateway forwards
// opaque DATA and the end-to-end WINDOW credits, and counts each direction's
// uncredited DATA. A side that exceeds relay.TunnelWindow, or credits data it
// never received, closes its tunnel, never the shared link.
type tunnel struct {
	link *daemonLink
	id   uint64
	// inbound holds daemon frames for the client. The window bounds what a
	// daemon may send, so a tunnel that fills it is closed.
	inbound chan queuedTunnelFrame
	done    chan struct{}
	once    sync.Once
	// reason is set before done closes.
	reason *status.Status

	mu   sync.Mutex
	up   int // client DATA the daemon has not credited
	down int // daemon DATA the client has not credited
}

func newTunnel(link *daemonLink, id uint64) *tunnel {
	return &tunnel{link: link, id: id, inbound: make(chan queuedTunnelFrame, relay.QueuedFrames), done: make(chan struct{})}
}

// push queues a daemon frame, reserving its bytes against the link's lane,
// account and gateway budgets until the client stream accepted it.
func (t *tunnel) push(frame *gatewayv1.DaemonLinkFrame) bool {
	size := int64(proto.Size(frame))
	if !t.link.budget.Reserve(size) {
		return false
	}
	select {
	case t.inbound <- queuedTunnelFrame{frame: frame, bytes: size}:
		return true
	default:
		t.link.budget.Release(size)
		return false
	}
}

// close ends the tunnel once. notifyDaemon sends TUNNEL_CLOSE when the
// daemon did not end the tunnel itself.
func (t *tunnel) close(reason *status.Status, notifyDaemon bool) {
	link, stalled := t.link, false
	t.once.Do(func() {
		link.mu.Lock()
		if link.tunnels[t.id] == t {
			delete(link.tunnels, t.id)
		}
		link.mu.Unlock()
		link.outbound.Cancel(t.id)
		if notifyDaemon {
			frame := &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE, StreamId: t.id, StatusCode: int32(reason.Code()), StatusMessage: boundedStatusMessage(reason.Message())}
			stalled = link.sendControlFrame(frame) != nil
		}
		t.reason = reason
		close(t.done)
		for {
			select {
			case item := <-t.inbound:
				link.budget.Release(item.bytes)
			default:
				return
			}
		}
	})
	if stalled {
		// A link that cannot take one bounded control frame cannot end tunnels
		// either. Reset it rather than leave the daemon side open. This runs
		// outside the once: closing the link closes its other tunnels.
		link.close()
	}
}

// splice runs an admitted tunnel until either side, the daemon link or the
// caller's session ends it.
func (t *tunnel) splice(stream tunnelStream) error {
	ctx := stream.Context()
	defer t.close(status.New(codes.Canceled, "client ended the tunnel"), true)
	if !t.awaitOpened(ctx, stream) {
		return nil
	}
	go t.fromClient(ctx, stream)
	for {
		select {
		case item := <-t.inbound:
			err := t.toClient(stream, item.frame)
			t.link.budget.Release(item.bytes)
			if err != nil {
				t.close(status.New(codes.Canceled, "client stream ended"), true)
				return err
			}
		case <-t.done:
			_ = stream.Send(tunnelClose(t.reason.Code(), t.reason.Message()))
			return nil
		case <-ctx.Done():
			// Sign-out or revocation cancels the stream with its reason.
			reason := contextStatus(ctx)
			t.close(reason, true)
			return reason.Err()
		}
	}
}

// contextStatus is why a stream's context ended: the session check's
// status, or the client's cancellation.
func contextStatus(ctx context.Context) *status.Status {
	if value, ok := status.FromError(context.Cause(ctx)); ok && value.Code() != codes.OK {
		return value
	}
	return status.FromContextError(ctx.Err())
}

// awaitOpened waits until the daemon accepted the tunnel and tells the client.
func (t *tunnel) awaitOpened(ctx context.Context, stream tunnelStream) bool {
	timer := time.NewTimer(tunnelOpenedTimeout)
	defer timer.Stop()
	select {
	case item := <-t.inbound:
		t.link.budget.Release(item.bytes)
		switch item.frame.GetKind() {
		case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPENED:
			if err := stream.Send(&gatewayv1.TunnelFrame{Kind: gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPENED}); err != nil {
				t.close(status.New(codes.Canceled, "client stream ended"), true)
				return false
			}
			return true
		case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE:
			t.close(daemonCloseStatus(item.frame), false)
		default:
			t.close(status.New(codes.Unavailable, "daemon sent tunnel data before accepting the tunnel"), true)
		}
	case <-timer.C:
		t.close(status.New(codes.Unavailable, "daemon did not accept the tunnel"), true)
	case <-t.done:
	case <-ctx.Done():
		t.close(contextStatus(ctx), true)
		return false
	}
	_ = stream.Send(tunnelClose(t.reason.Code(), t.reason.Message()))
	return false
}

func daemonCloseStatus(frame *gatewayv1.DaemonLinkFrame) *status.Status {
	return status.New(codes.Code(frame.GetStatusCode()), boundedStatusMessage(frame.GetStatusMessage()))
}

// toClient forwards one daemon frame. A daemon that breaks the protocol
// closes the tunnel; the caller then sends the client CLOSE.
func (t *tunnel) toClient(stream tunnelStream, frame *gatewayv1.DaemonLinkFrame) error {
	switch frame.GetKind() {
	case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_DATA:
		t.mu.Lock()
		t.down++
		exceeded := t.down > relay.TunnelWindow
		t.mu.Unlock()
		if exceeded {
			t.close(status.New(codes.ResourceExhausted, "daemon exceeded the tunnel window"), true)
			return nil
		}
		return stream.Send(&gatewayv1.TunnelFrame{Kind: gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_DATA, Data: frame.GetPayload()})
	case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_WINDOW:
		if !t.credit(&t.up, frame.GetCredit()) {
			t.close(status.New(codes.InvalidArgument, "daemon credited tunnel data it did not receive"), true)
			return nil
		}
		return stream.Send(&gatewayv1.TunnelFrame{Kind: gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_WINDOW, Credit: frame.GetCredit()})
	case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE:
		t.close(daemonCloseStatus(frame), false)
		return nil
	default:
		t.close(status.New(codes.InvalidArgument, "daemon sent an unexpected tunnel frame"), true)
		return nil
	}
}

// credit applies a WINDOW frame to the opposite direction's count. Credit
// for data that was never sent is a protocol violation.
func (t *tunnel) credit(outstanding *int, credit uint32) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if credit == 0 || int64(credit) > int64(*outstanding) {
		return false
	}
	*outstanding -= int(credit)
	return true
}

// fromClient forwards client frames to the daemon through the link's
// round-robin queue until the client or the tunnel ends.
func (t *tunnel) fromClient(ctx context.Context, stream tunnelStream) {
	for {
		frame, err := stream.Recv()
		if err != nil {
			switch {
			case ctx.Err() != nil:
				t.close(contextStatus(ctx), true)
			case errors.Is(err, io.EOF):
				t.close(status.New(codes.OK, "client closed the tunnel"), true)
			default:
				t.close(status.New(codes.Canceled, "client stream ended"), true)
			}
			return
		}
		var forward *gatewayv1.DaemonLinkFrame
		switch frame.GetKind() {
		case gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_DATA:
			if len(frame.GetData()) > relay.ChunkBytes {
				t.close(status.New(codes.ResourceExhausted, "tunnel DATA exceeds 64 KiB"), true)
				return
			}
			t.mu.Lock()
			t.up++
			exceeded := t.up > relay.TunnelWindow
			t.mu.Unlock()
			if exceeded {
				t.close(status.New(codes.ResourceExhausted, "client exceeded the tunnel window"), true)
				return
			}
			forward = &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_DATA, StreamId: t.id, Payload: frame.GetData()}
		case gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_WINDOW:
			if !t.credit(&t.down, frame.GetCredit()) {
				t.close(status.New(codes.InvalidArgument, "client credited tunnel data it did not receive"), true)
				return
			}
			forward = &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_WINDOW, StreamId: t.id, Credit: frame.GetCredit()}
		case gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_CLOSE:
			t.close(status.New(codes.Code(frame.GetStatusCode()), frame.GetStatusMessage()), true)
			return
		default:
			t.close(status.New(codes.InvalidArgument, "client sent an unexpected tunnel frame"), true)
			return
		}
		select {
		case <-t.done:
			return
		default:
		}
		if err := t.link.outbound.Add(forward); err != nil {
			t.close(status.New(codes.ResourceExhausted, "daemon relay channel is congested"), true)
			return
		}
	}
}
