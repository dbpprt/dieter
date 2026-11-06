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
	"github.com/dbpprt/dieter/internal/platform/buildinfo"
	"github.com/dbpprt/dieter/internal/platform/version"
	"github.com/dbpprt/dieter/internal/security/linkauth"
	"github.com/dbpprt/dieter/internal/transport/relay"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

const (
	// The largest message a client or daemon sends the gateway: tunnel and
	// presence frames are at most 64 KiB, roster entries at most 1 KiB.
	maxGatewayMessageBytes = 1 << 20
	// The largest message the gateway sends: a full device roster.
	maxGatewayResponseBytes = 8 << 20
	maxDaemonPresenceBytes  = 64 << 10
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
	relayLinks    map[string]map[relay.Lane]*daemonLink
	sessions      map[string]string
	retired       map[string]map[string]time.Time
	laneMemory    [4]*relay.Budget
	accountMemory map[int64][4]*relay.Budget
	nextID        atomic.Uint64
	revision      atomic.Uint64
	changed       chan struct{}
	quota         *QuotaManager
}

type daemonLink struct {
	lane          relay.Lane
	sessionID     string
	outbound      *relay.Queue
	budget        *relay.Budget
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
	tunnels       map[uint64]*tunnel
	lastSeenAt    atomic.Int64
	capabilities  map[string]bool
}

func NewHub(store *Store, config Config) *Hub {
	return &Hub{store: store, config: config, writeTimeout: relay.WriteTimeout, leaseCheck: daemonHeartbeatLeaseCheck, links: map[string]*daemonLink{}, relayLinks: map[string]map[relay.Lane]*daemonLink{}, sessions: map[string]string{}, retired: map[string]map[string]time.Time{}, accountMemory: map[int64][4]*relay.Budget{}, changed: make(chan struct{}, 1), handshakes: make(chan struct{}, maxDaemonHandshakes), handshakeClients: newClientSlots(maxDaemonHandshakesPerClient)}
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
	compatibilityValue, normalizedRelease := version.Evaluate(hello.GetReleaseVersion(), policy.MinimumDaemonVersion)
	if normalizedRelease == "" {
		normalizedRelease = hello.GetReleaseVersion()
	}
	if compatibilityValue != version.StatusCompatible {
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
	if !relay.Valid(hello.Lane) || len(hello.SessionId) != 64 {
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
		// Control frames are acknowledgements and tunnel closes: at most one
		// close per admitted tunnel, plus a few pongs.
		control: make(chan *gatewayv1.DaemonLinkFrame, 2*relay.TunnelLimit(hello.Lane)+16),
		quota:   make(chan *gatewayv1.DaemonLinkFrame, 16), done: make(chan struct{}), tunnels: map[uint64]*tunnel{},
		capabilities: map[string]bool{},
	}
	for _, capability := range hello.GetCapabilities() {
		link.capabilities[capability] = true
	}
	link.outbound = relay.NewQueue(link.budget)
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
	if link.lane == relay.Control {
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
				if link.hasTunnel(f.StreamId) {
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
	if link.lane == relay.Control && h.quota != nil && link.capabilities[providerQuotaCapability] {
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
	_ = link.sendControlFrame(ack)

	recvErr := make(chan error, 1)
	go func() {
		for {
			frame, err := stream.Recv()
			if err != nil {
				recvErr <- err
				return
			}
			if len(frame.GetPayload()) > relay.ChunkBytes || proto.Size(frame) > 2*relay.ChunkBytes {
				recvErr <- status.Error(codes.ResourceExhausted, "daemon link frame exceeds 64 KiB")
				return
			}
			link.markSeen(time.Now())
			switch frame.GetKind() {
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HEARTBEAT:
				if proto.Size(frame) > maxDaemonPresenceBytes {
					recvErr <- status.Error(codes.ResourceExhausted, "daemon presence exceeds 64 KiB")
					return
				}
				if link.lane == relay.Control {
					routes, _ := json.Marshal(frame.GetDirectCandidates())
					remoteDesktop, _ := json.Marshal(frame.GetRemoteDesktop())
					currentPolicy, policyErr := compatibilityPolicy(h.config)
					value, release := version.Evaluate(frame.GetReleaseVersion(), currentPolicy.MinimumDaemonVersion)
					if policyErr != nil || value != version.StatusCompatible {
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
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPENED,
				gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_DATA,
				gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_WINDOW,
				gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE:
				link.lastResponse.Store(time.Now().UnixNano())
				link.deliver(frame)
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
func (h *Hub) relayBudget(account int64, lane relay.Lane) *relay.Budget {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.laneMemory[lane] == nil {
		h.laneMemory[lane] = relay.NewBudget(256<<20, nil)
	}
	budgets := h.accountMemory[account]
	if budgets[lane] == nil {
		budgets[lane] = relay.NewBudget(128<<20, h.laneMemory[lane])
		h.accountMemory[account] = budgets
	}
	return relay.NewBudget(relay.BufferedBytes, budgets[lane])
}

func (h *Hub) register(link *daemonLink) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[link.id]
	if link.lane == relay.Control {
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
		lanes = map[relay.Lane]*daemonLink{}
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
	for _, lane := range relay.Lanes {
		// Calls are tunnels: each carries every call of one client connection.
		value := &gatewayv1.RelayLaneStatus{Lane: lane, CallLimit: uint32(relay.TunnelLimit(lane))}
		if link := h.relayLinks[id][lane]; link != nil {
			value.Connected = link.isAlive(time.Now())
			link.mu.RLock()
			value.ActiveCalls = uint32(len(link.tunnels))
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

// openTunnel admits a tunnel to daemonID on lane and asks the daemon to
// accept it. Each daemon lane admits at most relay.TunnelLimit tunnels.
func (h *Hub) openTunnel(daemonID string, lane relay.Lane) (*tunnel, error) {
	h.mu.RLock()
	link := h.relayLinks[daemonID][lane]
	h.mu.RUnlock()
	if link == nil || !link.isAlive(time.Now()) {
		return nil, status.Errorf(codes.Unavailable, "daemon %s relay channel is unavailable", strings.ToLower(strings.TrimPrefix(lane.String(), "RELAY_LANE_")))
	}
	id := h.nextID.Add(1)
	if id == 0 {
		id = h.nextID.Add(1)
	}
	opened := newTunnel(link, id)
	link.mu.Lock()
	select {
	case <-link.done:
		link.mu.Unlock()
		return nil, status.Error(codes.Unavailable, "daemon disconnected")
	default:
	}
	if len(link.tunnels) >= relay.TunnelLimit(lane) {
		link.rejected.Add(1)
		link.mu.Unlock()
		return nil, status.Error(codes.ResourceExhausted, "daemon relay tunnel limit is exhausted")
	}
	link.tunnels[id] = opened
	link.mu.Unlock()
	if err := link.outbound.Add(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPEN, StreamId: id, DaemonId: daemonID, Lane: lane}); err != nil {
		opened.close(status.New(codes.ResourceExhausted, "daemon relay channel is congested"), false)
		return nil, status.Error(codes.ResourceExhausted, "daemon relay channel is congested")
	}
	return opened, nil
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

func (l *daemonLink) hasTunnel(id uint64) bool {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return l.tunnels[id] != nil
}

// deliver hands a daemon frame to its tunnel without blocking the link
// reader. A tunnel whose client stopped reading fills its bounded queue and
// is closed; the link and its other tunnels continue.
func (l *daemonLink) deliver(frame *gatewayv1.DaemonLinkFrame) {
	l.mu.RLock()
	target := l.tunnels[frame.GetStreamId()]
	delivered := target != nil && target.push(frame)
	l.mu.RUnlock()
	if target != nil && !delivered {
		target.close(status.New(codes.ResourceExhausted, "relay tunnel client is not consuming data"), true)
	}
}

func (l *daemonLink) close() {
	l.closeOnce.Do(func() {
		close(l.done)
		if l.outbound != nil {
			l.outbound.Close()
		}
		l.mu.Lock()
		tunnels := make([]*tunnel, 0, len(l.tunnels))
		for _, value := range l.tunnels {
			tunnels = append(tunnels, value)
		}
		l.mu.Unlock()
		for _, value := range tunnels {
			value.close(status.New(codes.Unavailable, "daemon disconnected"), false)
		}
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
