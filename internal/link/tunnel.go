package link

import (
	"context"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/transport/relay"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// A relay tunnel carries one TLS connection between a client and the
// daemon's DirectServer as opaque bytes. Each side may have at most
// relay.TunnelWindow DATA frames of at most relay.ChunkBytes that the other
// side has not credited; a receiver credits a frame after writing it to its
// socket. The gateway forwards frames and credits and enforces the window,
// so memory stays bounded at every hop and one stalled tunnel never blocks
// another.

type tunnelKind int

const (
	tunnelData tunnelKind = iota
	tunnelWindow
	tunnelClose
)

// tunnelFrame is one frame of a tunnel, independent of its carrier.
type tunnelFrame struct {
	kind    tunnelKind
	data    []byte
	credit  uint32
	code    codes.Code
	message string
}

var errTunnelWindow = errors.New("tunnel peer exceeded its credit window")

// tunnel pumps bytes between a local stream and a framed carrier.
type tunnel struct {
	local net.Conn
	// send delivers frames in order and may block for backpressure.
	send func(tunnelFrame) error
	// reset ends the tunnel at the carrier without blocking.
	reset   func(codes.Code, string)
	onDone  func()
	inbound chan []byte
	credits chan struct{}
	// unacked counts received DATA frames this side has not credited yet.
	unacked atomic.Int32
	done    chan struct{}
	once    sync.Once
}

func newTunnel(local net.Conn, send func(tunnelFrame) error, reset func(codes.Code, string), onDone func()) *tunnel {
	t := &tunnel{
		local: local, send: send, reset: reset, onDone: onDone,
		inbound: make(chan []byte, relay.TunnelWindow), credits: make(chan struct{}, relay.TunnelWindow), done: make(chan struct{}),
	}
	for range relay.TunnelWindow {
		t.credits <- struct{}{}
	}
	return t
}

func (t *tunnel) start() {
	go t.readLocal()
	go t.writeLocal()
}

// deliver accepts one received DATA frame without blocking the carrier.
func (t *tunnel) deliver(data []byte) {
	if len(data) == 0 || len(data) > relay.ChunkBytes {
		t.abort(codes.InvalidArgument, "tunnel frame size is invalid")
		return
	}
	if t.unacked.Add(1) > relay.TunnelWindow {
		t.abort(codes.ResourceExhausted, errTunnelWindow.Error())
		return
	}
	select {
	case <-t.done:
	case t.inbound <- data:
	default:
		t.abort(codes.ResourceExhausted, errTunnelWindow.Error())
	}
}

// grant returns credit for frames the other side consumed.
func (t *tunnel) grant(credit uint32) {
	if credit == 0 || credit > relay.TunnelWindow {
		t.abort(codes.InvalidArgument, "tunnel credit is invalid")
		return
	}
	for range credit {
		select {
		case <-t.done:
			return
		case t.credits <- struct{}{}:
		default:
			t.abort(codes.InvalidArgument, "tunnel credit exceeds the frames sent")
			return
		}
	}
}

func (t *tunnel) readLocal() {
	buffer := make([]byte, relay.ChunkBytes)
	for {
		n, err := t.local.Read(buffer)
		if n > 0 {
			select {
			case <-t.done:
				return
			case <-t.credits:
			}
			if sendErr := t.send(tunnelFrame{kind: tunnelData, data: append([]byte(nil), buffer[:n]...)}); sendErr != nil {
				t.abort(codes.Unavailable, "tunnel carrier failed")
				return
			}
		}
		if err != nil {
			select {
			case <-t.done:
			default:
				// Every DATA frame queued before the close reaches the peer first.
				_ = t.send(tunnelFrame{kind: tunnelClose, code: codes.OK})
				t.finish()
			}
			return
		}
	}
}

func (t *tunnel) writeLocal() {
	for {
		select {
		case <-t.done:
			return
		case data := <-t.inbound:
			_ = t.local.SetWriteDeadline(time.Now().Add(relay.WriteTimeout))
			if _, err := t.local.Write(data); err != nil {
				t.abort(codes.DeadlineExceeded, "tunnel endpoint stalled")
				return
			}
			// The frame left this side before its credit does, so the peer can
			// never appear to exceed the window.
			t.unacked.Add(-1)
			if err := t.send(tunnelFrame{kind: tunnelWindow, credit: 1}); err != nil {
				t.abort(codes.Unavailable, "tunnel carrier failed")
				return
			}
		}
	}
}

// finish releases the tunnel without notifying the peer.
func (t *tunnel) finish() {
	t.once.Do(func() {
		close(t.done)
		_ = t.local.Close()
		if t.onDone != nil {
			t.onDone()
		}
	})
}

// abort ends the tunnel and tells the peer why.
func (t *tunnel) abort(code codes.Code, message string) {
	select {
	case <-t.done:
		return
	default:
	}
	t.reset(code, message)
	t.finish()
}

// Close ends the tunnel locally, e.g. when its carrier disconnected.
func (t *tunnel) Close() { t.finish() }

// DialTunnel opens a relay tunnel to daemonID on lane through conn, a gateway
// connection whose calls already carry credentials. The returned connection
// carries opaque bytes: run mutually authenticated TLS over it (DialDaemon).
func DialTunnel(ctx context.Context, conn grpc.ClientConnInterface, daemonID string, lane relay.Lane) (net.Conn, error) {
	if !relay.Valid(lane) || daemonID == "" {
		return nil, errors.New("tunnel target is invalid")
	}
	streamCtx, cancel := context.WithCancel(context.Background())
	stream, err := gatewayv1.NewRelayServiceClient(conn).OpenTunnel(streamCtx)
	if err != nil {
		cancel()
		return nil, err
	}
	opened := make(chan error, 1)
	go func() {
		if err := stream.Send(&gatewayv1.TunnelFrame{Kind: gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPEN, DaemonId: daemonID, Lane: lane}); err != nil {
			opened <- err
			return
		}
		frame, err := stream.Recv()
		switch {
		case err != nil:
			opened <- err
		case frame.GetKind() == gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPENED:
			opened <- nil
		case frame.GetKind() == gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_CLOSE:
			opened <- status.Error(codes.Code(frame.GetStatusCode()), frame.GetStatusMessage())
		default:
			opened <- status.Error(codes.Internal, "gateway sent an invalid tunnel frame")
		}
	}()
	select {
	case <-ctx.Done():
		cancel()
		return nil, ctx.Err()
	case err := <-opened:
		if err != nil {
			cancel()
			return nil, err
		}
	}
	user, local := net.Pipe()
	var sendMu sync.Mutex
	send := func(frame tunnelFrame) error {
		value := &gatewayv1.TunnelFrame{}
		switch frame.kind {
		case tunnelData:
			value.Kind, value.Data = gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_DATA, frame.data
		case tunnelWindow:
			value.Kind, value.Credit = gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_WINDOW, frame.credit
		default:
			value.Kind, value.StatusCode, value.StatusMessage = gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_CLOSE, int32(frame.code), frame.message
		}
		sendMu.Lock()
		defer sendMu.Unlock()
		return stream.Send(value)
	}
	t := newTunnel(local, send, func(codes.Code, string) { cancel() }, cancel)
	go func() {
		defer t.finish()
		for {
			frame, err := stream.Recv()
			if err != nil {
				return
			}
			switch frame.GetKind() {
			case gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_DATA:
				t.deliver(frame.GetData())
			case gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_WINDOW:
				t.grant(frame.GetCredit())
			case gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_CLOSE:
				return
			default:
				t.abort(codes.InvalidArgument, "gateway sent an invalid tunnel frame")
				return
			}
		}
	}()
	t.start()
	// Closing user ends the local pipe; the pump then sends CLOSE after every
	// queued DATA frame.
	return user, nil
}

// linkTunnels are the tunnels of one daemon link lane.
type linkTunnels struct {
	mu      sync.Mutex
	items   map[uint64]*tunnel
	pending map[uint64]bool
	closed  bool
}

func newLinkTunnels() *linkTunnels {
	return &linkTunnels{items: map[uint64]*tunnel{}, pending: map[uint64]bool{}}
}

// reserve admits a new tunnel ID within limit.
func (l *linkTunnels) reserve(id uint64, limit int) (bool, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.closed || l.items[id] != nil || l.pending[id] {
		return false, true
	}
	if len(l.items)+len(l.pending) >= limit {
		return false, false
	}
	l.pending[id] = true
	return true, false
}

func (l *linkTunnels) activate(id uint64, t *tunnel) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.pending, id)
	if l.closed {
		return false
	}
	l.items[id] = t
	return true
}

func (l *linkTunnels) release(id uint64) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.pending, id)
	delete(l.items, id)
}

func (l *linkTunnels) get(id uint64) *tunnel {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.items[id]
}

// close ends every tunnel of a disconnected link. Agents and RPCs inside the
// daemon keep running; only their transport goes away.
func (l *linkTunnels) close() {
	l.mu.Lock()
	l.closed = true
	items := make([]*tunnel, 0, len(l.items))
	for _, t := range l.items {
		items = append(items, t)
	}
	l.mu.Unlock()
	for _, t := range items {
		t.Close()
	}
}
