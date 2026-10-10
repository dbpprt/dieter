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

	"github.com/dbpprt/dieter/internal/buildinfo"
	"github.com/dbpprt/dieter/internal/compatibility"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/linkauth"
	"github.com/dbpprt/dieter/internal/relaypolicy"
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
)

const (
	// The daemon idles at a 20-second heartbeat. Require three missed
	// heartbeats before expiring the route so brief scheduler or network stalls
	// do not disconnect every native client at once.
	daemonHeartbeatLease      = 60 * time.Second
	daemonHeartbeatLeaseCheck = time.Second
	daemonHandshakeTimeout    = 10 * time.Second
	// A daemon sends HELLO as soon as its stream opens. An unauthenticated
	// stream that stays silent only holds a handshake slot.
	daemonHelloTimeout  = 3 * time.Second
	maxDaemonHandshakes = 256
	// One machine opens a link per lane, so a few machines behind one address
	// can reconnect together without one source taking the whole pool.
	maxDaemonHandshakesPerClient = 16
	maxDaemonRelayStreams        = relaypolicy.CommandCalls
	// Every client holds a change stream to every online machine and may
	// watch conversations, KV and executions there. These long-lived reads
	// have their own bound, so they cannot starve requests or each other's
	// clients of the ordinary streams.
	maxDaemonWatchStreams = relaypolicy.SubscriptionCalls
)

type Hub struct {
	gatewayv1.UnimplementedDaemonLinkServiceServer
	store      *Store
	config     Config
	handshakes chan struct{}
	// handshakeClients bounds the HTTP ingress share of handshakes per client.
	handshakeClients *clientSlots
	writeTimeout     time.Duration
	leaseCheck       time.Duration

	mu            sync.RWMutex
	links         map[string]*daemonLink
	relayLinks    map[string]map[relaypolicy.Lane]*daemonLink
	sessions      map[string]string
	retired       map[string]map[string]time.Time
	laneMemory    [4]*relaypolicy.Budget
	accountMemory map[int64][4]*relaypolicy.Budget
	nextID        atomic.Uint64
	revision      atomic.Uint64
	changed       chan struct{}
	quota         *QuotaManager
}

type daemonLink struct {
	lane          relaypolicy.Lane
	sessionID     string
	outbound      *relaypolicy.Queue
	budget        *relaypolicy.Budget
	rejected      atomic.Uint64
	lastResponse  atomic.Int64
	sendingAt     atomic.Int64
	controlWebRTC bool
	id            string
	generation    uint64
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
	link   *daemonLink
	id     uint64
	queue  *relayFrameQueue
	once   sync.Once
	done   chan struct{}
	mu     sync.Mutex
	held   int64
	closed bool
}

type queuedRelayFrame struct {
	frame *gatewayv1.DaemonLinkFrame
	bytes int64
}

type relayFrameQueue struct {
	frames chan queuedRelayFrame
	bytes  atomic.Int64
	lane   relaypolicy.Lane
	budget *relaypolicy.Budget
}

func (q *relayFrameQueue) push(frame *gatewayv1.DaemonLinkFrame) bool {
	// Count the whole encoded frame, including metadata. Reserve before the
	// send because the receiver may consume and release it immediately.
	size := int64(proto.Size(frame))
	if q.bytes.Add(size) > maxRelayBufferedBytes {
		q.bytes.Add(-size)
		return false
	}
	if q.budget != nil && !q.budget.Reserve(size) {
		q.bytes.Add(-size)
		return false
	}
	select {
	case q.frames <- queuedRelayFrame{frame: frame, bytes: size}:
		return true
	default:
		q.bytes.Add(-size)
		if q.budget != nil {
			q.budget.Release(size)
		}
		return false
	}
}

func NewHub(store *Store, config Config) *Hub {
	return &Hub{store: store, config: config, writeTimeout: relaypolicy.WriteTimeout, leaseCheck: daemonHeartbeatLeaseCheck, links: map[string]*daemonLink{}, relayLinks: map[string]map[relaypolicy.Lane]*daemonLink{}, sessions: map[string]string{}, retired: map[string]map[string]time.Time{}, accountMemory: map[int64][4]*relaypolicy.Budget{}, changed: make(chan struct{}, 1), handshakes: make(chan struct{}, maxDaemonHandshakes), handshakeClients: newClientSlots(maxDaemonHandshakesPerClient)}
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

func (h *Hub) handshake(stream grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame], helloReceived chan<- struct{}) daemonHandshake {
	hello, err := stream.Recv()
	if err != nil {
		return daemonHandshake{err: err}
	}
	close(helloReceived)
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
	if err := linkauth.VerifyCertificate(record.Certificate, h.config.IdentityOrigin(), identity, challenge, proof.GetPayload()); err != nil {
		return daemonHandshake{err: status.Error(codes.Unauthenticated, "daemon challenge response is invalid")}
	}
	if authenticated, ok := stream.Context().Value(gatewayLinkAuthenticatedKey{}).(chan struct{}); ok {
		close(authenticated)
	}
	if release, ok := stream.Context().Value(gatewayLinkAdmittedKey{}).(func()); ok {
		release()
	}
	return daemonHandshake{hello: hello, record: record}
}

func (h *Hub) authenticateLink(stream grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame], timeout time.Duration) daemonHandshake {
	if release, _ := stream.Context().Value(gatewayLinkAdmittedKey{}).(func()); release == nil {
		select {
		case h.handshakes <- struct{}{}:
			defer func() { <-h.handshakes }()
		default:
			return daemonHandshake{err: status.Error(codes.ResourceExhausted, "daemon handshake concurrency is exhausted")}
		}
	}
	ctx, cancel := context.WithTimeout(stream.Context(), timeout)
	defer cancel()
	result := make(chan daemonHandshake, 1)
	helloReceived := make(chan struct{})
	// Returning the RPC on timeout cancels the underlying gRPC transport and
	// releases any blocked Send/Recv. A derived context alone does not do so.
	go func() { result <- h.handshake(stream, helloReceived) }()
	helloTimer := time.NewTimer(min(daemonHelloTimeout, timeout))
	defer helloTimer.Stop()
	helloDeadline := helloTimer.C
	for {
		select {
		case <-ctx.Done():
			return daemonHandshake{err: status.FromContextError(ctx.Err()).Err()}
		case <-helloDeadline:
			return daemonHandshake{err: status.Error(codes.DeadlineExceeded, "daemon hello was not received")}
		case <-helloReceived:
			helloReceived, helloDeadline = nil, nil
		case authenticated := <-result:
			return authenticated
		}
	}
}

func (h *Hub) connect(stream grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame], timeout time.Duration) error {
	authenticated := h.authenticateLink(stream, timeout)
	if authenticated.err != nil {
		return authenticated.err
	}
	hello, record := authenticated.hello, authenticated.record
	identity := record.ID
	policy, err := compatibilityPolicy(h.config)
	if err != nil {
		return status.Error(codes.Internal, "gateway compatibility policy is invalid")
	}
	compatibilityValue, normalizedRelease := compatibility.Evaluate(hello.GetReleaseVersion(), policy.MinimumDaemonVersion)
	if normalizedRelease == "" {
		normalizedRelease = hello.GetReleaseVersion()
	}
	if compatibilityValue != compatibility.StatusCompatible {
		if err := h.store.MarkDaemonSeen(identity, normalizedRelease, []byte("[]"), []byte("{}")); err != nil {
			return status.Error(codes.Unauthenticated, "daemon is revoked")
		}
		h.signalChanged()
		_ = stream.Send(&gatewayv1.DaemonLinkFrame{
			Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO_ACK,
			DaemonId: identity, Generation: record.Generation, ReleaseVersion: buildinfo.ReleaseVersion,
			CompatibilityPolicy: protoCompatibilityPolicy(policy), Compatibility: protoCompatibilityStatus(compatibilityValue),
		})
		return status.Errorf(codes.FailedPrecondition, "daemon update required: installed %q, minimum %s", normalizedRelease, policy.MinimumDaemonVersion)
	}
	if !relaypolicy.Valid(hello.Lane) || len(hello.SessionId) != 64 {
		return status.Error(codes.InvalidArgument, "valid relay lane and process session are required")
	}

	if hello.Generation != record.Generation {
		return status.Error(codes.Unauthenticated, "daemon enrollment generation is stale")
	}

	controlWebRTC := false
	for _, capability := range hello.GetCapabilities() {
		if capability == "control_webrtc_v1" {
			controlWebRTC = true
			break
		}
	}
	link := &daemonLink{
		id: identity, generation: record.Generation, controlWebRTC: controlWebRTC, lane: hello.Lane, sessionID: hello.SessionId, budget: h.relayBudget(record.GitHubID, hello.Lane),
		control: make(chan *gatewayv1.DaemonLinkFrame, 2*(maxDaemonRelayStreams+maxDaemonWatchStreams)),
		quota:   make(chan *gatewayv1.DaemonLinkFrame, 16), done: make(chan struct{}), streams: map[uint64]*relayFrameQueue{},
		capabilities: map[string]bool{},
	}
	for _, capability := range hello.GetCapabilities() {
		link.capabilities[capability] = true
	}
	link.outbound = relaypolicy.NewQueue(link.budget)
	link.markSeen(time.Now())
	if err := h.register(link); err != nil {
		link.close()
		return err
	}
	defer h.unregister(link)
	// Register before the atomic revoked check: a concurrent revocation must
	// either reject this write or find this link and close it.
	routes, _ := json.Marshal(hello.GetDirectCandidates())
	remoteDesktop, _ := json.Marshal(hello.GetRemoteDesktop())
	current, e := h.store.Daemon(identity)
	if e != nil || current.Revoked || current.Generation != record.Generation {
		return status.Error(codes.Unauthenticated, "daemon enrollment was revoked or replaced")
	}
	if link.lane == relaypolicy.Control {
		if err := h.store.MarkDaemonSeen(identity, normalizedRelease, routes, remoteDesktop); err != nil {
			return status.Error(codes.Unauthenticated, "daemon is revoked")
		}
	}

	sendErr := make(chan error, 1)
	go func() {
		send := func(f *gatewayv1.DaemonLinkFrame, release func()) bool {
			link.sendingAt.Store(time.Now().UnixNano())
			err := stream.Send(f)
			link.sendingAt.Store(0)
			release()
			if err != nil {
				sendErr <- err
				return false
			}
			return true
		}
		for {
			select {
			case <-link.done:
				return
			case f := <-link.control:
				if !send(f, func() {}) {
					return
				}
				continue
			case f := <-link.quota:
				if !send(f, func() {}) {
					return
				}
				continue
			default:
			}
			if f, release := link.outbound.Next(); f != nil {
				if link.hasStream(f.StreamId) {
					if !send(f, release) {
						return
					}
				} else {
					release()
				}
				continue
			}
			select {
			case <-link.done:
				return
			case <-link.outbound.Wake:
			case f := <-link.control:
				if !send(f, func() {}) {
					return
				}
			case f := <-link.quota:
				if !send(f, func() {}) {
					return
				}
			}
		}
	}()
	ack := &gatewayv1.DaemonLinkFrame{
		Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO_ACK,
		DaemonId: identity, Generation: record.Generation, ReleaseVersion: buildinfo.ReleaseVersion, Lane: link.lane, SessionId: link.sessionID,
		CompatibilityPolicy: protoCompatibilityPolicy(policy),
		Compatibility:       gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_COMPATIBLE,
	}
	if link.lane == relaypolicy.Control && h.quota != nil && link.capabilities[providerQuotaCapability] {
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
		assembler := relaypolicy.NewAssembler(link.budget, relaypolicy.Limit(link.lane))
		defer assembler.Close()
		for {
			frame, err := stream.Recv()
			if err != nil {
				recvErr <- err
				return
			}
			if len(frame.GetPayload()) > relaypolicy.ChunkBytes || proto.Size(frame) > 2*relaypolicy.ChunkBytes {
				recvErr <- errors.New("daemon relay fragment exceeds 64 KiB")
				return
			}
			link.markSeen(time.Now())
			for _, id := range assembler.Expired(time.Now()) {
				link.failStream(id, status.Error(codes.DeadlineExceeded, "relay payload assembly expired"))
			}
			switch frame.GetKind() {
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HEARTBEAT:
				if proto.Size(frame) > maxDaemonPresenceBytes {
					recvErr <- status.Error(codes.ResourceExhausted, "daemon presence exceeds 64 KiB")
					return
				}
				if link.lane == relaypolicy.Control {
					routes, _ := json.Marshal(frame.GetDirectCandidates())
					remoteDesktop, _ := json.Marshal(frame.GetRemoteDesktop())
					currentPolicy, policyErr := compatibilityPolicy(h.config)
					value, release := compatibility.Evaluate(frame.GetReleaseVersion(), currentPolicy.MinimumDaemonVersion)
					if policyErr != nil || value != compatibility.StatusCompatible {
						recvErr <- status.Error(codes.FailedPrecondition, "daemon update required by current gateway policy")
						return
					}
					if err := h.store.MarkDaemonSeen(identity, release, routes, remoteDesktop); err != nil {
						recvErr <- err
						return
					}
					h.signalChanged()
				}
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
				link.lastResponse.Store(time.Now().UnixNano())
				for _, id := range assembler.Expired(time.Now()) {
					link.failStream(id, status.Error(codes.DeadlineExceeded, "relay payload assembly expired"))
				}
				if !link.hasStream(frame.StreamId) {
					assembler.Cancel(frame.StreamId)
					continue
				}
				if frame.Kind == gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RPC_ERROR {
					assembler.Cancel(frame.StreamId)
				}
				assembled, release, e := assembler.Accept(frame)
				if e != nil {
					link.failStream(frame.StreamId, status.Error(codes.ResourceExhausted, e.Error()))
					continue
				}
				if assembled != nil {
					link.dispatch(assembled)
					release()
				}

			}
		}
	}()
	lease := time.NewTicker(h.leaseCheck)
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
			if started := link.sendingAt.Load(); started != 0 && time.Since(time.Unix(0, started)) >= h.writeTimeout {
				return status.Error(codes.Unavailable, "relay lane writer is stalled")
			}
			if !link.isAlive(time.Now()) {
				return status.Error(codes.Unavailable, "daemon heartbeat lease expired")
			}
		}
	}
}

// Each lane has reserved account/global byte capacity. Subscriptions cannot
// exhaust the budget that admits health or replication traffic.
func (h *Hub) relayBudget(account int64, lane relaypolicy.Lane) *relaypolicy.Budget {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.laneMemory[lane] == nil {
		h.laneMemory[lane] = relaypolicy.NewBudget(256<<20, nil)
	}
	budgets := h.accountMemory[account]
	if budgets[lane] == nil {
		budgets[lane] = relaypolicy.NewBudget(128<<20, h.laneMemory[lane])
		h.accountMemory[account] = budgets
	}
	return relaypolicy.NewBudget(relaypolicy.BufferedBytes, budgets[lane])
}

func (h *Hub) register(link *daemonLink) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[link.id]
	if link.lane == relaypolicy.Control {
		for id, at := range h.retired[link.id] {
			if time.Since(at) > 2*time.Minute {
				delete(h.retired[link.id], id)
			}
		}
		if _, retired := h.retired[link.id][link.sessionID]; retired {
			h.retired[link.id][link.sessionID] = time.Now()
			return status.Error(codes.FailedPrecondition, "relay process session was replaced")
		}
		if session != "" && session != link.sessionID {
			retired := h.retired[link.id]
			if retired == nil {
				retired = map[string]time.Time{}
				h.retired[link.id] = retired
			}
			if len(retired) >= 64 {
				return status.Error(codes.ResourceExhausted, "relay process session replacement capacity is exhausted")
			}
			retired[session] = time.Now()
			for _, old := range h.relayLinks[link.id] {
				old.close()
			}
			delete(h.relayLinks, link.id)
		}
		h.sessions[link.id] = link.sessionID
		h.links[link.id] = link
	} else if session == "" || session != link.sessionID {
		return status.Error(codes.FailedPrecondition, "control lane must establish this relay process session")
	}
	lanes := h.relayLinks[link.id]
	if lanes == nil {
		lanes = map[relaypolicy.Lane]*daemonLink{}
		h.relayLinks[link.id] = lanes
	}
	if previous := lanes[link.lane]; previous != nil {
		previous.close()
	}
	lanes[link.lane] = link
	h.signalChanged()
	if h.quota != nil {
		h.quota.signalChanged()
	}
	return nil
}

func (h *Hub) unregister(link *daemonLink) {
	h.mu.Lock()
	if h.links[link.id] == link {
		delete(h.links, link.id)
	}
	if h.relayLinks[link.id][link.lane] == link {
		delete(h.relayLinks[link.id], link.lane)
	}
	h.mu.Unlock()
	link.close()
	h.signalChanged()
	if h.quota != nil {
		h.quota.signalChanged()
	}
}

func (h *Hub) RelayLanes(id string) []*gatewayv1.RelayLaneStatus {
	h.mu.RLock()
	defer h.mu.RUnlock()
	result := make([]*gatewayv1.RelayLaneStatus, 0, 4)
	for _, lane := range relaypolicy.Lanes {
		value := &gatewayv1.RelayLaneStatus{Lane: lane, CallLimit: uint32(relaypolicy.Limit(lane))}
		if link := h.relayLinks[id][lane]; link != nil {
			value.Connected = link.isAlive(time.Now())
			link.mu.RLock()
			value.ActiveCalls = uint32(len(link.streams))
			link.mu.RUnlock()
			if link.budget != nil {
				value.QueuedBytes = uint64(link.budget.Used())
			}
			value.RejectedCalls = link.rejected.Load()
			if at := link.lastResponse.Load(); at != 0 {
				value.LastResponseAt = time.Unix(0, at).UTC().Format(time.RFC3339Nano)
			}
			if at := link.sendingAt.Load(); at != 0 {
				value.WriteStalled = time.Since(time.Unix(0, at)) >= h.writeTimeout
			}
		}
		result = append(result, value)
	}
	return result
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

// Presence describes the logical daemon session, not one transport. A control
// reconnect must not tell clients to tear down healthy command/watch streams.
func (h *Hub) Online(id string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, link := range h.relayLinks[id] {
		if link.isAlive(time.Now()) {
			return true
		}
	}
	return false
}

// RelayReady reports that all four independently authenticated lanes are live.
func (h *Hub) RelayReady(id string) bool {
	for _, value := range h.RelayLanes(id) {
		if !value.Connected {
			return false
		}
	}
	return true
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
	defer h.mu.RUnlock()
	for _, link := range h.relayLinks[id] {
		link.close()
	}
}

func (h *Hub) Open(ctx context.Context, daemonID string, frame *gatewayv1.DaemonLinkFrame) (*relayStream, error) {
	if err := ctx.Err(); err != nil {
		return nil, status.FromContextError(err).Err()
	}
	h.mu.RLock()
	lane := relaypolicy.Method(frame.Method)
	link := h.relayLinks[daemonID][lane]
	h.mu.RUnlock()
	if link == nil || !link.isAlive(time.Now()) {
		return nil, status.Errorf(codes.Unavailable, "daemon %s relay channel is unavailable", strings.ToLower(strings.TrimPrefix(lane.String(), "RELAY_LANE_")))
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
	streams, limit := 0, relaypolicy.Limit(lane)
	for _, existing := range link.streams {
		if existing.lane == lane {
			streams++
		}
	}
	if streams >= limit {
		link.rejected.Add(1)
		link.mu.Unlock()
		return nil, status.Error(codes.ResourceExhausted, "daemon relay concurrency is exhausted")
	}
	// A watch may replay several small events plus headers/trailers before its
	// receiver is scheduled. Allow bounded bursts without increasing the old
	// ordinary-RPC memory ceiling (four 16 MiB frames). Large frames still hit
	// the byte limit; a stalled stream never blocks the shared daemon link.
	queue := &relayFrameQueue{frames: make(chan queuedRelayFrame, relayFrameBuffer(frame.GetMethod())), lane: lane, budget: link.budget}
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

func (q *relayFrameQueue) release(frame queuedRelayFrame) {
	q.bytes.Add(-frame.bytes)
	if q.budget != nil {
		q.budget.Release(frame.bytes)
	}
}
func (q *relayFrameQueue) discard() {
	for {
		select {
		case frame, ok := <-q.frames:
			if !ok {
				return
			}
			q.release(frame)
		default:
			return
		}
	}
}
func (s *relayStream) releaseHeld() {
	if s.held != 0 {
		if s.queue.budget != nil {
			s.queue.budget.Release(s.held)
		}
		s.held = 0
	}
}
func (s *relayStream) Recv() (*gatewayv1.DaemonLinkFrame, error) {
	s.mu.Lock()
	s.releaseHeld()
	s.mu.Unlock()
	select {
	case <-s.link.done:
		return nil, status.Error(codes.Unavailable, "daemon disconnected")
	case frame, ok := <-s.queue.frames:
		if !ok {
			return nil, io.EOF
		}
		s.queue.bytes.Add(-frame.bytes)
		s.mu.Lock()
		if s.closed {
			if s.queue.budget != nil {
				s.queue.budget.Release(frame.bytes)
			}
		} else {
			s.held = frame.bytes
		}
		s.mu.Unlock()
		return frame.frame, nil
	}
}
func (s *relayStream) Close() {
	s.once.Do(func() {
		close(s.done)
		if s.link.removeStream(s.id) {
			s.link.cancelStream(s.id)
		}
		s.mu.Lock()
		s.closed = true
		s.releaseHeld()
		s.mu.Unlock()
		s.queue.discard()
	})
}

func (l *daemonLink) sendFrame(ctx context.Context, frame *gatewayv1.DaemonLinkFrame) error {
	if ctx.Err() != nil {
		return status.FromContextError(ctx.Err()).Err()
	}
	select {
	case <-l.done:
		return status.Error(codes.Unavailable, "daemon link is closed")
	default:
	}
	if err := l.outbound.Add(frame); err != nil {
		return status.Error(codes.ResourceExhausted, err.Error())
	}
	return nil
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
	if l.outbound != nil {
		l.outbound.Cancel(id)
	}
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
				if stream.budget != nil {
					stream.budget.Release(frame.bytes)
				}
			default:
				break drain
			}
		}
		value := status.Convert(err)
		failure := &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RPC_ERROR, StreamId: id, StatusCode: int32(value.Code()), StatusMessage: value.Message()}
		if !stream.push(failure) {
			// A full lane must still fail closed. There is one small emergency terminal
			// frame per admitted RPC, outside the data budget; the drained queue has room.
			stream.frames <- queuedRelayFrame{frame: failure}
		}
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
		if l.outbound != nil {
			l.outbound.Close()
		}
		l.mu.Lock()
		for id, stream := range l.streams {
			delete(l.streams, id)
			close(stream.frames)
			stream.discard()
		}
		l.mu.Unlock()
	})
}

func (h *Hub) ControlWebRTC(id string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, link := range h.relayLinks[id] {
		if link.isAlive(time.Now()) && link.controlWebRTC {
			return true
		}
	}
	return false
}
