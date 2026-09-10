package gateway

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/linkauth"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

const (
	maxRelayPayload               = 16 << 20
	defaultRelayFrameBuffer       = 64
	remoteDesktopRelayFrameBuffer = 128
	// WatchExecution can replay all 4096 events retained by remoteexec before
	// its receiver runs, plus the transport header and trailer. Keep this in
	// sync with maxRetainedEventFrames in internal/remoteexec/manager_unix.go.
	executionRelayFrameBuffer = 4096 + 2
	maxRelayBufferedBytes     = 64 << 20
	heartbeatAckCapability    = "heartbeat_ack_v1"
)

const (
	// The daemon idles at a 20-second heartbeat. Require three missed
	// heartbeats before expiring the route so brief scheduler or network stalls
	// do not disconnect every native client at once.
	daemonHeartbeatLease      = 60 * time.Second
	daemonHeartbeatLeaseCheck = time.Second
)

type Hub struct {
	gatewayv1.UnimplementedDaemonLinkServiceServer
	store  *Store
	config Config

	mu       sync.RWMutex
	links    map[string]*daemonLink
	nextID   atomic.Uint64
	revision atomic.Uint64
	changed  chan struct{}
}

type daemonLink struct {
	id         string
	generation uint64
	send       chan *gatewayv1.DaemonLinkFrame
	control    chan *gatewayv1.DaemonLinkFrame
	done       chan struct{}
	closeOnce  sync.Once
	mu         sync.RWMutex
	streams    map[uint64]*relayFrameQueue
	lastSeenAt atomic.Int64
}

type relayStream struct {
	link  *daemonLink
	id    uint64
	queue *relayFrameQueue
	once  sync.Once
}

type queuedRelayFrame struct {
	frame *gatewayv1.DaemonLinkFrame
	bytes int64
}

type relayFrameQueue struct {
	frames chan queuedRelayFrame
	bytes  atomic.Int64
}

func (q *relayFrameQueue) push(frame *gatewayv1.DaemonLinkFrame) bool {
	// Count the whole encoded frame, including metadata. Reserve before the
	// send because the receiver may consume and release it immediately.
	size := int64(proto.Size(frame))
	if q.bytes.Add(size) > maxRelayBufferedBytes {
		q.bytes.Add(-size)
		return false
	}
	select {
	case q.frames <- queuedRelayFrame{frame: frame, bytes: size}:
		return true
	default:
		q.bytes.Add(-size)
		return false
	}
}

func NewHub(store *Store, config Config) *Hub {
	return &Hub{store: store, config: config, links: map[string]*daemonLink{}, changed: make(chan struct{}, 1)}
}

func (h *Hub) Connect(stream grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame]) error {
	hello, err := stream.Recv()
	if err != nil {
		return err
	}
	identity := hello.GetDaemonId()
	if hello.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO || identity == "" {
		return status.Error(codes.Unauthenticated, "daemon hello is required")
	}
	record, err := h.store.Daemon(identity)
	if err != nil || record.Revoked {
		return status.Error(codes.Unauthenticated, "daemon is not enrolled")
	}
	challenge := make([]byte, 32)
	if _, err := rand.Read(challenge); err != nil {
		return status.Error(codes.Internal, "create daemon challenge")
	}
	challengeID := randomID("link_")
	if err := stream.Send(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PING, DaemonId: identity, RequestId: challengeID, Payload: challenge}); err != nil {
		return err
	}
	proof, err := stream.Recv()
	if err != nil || proof.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG || proof.GetDaemonId() != identity || proof.GetRequestId() != challengeID {
		return status.Error(codes.Unauthenticated, "daemon challenge response is invalid")
	}
	if err := linkauth.VerifyCertificate(record.Certificate, h.config.PublicURL.String(), identity, challenge, proof.GetPayload()); err != nil {
		return status.Error(codes.Unauthenticated, "daemon challenge response is invalid")
	}
	routes, _ := json.Marshal(hello.GetDirectCandidates())
	remoteDesktop, _ := json.Marshal(hello.GetRemoteDesktop())
	if err := h.store.MarkDaemonSeen(identity, hello.GetVersion(), hello.GetApiVersion(), routes, remoteDesktop); err != nil {
		return status.Error(codes.Unauthenticated, "daemon is revoked")
	}
	link := &daemonLink{
		id: identity, generation: record.Generation,
		send: make(chan *gatewayv1.DaemonLinkFrame, 8), control: make(chan *gatewayv1.DaemonLinkFrame, 4),
		done: make(chan struct{}), streams: map[uint64]*relayFrameQueue{},
	}
	link.markSeen(time.Now())
	h.register(link)
	defer h.unregister(link)

	sendErr := make(chan error, 1)
	go func() {
		for {
			select {
			case <-link.done:
				sendErr <- nil
				return
			case frame := <-link.control:
				if err := stream.Send(frame); err != nil {
					sendErr <- err
					return
				}
				continue
			default:
			}
			select {
			case <-link.done:
				sendErr <- nil
				return
			case frame := <-link.control:
				if err := stream.Send(frame); err != nil {
					sendErr <- err
					return
				}
			case frame := <-link.send:
				if err := stream.Send(frame); err != nil {
					sendErr <- err
					return
				}
			}
		}
	}()
	link.sendControlFrame(&gatewayv1.DaemonLinkFrame{
		Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO_ACK,
		DaemonId: identity, Generation: record.Generation, Version: "1",
		Capabilities: []string{heartbeatAckCapability},
	})

	recvErr := make(chan error, 1)
	go func() {
		for {
			frame, err := stream.Recv()
			if err != nil {
				recvErr <- err
				return
			}
			if len(frame.GetPayload()) > maxRelayPayload {
				recvErr <- errors.New("daemon relay frame exceeds 16 MiB")
				return
			}
			link.markSeen(time.Now())
			switch frame.GetKind() {
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HEARTBEAT:
				routes, _ := json.Marshal(frame.GetDirectCandidates())
				remoteDesktop, _ := json.Marshal(frame.GetRemoteDesktop())
				if err := h.store.MarkDaemonSeen(identity, frame.GetVersion(), frame.GetApiVersion(), routes, remoteDesktop); err != nil {
					recvErr <- err
					return
				}
				h.signalChanged()
				if frame.GetRequestId() != "" {
					if err := link.sendControlFrame(&gatewayv1.DaemonLinkFrame{
						Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG,
						DaemonId: identity, RequestId: frame.GetRequestId(),
					}); err != nil {
						recvErr <- err
						return
					}
				}
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PING:
				link.sendControlFrame(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG, DaemonId: identity, RequestId: frame.GetRequestId()})
			default:
				link.dispatch(frame)
			}
		}
	}()
	lease := time.NewTicker(daemonHeartbeatLeaseCheck)
	defer lease.Stop()
	for {
		select {
		case err := <-sendErr:
			return err
		case err := <-recvErr:
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		case <-stream.Context().Done():
			return stream.Context().Err()
		case <-lease.C:
			if !link.isAlive(time.Now()) {
				return status.Error(codes.Unavailable, "daemon heartbeat lease expired")
			}
		}
	}
}

func (h *Hub) register(link *daemonLink) {
	h.mu.Lock()
	if previous := h.links[link.id]; previous != nil {
		previous.close()
	}
	h.links[link.id] = link
	h.mu.Unlock()
	h.signalChanged()
}

func (h *Hub) unregister(link *daemonLink) {
	h.mu.Lock()
	if h.links[link.id] == link {
		delete(h.links, link.id)
	}
	h.mu.Unlock()
	link.close()
	h.signalChanged()
}

func (h *Hub) signalChanged() {
	h.revision.Add(1)
	select {
	case h.changed <- struct{}{}:
	default:
	}
}

func (h *Hub) Changed() <-chan struct{} { return h.changed }

func (h *Hub) Revision() uint64 { return h.revision.Load() }

func (h *Hub) Online(id string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	link := h.links[id]
	return link != nil && link.isAlive(time.Now())
}

func (h *Hub) CloseDaemon(id string) {
	h.mu.RLock()
	link := h.links[id]
	h.mu.RUnlock()
	if link != nil {
		link.close()
	}
}

func (h *Hub) Open(ctx context.Context, daemonID string, frame *gatewayv1.DaemonLinkFrame) (*relayStream, error) {
	h.mu.RLock()
	link := h.links[daemonID]
	h.mu.RUnlock()
	if link == nil || !link.isAlive(time.Now()) {
		return nil, status.Error(14, "daemon is offline")
	}
	id := h.nextID.Add(1)
	if id == 0 {
		id = h.nextID.Add(1)
	}
	link.mu.Lock()
	select {
	case <-link.done:
		link.mu.Unlock()
		return nil, status.Error(14, "daemon disconnected")
	default:
	}
	if len(link.streams) >= 16 {
		link.mu.Unlock()
		return nil, status.Error(codes.ResourceExhausted, "daemon relay concurrency is exhausted")
	}
	// A watch may replay several small events plus headers/trailers before its
	// receiver is scheduled. Allow bounded bursts without increasing the old
	// ordinary-RPC memory ceiling (four 16 MiB frames). Large frames still hit
	// the byte limit; a stalled stream never blocks the shared daemon link.
	queue := &relayFrameQueue{frames: make(chan queuedRelayFrame, relayFrameBuffer(frame.GetMethod()))}
	link.streams[id] = queue
	link.mu.Unlock()
	frame.StreamId, frame.DaemonId = id, daemonID
	if err := link.sendFrame(frame); err != nil {
		link.removeStream(id)
		return nil, status.Error(14, "daemon disconnected")
	}
	result := &relayStream{link: link, id: id, queue: queue}
	go func() {
		select {
		case <-ctx.Done():
			_ = link.sendFrame(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_CANCEL_RPC, StreamId: id})
			result.Close()
		case <-link.done:
		}
	}()
	return result, nil
}

func relayFrameBuffer(method string) int {
	if strings.HasSuffix(method, "/StartRemoteDesktop") {
		return remoteDesktopRelayFrameBuffer
	}
	if strings.HasSuffix(method, "/WatchExecution") {
		return executionRelayFrameBuffer
	}
	return defaultRelayFrameBuffer
}

func (l *daemonLink) markSeen(now time.Time) {
	l.lastSeenAt.Store(now.UnixNano())
}

func (l *daemonLink) isAlive(now time.Time) bool {
	lastSeenAt := l.lastSeenAt.Load()
	return lastSeenAt > 0 && now.Sub(time.Unix(0, lastSeenAt)) < daemonHeartbeatLease
}

func (s *relayStream) Recv() (*gatewayv1.DaemonLinkFrame, error) {
	select {
	case <-s.link.done:
		return nil, status.Error(14, "daemon disconnected")
	case frame, ok := <-s.queue.frames:
		if !ok {
			return nil, io.EOF
		}
		s.queue.bytes.Add(-frame.bytes)
		return frame.frame, nil
	}
}

func (s *relayStream) Close() {
	s.once.Do(func() { s.link.removeStream(s.id) })
}

func (l *daemonLink) sendFrame(frame *gatewayv1.DaemonLinkFrame) error {
	select {
	case <-l.done:
		return errors.New("daemon link is closed")
	case l.send <- frame:
		return nil
	}
}

func (l *daemonLink) sendControlFrame(frame *gatewayv1.DaemonLinkFrame) error {
	select {
	case <-l.done:
		return errors.New("daemon link is closed")
	case l.control <- frame:
		return nil
	}
}

func (l *daemonLink) dispatch(frame *gatewayv1.DaemonLinkFrame) {
	l.mu.RLock()
	stream := l.streams[frame.GetStreamId()]
	if stream == nil {
		l.mu.RUnlock()
		return
	}
	if !stream.push(frame) {
		l.mu.RUnlock()
		l.failStream(frame.GetStreamId(), status.Error(codes.ResourceExhausted, "relay client is not consuming responses"))
		return
	}
	l.mu.RUnlock()
	if frame.GetKind() == gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_END || frame.GetKind() == gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RPC_ERROR {
		l.removeStream(frame.GetStreamId())
	}
}

func (l *daemonLink) failStream(id uint64, err error) {
	l.mu.Lock()
	stream := l.streams[id]
	delete(l.streams, id)
	if stream != nil {
	drain:
		for {
			select {
			case frame := <-stream.frames:
				stream.bytes.Add(-frame.bytes)
			default:
				break drain
			}
		}
		value := status.Convert(err)
		stream.push(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RPC_ERROR, StreamId: id, StatusCode: int32(value.Code()), StatusMessage: value.Message()})
		close(stream.frames)
	}
	l.mu.Unlock()
}

func (l *daemonLink) removeStream(id uint64) {
	l.mu.Lock()
	stream := l.streams[id]
	delete(l.streams, id)
	l.mu.Unlock()
	if stream != nil {
		close(stream.frames)
	}
}

func (l *daemonLink) close() {
	l.closeOnce.Do(func() {
		close(l.done)
		l.mu.Lock()
		for id, stream := range l.streams {
			delete(l.streams, id)
			close(stream.frames)
		}
		l.mu.Unlock()
	})
}
