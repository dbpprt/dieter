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
	maxDaemonPresenceBytes        = 64 << 10
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
	daemonHandshakeTimeout    = 10 * time.Second
	maxDaemonHandshakes       = 64
	maxDaemonRelayStreams     = 16
)

type Hub struct {
	gatewayv1.UnimplementedDaemonLinkServiceServer
	store      *Store
	config     Config
	handshakes chan struct{}

	mu       sync.RWMutex
	links    map[string]*daemonLink
	nextID   atomic.Uint64
	revision atomic.Uint64
	changed  chan struct{}
	quota    *QuotaManager
}

type daemonLink struct {
	controlWebRTC bool
	id            string
	generation    uint64
	send          chan *gatewayv1.DaemonLinkFrame
	control       chan *gatewayv1.DaemonLinkFrame
	quota         chan *gatewayv1.DaemonLinkFrame
	done          chan struct{}
	closeOnce     sync.Once
	mu            sync.RWMutex
	streams       map[uint64]*relayFrameQueue
	lastSeenAt    atomic.Int64
	capabilities  map[string]bool
}

type relayStream struct {
	link  *daemonLink
	id    uint64
	queue *relayFrameQueue
	once  sync.Once
	done  chan struct{}
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
	return &Hub{store: store, config: config, links: map[string]*daemonLink{}, changed: make(chan struct{}, 1), handshakes: make(chan struct{}, maxDaemonHandshakes)}
}

func (h *Hub) SetQuotaManager(manager *QuotaManager) { h.quota = manager }

func (h *Hub) Connect(stream grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame]) error {
	return h.connect(stream, daemonHandshakeTimeout)
}

type daemonHandshake struct {
	hello  *gatewayv1.DaemonLinkFrame
	record DaemonRecord
	err    error
}

func (h *Hub) handshake(stream grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame]) daemonHandshake {
	hello, err := stream.Recv()
	if err != nil {
		return daemonHandshake{err: err}
	}
	identity := hello.GetDaemonId()
	if hello.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO || identity == "" {
		return daemonHandshake{err: status.Error(codes.Unauthenticated, "daemon hello is required")}
	}
	if proto.Size(hello) > maxDaemonPresenceBytes {
		return daemonHandshake{err: status.Error(codes.ResourceExhausted, "daemon presence exceeds 64 KiB")}
	}
	record, err := h.store.Daemon(identity)
	if err != nil || record.Revoked || !h.config.AllowsGitHubUser(record.GitHubID) {
		return daemonHandshake{err: status.Error(codes.Unauthenticated, "daemon is not enrolled")}
	}
	challenge := make([]byte, 32)
	if _, err := rand.Read(challenge); err != nil {
		return daemonHandshake{err: status.Error(codes.Internal, "create daemon challenge")}
	}
	challengeID := randomID("link_")
	if err := stream.Send(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PING, DaemonId: identity, RequestId: challengeID, Payload: challenge}); err != nil {
		return daemonHandshake{err: err}
	}
	proof, err := stream.Recv()
	if err != nil || proof.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG || proof.GetDaemonId() != identity || proof.GetRequestId() != challengeID {
		return daemonHandshake{err: status.Error(codes.Unauthenticated, "daemon challenge response is invalid")}
	}
	if err := linkauth.VerifyCertificate(record.Certificate, h.config.PublicURL.String(), identity, challenge, proof.GetPayload()); err != nil {
		return daemonHandshake{err: status.Error(codes.Unauthenticated, "daemon challenge response is invalid")}
	}
	return daemonHandshake{hello: hello, record: record}
}

func (h *Hub) authenticateLink(stream grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame], timeout time.Duration) daemonHandshake {
	select {
	case h.handshakes <- struct{}{}:
		defer func() { <-h.handshakes }()
	default:
		return daemonHandshake{err: status.Error(codes.ResourceExhausted, "daemon handshake concurrency is exhausted")}
	}
	ctx, cancel := context.WithTimeout(stream.Context(), timeout)
	defer cancel()
	result := make(chan daemonHandshake, 1)
	// Returning the RPC on timeout cancels the underlying gRPC transport and
	// releases any blocked Send/Recv. A derived context alone does not do so.
	go func() { result <- h.handshake(stream) }()
	select {
	case <-ctx.Done():
		return daemonHandshake{err: status.FromContextError(ctx.Err()).Err()}
	case authenticated := <-result:
		return authenticated
	}
}

func (h *Hub) connect(stream grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame], timeout time.Duration) error {
	authenticated := h.authenticateLink(stream, timeout)
	if authenticated.err != nil {
		return authenticated.err
	}
	hello, record := authenticated.hello, authenticated.record
	identity := record.ID
	controlWebRTC := false
	for _, capability := range hello.GetCapabilities() {
		if capability == "control_webrtc_v1" {
			controlWebRTC = true
			break
		}
	}
	link := &daemonLink{
		id: identity, generation: record.Generation, controlWebRTC: controlWebRTC,
		send: make(chan *gatewayv1.DaemonLinkFrame, 8), control: make(chan *gatewayv1.DaemonLinkFrame, 2*maxDaemonRelayStreams),
		quota: make(chan *gatewayv1.DaemonLinkFrame, 16), done: make(chan struct{}), streams: map[uint64]*relayFrameQueue{},
		capabilities: map[string]bool{},
	}
	for _, capability := range hello.GetCapabilities() {
		link.capabilities[capability] = true
	}
	link.markSeen(time.Now())
	h.register(link)
	defer h.unregister(link)
	// Register before the atomic revoked check: a concurrent revocation must
	// either reject this write or find this link and close it.
	routes, _ := json.Marshal(hello.GetDirectCandidates())
	remoteDesktop, _ := json.Marshal(hello.GetRemoteDesktop())
	if err := h.store.MarkDaemonSeen(identity, hello.GetVersion(), hello.GetApiVersion(), routes, remoteDesktop); err != nil {
		return status.Error(codes.Unauthenticated, "daemon is revoked")
	}

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
			case frame := <-link.quota:
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
			case frame := <-link.quota:
				if err := stream.Send(frame); err != nil {
					sendErr <- err
					return
				}
			case frame := <-link.send:
				// A prioritized cancellation may precede an unsent OPEN. Never
				// dispatch that canceled request after its cancellation.
				if !link.hasStream(frame.GetStreamId()) {
					continue
				}
				if err := stream.Send(frame); err != nil {
					sendErr <- err
					return
				}
			}
		}
	}()
	ack := &gatewayv1.DaemonLinkFrame{
		Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO_ACK,
		DaemonId: identity, Generation: record.Generation, Version: "1",
		Capabilities: []string{heartbeatAckCapability},
	}
	if h.quota != nil && link.capabilities[providerQuotaCapability] {
		correlationKey, err := h.store.ProviderCorrelationKey(record.GitHubID)
		if err != nil {
			return status.Error(codes.Internal, "load provider account correlation key")
		}
		ack.Capabilities = append(ack.Capabilities, providerQuotaCapability)
		ack.ProviderAccountCorrelationKey = correlationKey
		if link.capabilities[providerQuotaResetCapability] {
			ack.Capabilities = append(ack.Capabilities, providerQuotaResetCapability)
		}
	}
	link.sendControlFrame(ack)

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
				if proto.Size(frame) > maxDaemonPresenceBytes {
					recvErr <- status.Error(codes.ResourceExhausted, "daemon presence exceeds 64 KiB")
					return
				}
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
				if err := link.sendControlFrame(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG, DaemonId: identity, RequestId: frame.GetRequestId()}); err != nil {
					recvErr <- err
					return
				}
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_ACCOUNTS:
				if h.quota == nil || !link.capabilities[providerQuotaCapability] || frame.GetDaemonId() != identity {
					recvErr <- status.Error(codes.PermissionDenied, "provider quota capability was not negotiated")
					return
				}
				if err := h.quota.HandlePresence(record, identity, frame.GetProviderAccounts()); err != nil {
					recvErr <- status.Error(codes.InvalidArgument, err.Error())
					return
				}
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_QUOTA_REFRESH_RESULT:
				if h.quota == nil || !link.capabilities[providerQuotaCapability] || frame.GetDaemonId() != identity {
					recvErr <- status.Error(codes.PermissionDenied, "provider quota capability was not negotiated")
					return
				}
				if err := h.quota.HandleResult(record, identity, frame.GetRequestId(), frame.GetProviderQuotaRefreshResult()); err != nil {
					recvErr <- status.Error(codes.InvalidArgument, err.Error())
					return
				}
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_QUOTA_RESET_RESULT:
				if h.quota == nil || !link.capabilities[providerQuotaResetCapability] || frame.GetDaemonId() != identity {
					recvErr <- status.Error(codes.PermissionDenied, "provider quota reset capability was not negotiated")
					return
				}
				if err := h.quota.HandleResetResult(record, identity, frame.GetRequestId(), frame.GetProviderQuotaResetResult()); err != nil {
					recvErr <- status.Error(codes.InvalidArgument, err.Error())
					return
				}
			default:
				link.dispatch(frame)
			}
		}
	}()
	lease := time.NewTicker(daemonHeartbeatLeaseCheck)
	defer lease.Stop()
	for {
		select {
		case <-link.done:
			return status.Error(codes.Unavailable, "daemon link is closed")
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
	if h.quota != nil {
		h.quota.signalChanged()
	}
}

func (h *Hub) unregister(link *daemonLink) {
	h.mu.Lock()
	if h.links[link.id] == link {
		delete(h.links, link.id)
	}
	h.mu.Unlock()
	link.close()
	h.signalChanged()
	if h.quota != nil {
		h.quota.signalChanged()
	}
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

func (h *Hub) SupportsProviderQuotas(id string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	link := h.links[id]
	return link != nil && link.isAlive(time.Now()) && link.capabilities[providerQuotaCapability]
}

func (h *Hub) SupportsProviderQuotaReset(id string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	link := h.links[id]
	return link != nil && link.isAlive(time.Now()) && link.capabilities[providerQuotaResetCapability]
}

func (h *Hub) SendProviderQuotaRefresh(daemonID, requestID string, request *gatewayv1.ProviderQuotaRefreshRequest) error {
	if requestID == "" || request == nil || proto.Size(request) > maxProviderQuotaFrameBytes {
		return status.Error(codes.InvalidArgument, "provider quota refresh request is invalid")
	}
	h.mu.RLock()
	link := h.links[daemonID]
	h.mu.RUnlock()
	if link == nil || !link.isAlive(time.Now()) || !link.capabilities[providerQuotaCapability] {
		return status.Error(codes.Unavailable, "provider quota source is offline")
	}
	return link.sendQuotaFrame(&gatewayv1.DaemonLinkFrame{
		Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_QUOTA_REFRESH_REQUEST,
		DaemonId: daemonID, RequestId: requestID, ProviderQuotaRefreshRequest: request,
	})
}

func (h *Hub) SendProviderQuotaReset(daemonID, requestID string, request *gatewayv1.ProviderQuotaResetRequest) error {
	if requestID == "" || request == nil || proto.Size(request) > maxProviderQuotaFrameBytes {
		return status.Error(codes.InvalidArgument, "provider quota reset request is invalid")
	}
	h.mu.RLock()
	link := h.links[daemonID]
	h.mu.RUnlock()
	if link == nil || !link.isAlive(time.Now()) || !link.capabilities[providerQuotaResetCapability] {
		return status.Error(codes.Unavailable, "provider quota reset source is offline")
	}
	return link.sendQuotaFrame(&gatewayv1.DaemonLinkFrame{
		Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_QUOTA_RESET_REQUEST,
		DaemonId: daemonID, RequestId: requestID, ProviderQuotaResetRequest: request,
	})
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
	if err := ctx.Err(); err != nil {
		return nil, status.FromContextError(err).Err()
	}
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
	if len(link.streams) >= maxDaemonRelayStreams {
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
	if err := link.sendFrame(ctx, frame); err != nil {
		link.removeStream(id)
		return nil, err
	}
	result := &relayStream{link: link, id: id, queue: queue, done: make(chan struct{})}
	go func() {
		select {
		case <-ctx.Done():
			result.Close()
		case <-link.done:
		case <-result.done:
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
	select {
	case <-l.done:
		return false
	default:
	}
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
	s.once.Do(func() {
		close(s.done)
		if s.link.removeStream(s.id) {
			s.link.cancelStream(s.id)
		}
	})
}

func (l *daemonLink) sendFrame(ctx context.Context, frame *gatewayv1.DaemonLinkFrame) error {
	select {
	case <-ctx.Done():
		return status.FromContextError(ctx.Err()).Err()
	case <-l.done:
		return status.Error(codes.Unavailable, "daemon link is closed")
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
	default:
		return status.Error(codes.ResourceExhausted, "daemon control queue is stalled")
	}
}

func (l *daemonLink) sendQuotaFrame(frame *gatewayv1.DaemonLinkFrame) error {
	select {
	case <-l.done:
		return errors.New("daemon link is closed")
	case l.quota <- frame:
		return nil
	default:
		return status.Error(codes.ResourceExhausted, "provider quota queue is stalled")
	}
}

func (l *daemonLink) hasStream(id uint64) bool {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return l.streams[id] != nil
}

func (l *daemonLink) cancelStream(id uint64) {
	if err := l.sendControlFrame(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_CANCEL_RPC, StreamId: id}); err != nil {
		// A peer that cannot consume its bounded control queue cannot honor
		// cancellation. Tear down that stalled transport rather than leak RPCs.
		l.close()
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
	if stream != nil {
		l.cancelStream(id)
	}
}

func (l *daemonLink) removeStream(id uint64) bool {
	l.mu.Lock()
	stream := l.streams[id]
	delete(l.streams, id)
	l.mu.Unlock()
	if stream != nil {
		close(stream.frames)
	}
	return stream != nil
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

func (h *Hub) ControlWebRTC(id string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	link := h.links[id]
	if link == nil {
		return false
	}
	return link.controlWebRTC
}
