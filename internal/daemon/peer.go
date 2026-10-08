package daemon

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math/rand/v2"
	"net"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/dbpprt/dieter/internal/buildinfo"
	"github.com/dbpprt/dieter/internal/controlrtc"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/linkauth"
	"github.com/dbpprt/dieter/internal/peerstore"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

// ErrPeerCatchUp reports durable progress with more pages left for a later round.
// It is not a completed exchange or a transport failure.
var ErrPeerCatchUp = errors.New("peer catch-up continues next round")

const peerExchangePages = 64

// peerGatewayConn authenticates autonomous peers with short-lived possession
// proofs. The gateway resolves the account from current enrollment, never input.
type peerGatewayConn struct {
	grpc.ClientConnInterface
	identity *Identity
	target   string
}

func (c peerGatewayConn) auth(ctx context.Context) context.Context {
	values, _ := metadata.FromOutgoingContext(ctx)
	values = values.Copy()
	values.Set("authorization", "Bearer "+linkauth.SignPeer(c.identity.PrivateKey, c.identity.ID, c.identity.Issuer(), c.identity.Generation, time.Now()))
	values.Set("x-dieter-client-version", buildinfo.ReleaseVersion)
	if c.target != "" {
		values.Set("x-dieter-daemon-id", c.target)
	}
	return metadata.NewOutgoingContext(ctx, values)
}
func (c peerGatewayConn) Invoke(ctx context.Context, method string, in, out any, opts ...grpc.CallOption) error {
	return c.ClientConnInterface.Invoke(c.auth(ctx), method, in, out, opts...)
}
func (c peerGatewayConn) NewStream(ctx context.Context, desc *grpc.StreamDesc, method string, opts ...grpc.CallOption) (grpc.ClientStream, error) {
	return c.ClientConnInterface.NewStream(c.auth(ctx), desc, method, opts...)
}

type PeerConnection struct {
	Client      dieterv1.DieterServiceClient
	Route       string
	RTCFallback *PeerRTCFallback
	close       func()
}

// PeerRTCFallback is safe to retain and log. It deliberately excludes the
// underlying error, candidate addresses, SDP, and credentials.
type PeerRTCFallback struct {
	Stage     string
	Reason    string
	ElapsedMS int64
}

func (c *PeerConnection) Close() {
	if c != nil && c.close != nil {
		c.close()
	}
}

// DialPeer reuses enrolled TLS identity and existing controlrtc byte framing.
// Connections are short-lived anti-entropy rounds; bearer renewal is performed
// by the next round, well within the five-minute access-token lifetime.
func DialPeer(ctx context.Context, identity *Identity, gatewayConnection grpc.ClientConnInterface, target string) (*PeerConnection, error) {
	return dialPeer(ctx, identity, gatewayConnection, target, false, false)
}

func dialPeer(ctx context.Context, identity *Identity, gatewayConnection grpc.ClientConnInterface, target string, relayOnly, skipRTC bool) (*PeerConnection, error) {
	gateway := gatewayv1.NewGatewayServiceClient(peerGatewayConn{gatewayConnection, identity, ""})
	route, err := gateway.ResolveDaemonRoute(ctx, &gatewayv1.DaemonRef{DaemonId: target})
	if err != nil {
		return nil, err
	}
	token, err := gateway.ExchangeDaemonToken(ctx, &gatewayv1.ExchangeDaemonTokenRequest{DaemonId: target})
	if err != nil {
		return nil, err
	}
	for i, candidate := range route.GetDirectCandidates() {
		if i >= 4 || relayOnly {
			break
		}
		attempt, cancel := context.WithTimeout(ctx, time.Second)
		connection, e := DialDirect(attempt, net.JoinHostPort(candidate.GetHost(), fmt.Sprint(candidate.GetPort())), target, route.GetDaemonCaPem(), token.GetAccessToken())
		client := dieterv1.NewDieterServiceClient(connection)
		if e == nil {
			_, e = client.GetPeerStoreStatus(attempt, &emptypb.Empty{})
		}
		cancel()
		if e == nil {
			return &PeerConnection{Client: client, Route: "direct-tls", close: func() { _ = connection.Close() }}, nil
		}
		if connection != nil {
			_ = connection.Close()
		}
	}
	relay := dieterv1.NewDieterServiceClient(peerGatewayConn{gatewayConnection, identity, target})
	var fallback *PeerRTCFallback
	if route.GetControlWebrtc() && !skipRTC {
		rtcStarted := time.Now()
		stage := "configuration"
		attempt, cancel := context.WithTimeout(ctx, 15*time.Second)
		configuration, e := gateway.GetRTCConfiguration(attempt, &gatewayv1.DaemonRef{DaemonId: target})
		if e == nil {
			stage = "ice-gathering"
			stream, session, dialErr := controlrtc.DialWithPolicy(attempt, configuration, func(call context.Context, r *dieterv1.StartControlConnectionRequest) (*dieterv1.ControlConnection, error) {
				return relay.StartControlConnection(call, r)
			}, relayOnly)
			if dialErr == nil {
				stage = "data-channel-tls"
				var used atomic.Bool
				connection, tlsErr := DialDirectWithCredentials(attempt, "passthrough:///peer-control", target, route.GetDaemonCaPem(), daemonTokenCredential{token.GetAccessToken()}, grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
					if used.Swap(true) {
						return nil, controlrtc.ErrUnavailable
					}
					return stream, nil
				}))
				if tlsErr == nil {
					client := dieterv1.NewDieterServiceClient(connection)
					stage = "health"
					_, tlsErr = client.GetPeerStoreStatus(attempt, &emptypb.Empty{})
					if tlsErr == nil {
						stage = "status"
						info, infoErr := client.GetControlConnection(attempt, &dieterv1.ControlConnectionRef{SessionId: session.GetSessionId()})
						if infoErr == nil {
							cancel()
							return &PeerConnection{Client: client, Route: "webrtc-" + info.GetMode(), close: func() { _ = connection.Close(); _ = stream.Close() }}, nil
						}
						tlsErr = infoErr
					}
				}
				if connection != nil {
					_ = connection.Close()
				}
				_ = stream.Close()
				e = tlsErr
			} else {
				e = dialErr
			}
		}
		var typed *controlrtc.DialError
		if errors.As(e, &typed) {
			stage = typed.Stage
		}
		fallback = &PeerRTCFallback{Stage: stage, Reason: sanitizedRTCReason(e), ElapsedMS: time.Since(rtcStarted).Milliseconds()}
		cancel()
	}
	if !route.GetRelayAvailable() {
		return nil, fmt.Errorf("peer %s has no available route", target)
	}
	return &PeerConnection{Client: relay, Route: "relay", RTCFallback: fallback, close: func() {}}, nil
}

func sanitizedRTCReason(err error) string {
	if err == nil {
		return "unavailable"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "deadline"
	}
	if errors.Is(err, context.Canceled) {
		return "canceled"
	}
	if code := status.Code(err); code != codes.Unknown {
		return code.String()
	}
	return "unavailable"
}

type peerRTCRetry struct {
	failures int
	retryAt  time.Time
}

const (
	peerRTCInitialCooldown = 2 * time.Minute
	peerRTCMaximumCooldown = 15 * time.Minute
)

func peerRTCCooldown(failures int) time.Duration {
	if failures < 1 {
		return 0
	}
	delay := peerRTCInitialCooldown
	for n := 1; n < failures && delay < peerRTCMaximumCooldown; n++ {
		delay *= 2
	}
	return min(delay, peerRTCMaximumCooldown)
}

// PeerSync runs only from serve. No handler construction starts background work.
// Independent per-peer retries and a bounded worker set isolate stalled peers.
// All actors can write; rounds rotate through account members without a leader.
type PeerSync struct {
	Identity    *Identity
	Store       *store.Store
	Log         *slog.Logger
	Interval    time.Duration
	RelayOnly   bool // Require TURN for isolated qualification; false preserves normal route preference.
	next        int
	syncMu      sync.Mutex
	syncRetry   map[string]peerSyncRetry
	activePeers int
	rtcMu       sync.Mutex
	rtcRetry    map[string]peerRTCRetry
	now         func() time.Time
}

func (p *PeerSync) rtcAttemptAllowed(target string) bool {
	p.rtcMu.Lock()
	defer p.rtcMu.Unlock()
	state, ok := p.rtcRetry[target]
	return !ok || !p.timeNow().Before(state.retryAt)
}

func (p *PeerSync) recordRTCFallback(target string) peerRTCRetry {
	p.rtcMu.Lock()
	defer p.rtcMu.Unlock()
	if p.rtcRetry == nil {
		p.rtcRetry = map[string]peerRTCRetry{}
	}
	state := p.rtcRetry[target]
	state.failures++
	state.retryAt = p.timeNow().Add(peerRTCCooldown(state.failures))
	p.rtcRetry[target] = state
	return state
}

func (p *PeerSync) clearRTCFallback(target string) {
	p.rtcMu.Lock()
	defer p.rtcMu.Unlock()
	delete(p.rtcRetry, target)
}

func (p *PeerSync) timeNow() time.Time {
	if p.now != nil {
		return p.now()
	}
	return time.Now()
}

type peerSyncRetry struct {
	failures int
	retryAt  time.Time
	active   bool
}

const maxConcurrentPeerExchanges = 4

func (p *PeerSync) selectPeers(peers []string, limit int) []string {
	p.syncMu.Lock()
	defer p.syncMu.Unlock()
	if p.syncRetry == nil {
		p.syncRetry = map[string]peerSyncRetry{}
	}
	live := map[string]bool{}
	for _, id := range peers {
		live[id] = true
	}
	for id, state := range p.syncRetry {
		if !live[id] && !state.active {
			delete(p.syncRetry, id)
		}
	}
	var selected []string
	for n := 0; n < len(peers) && len(selected) < limit && p.activePeers < maxConcurrentPeerExchanges; n++ {
		id := peers[p.next%len(peers)]
		p.next++
		state := p.syncRetry[id]
		if state.active || p.timeNow().Before(state.retryAt) {
			continue
		}
		state.active = true
		p.syncRetry[id] = state
		p.activePeers++
		selected = append(selected, id)
	}
	return selected
}
func (p *PeerSync) finishPeer(target string, err error) {
	p.syncMu.Lock()
	defer p.syncMu.Unlock()
	state := p.syncRetry[target]
	state.active = false
	p.activePeers--
	if err == nil {
		state.failures = 0
		state.retryAt = time.Time{}
	} else {
		state.failures++
		delay := 15 * time.Second
		for n := 1; n < state.failures && delay < 2*time.Minute; n++ {
			delay = min(delay*2, 2*time.Minute)
		}
		state.retryAt = p.timeNow().Add(delay)
	}
	p.syncRetry[target] = state
}

func (p *PeerSync) Run(ctx context.Context) {
	interval := p.Interval
	if interval <= 0 {
		interval = 15 * time.Second
	}
	logger := p.Log
	if logger == nil {
		logger = slog.Default()
	}
	delay := interval
	changes := p.Store.PeerChangesAvailable()
	var workers sync.WaitGroup
	defer workers.Wait()
	for ctx.Err() == nil {
		discovery, cancel := context.WithTimeout(ctx, 25*time.Second)
		err := p.round(discovery, ctx, &workers)
		cancel()
		if err != nil && ctx.Err() == nil {
			logger.Warn("peer store discovery pending", "error", err)
			delay = min(max(delay*2, interval), 2*time.Minute)
		} else {
			delay = interval
		}
		timer := time.NewTimer(delay + time.Duration(rand.Int64N(int64(interval/4+1))))
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		case <-changes:
			timer.Stop()
			pause := time.Second
			if err != nil {
				pause = delay
			}
			coalesce := time.NewTimer(pause)
			select {
			case <-ctx.Done():
				coalesce.Stop()
				return
			case <-coalesce.C:
			}
		}
	}
}
func (p *PeerSync) Round(ctx context.Context) error { return p.round(ctx, ctx, nil) }

// Discovery can fail globally; exchange failures back off only their target.
// Serve dispatches without waiting for slow exchanges. Explicit Round waits for
// its admitted peers, preserving callers' durable convergence boundary.
func (p *PeerSync) round(ctx, workerCtx context.Context, workers *sync.WaitGroup) error {
	if err := p.Store.FlushSharedOutbox(); err != nil {
		return err
	}
	current, err := LoadIdentity(p.Store.Root)
	if err != nil || !current.Enrolled() || current.ID != p.Identity.ID || current.GatewayURL != p.Identity.GatewayURL || current.Generation != p.Identity.Generation {
		return fmt.Errorf("peer enrollment changed; restart daemon")
	}

	conn, err := dialGateway(ctx, p.Identity, false)
	if err != nil {
		return err
	}
	defer conn.Close()
	gateway := gatewayv1.NewGatewayServiceClient(peerGatewayConn{conn, p.Identity, ""})
	discovery, cancel := context.WithTimeout(ctx, 10*time.Second)
	account, err := gateway.GetAccount(discovery, &emptypb.Empty{})
	cancel()
	if err != nil {
		return err
	}
	if account.GetGithubId() <= 0 {
		return fmt.Errorf("invalid peer account")
	}
	subject := fmt.Sprintf("github:%d", account.GetGithubId())
	scope := peerstore.Revision([]string{p.Identity.Issuer(), subject})
	binding, err := p.Store.BindPeerAccount(scope, subject, p.Identity.ID, p.Identity.Issuer())
	if err != nil {
		return err
	}
	discovery, cancel = context.WithTimeout(ctx, 10*time.Second)
	directory, err := gateway.ListDaemons(discovery, &emptypb.Empty{})
	cancel()
	if err != nil {
		return err
	}
	peers := []string{}
	online := make(map[string]bool, len(directory.GetDaemons()))
	var lastErr error
	for _, d := range directory.GetDaemons() {
		online[d.GetId()] = d.GetOnline()
		if d.GetId() != p.Identity.ID && d.GetOnline() {
			if d.GetCompatibility() != gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_COMPATIBLE {
				lastErr = fmt.Errorf("machine %s requires update to release %s", d.GetName(), d.GetMinimumReleaseVersion())
				continue
			}
			peers = append(peers, d.GetId())
		}
	}
	if err := p.Store.ObservePeerAvailability(binding, online); err != nil {
		return err
	}
	sort.Strings(peers)
	if len(peers) == 0 {
		if workers != nil {
			return nil
		}
		return lastErr
	}
	limit := 2
	if workers != nil {
		limit = maxConcurrentPeerExchanges
	}
	selected := p.selectPeers(peers, limit)
	results := make(chan error, len(selected))
	for _, target := range selected {
		if workers != nil {
			workers.Add(1)
		}
		go func() {
			if workers != nil {
				defer workers.Done()
			}
			attempt, cancel := context.WithTimeout(workerCtx, 40*time.Second)
			defer cancel()
			// Each exchange owns its connection. A completed discovery closes only its
			// own RPCs, never an independently progressing peer.
			connection, e := dialGateway(attempt, p.Identity, false)
			if e == nil {
				e = p.exchangePeer(attempt, binding, connection, target)
				connection.Close()
			}
			p.finishPeer(target, e)
			if workers == nil {
				results <- e
			} else if e != nil && workerCtx.Err() == nil {
				logger := p.Log
				if logger == nil {
					logger = slog.Default()
				}
				logger.Warn("peer store synchronization pending", "peer", target, "error", e)
			}
		}()
	}
	if workers == nil {
		for range selected {
			if e := <-results; e != nil {
				lastErr = e
			}
		}
	}
	if workers != nil {
		return nil
	}
	return lastErr
}

func (p *PeerSync) exchangePeer(ctx context.Context, binding store.PeerIdentity, conn grpc.ClientConnInterface, target string) error {
	connection, e := dialPeer(ctx, p.Identity, conn, target, p.RelayOnly, !p.RelayOnly && !p.rtcAttemptAllowed(target))
	if e != nil {
		_ = p.Store.RecordPeerSync(binding, store.PeerSyncDiagnostic{PeerID: target, LastAttemptAt: time.Now().UTC().Format(time.RFC3339Nano), Direction: "connect", FailureCode: sanitizedRTCReason(e)})
		return fmt.Errorf("peer %s: %w", target, e)
	}
	defer connection.Close()
	if connection.RTCFallback != nil {
		retry := p.recordRTCFallback(target)
		logger := p.Log
		if logger == nil {
			logger = slog.Default()
		}
		logger.Info("peer WebRTC unavailable; using gateway relay", "peer", target, "stage", connection.RTCFallback.Stage, "reason", connection.RTCFallback.Reason, "elapsed_ms", connection.RTCFallback.ElapsedMS, "retry_in", peerRTCCooldown(retry.failures))
	} else if strings.HasPrefix(connection.Route, "webrtc-") {
		p.clearRTCFallback(target)
	}
	e = p.exchange(ctx, binding, connection.Client, target, connection.Route)
	if e == nil {
		e = p.Store.PeerSynced(binding, target, connection.Route)
	} else if errors.Is(e, ErrPeerCatchUp) {
		e = nil
	}
	return e
}

// Exchange resumes each direction from a durable local transport checkpoint.
// Merge commits before checkpoint advancement; lost replies only repeat joins.
func (p *PeerSync) Exchange(ctx context.Context, binding store.PeerIdentity, client dieterv1.DieterServiceClient) error {
	return p.exchange(ctx, binding, client, "", "")
}

func (p *PeerSync) exchange(ctx context.Context, binding store.PeerIdentity, client dieterv1.DieterServiceClient, target, route string) (resultErr error) {
	diagnostic := store.PeerSyncDiagnostic{PeerID: target, LastAttemptAt: time.Now().UTC().Format(time.RFC3339Nano), Direction: "status", Route: route}
	defer func() {
		if diagnostic.PeerID == "" {
			return
		}
		if errors.Is(resultErr, ErrPeerCatchUp) {
			diagnostic.Direction = "catchup"
		} else if resultErr != nil {
			diagnostic.FailureCode = sanitizedRTCReason(resultErr)
			var record *store.PeerRecordError
			if errors.As(resultErr, &record) {
				diagnostic.RecordKind, diagnostic.RecordID, diagnostic.Field, diagnostic.FailureCode = record.Kind, record.ID, record.Field, record.Code
			}
			for _, detail := range status.Convert(resultErr).Details() {
				if info, ok := detail.(*errdetails.ErrorInfo); ok && info.Domain == "dieter.peer" {
					// Only bounded identifiers/categories from an authenticated peer.
					if peerstore.ValidID(info.Metadata["kind"]) && peerstore.ValidID(info.Metadata["id"]) && peerstore.ValidID(info.Metadata["field"]) && peerstore.ValidID(info.Reason) {
						diagnostic.RecordKind, diagnostic.RecordID, diagnostic.Field, diagnostic.FailureCode = info.Metadata["kind"], info.Metadata["id"], info.Metadata["field"], info.Reason
					}
				}
			}
		} else {
			diagnostic.Direction = "complete"
		}
		if err := p.Store.RecordPeerSync(binding, diagnostic); err != nil && (resultErr == nil || errors.Is(resultErr, ErrPeerCatchUp)) {
			resultErr = err
		}
	}()
	statusInfo, err := client.GetPeerStoreStatus(ctx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	if statusInfo.GetAccount() != binding.Account {
		return fmt.Errorf("peer account mismatch")
	}
	peer := statusInfo.GetActor()
	diagnostic.Actor = peer
	if diagnostic.PeerID == "" {
		diagnostic.PeerID = peer
	}
	diagnostic.Direction = "pull"
	pull, err := p.Store.PeerCheckpoint(binding.Account, peer, "pull")
	if err != nil {
		return err
	}
	diagnostic.Pull = pull
	pullComplete, pushComplete := false, false
	for page := 0; page < peerExchangePages; page++ {
		changes, e := client.GetPeerChanges(ctx, &dieterv1.PeerChangesRequest{Account: binding.Account, Epoch: pull.Epoch, AfterSequence: pull.Sequence})
		if status.Code(e) == codes.Aborted && pull.Epoch != "" {
			pull = store.PeerCheckpoint{}
			continue
		}
		if e != nil {
			return e
		}
		if changes.GetEpoch() == "" || changes.GetAfterSequence() < pull.Sequence || len(changes.GetRecords()) > peerstore.PageSize {
			return fmt.Errorf("invalid peer changes")
		}
		records := make([]peerstore.Record, 0, len(changes.GetRecords()))
		for _, r := range changes.GetRecords() {
			record := peerstore.Record{Kind: r.GetKind(), ID: r.GetId()}
			for _, v := range r.GetVersions() {
				record.Versions = append(record.Versions, peerstore.Version{Clock: v.GetClock(), Value: v.GetValueJson(), Deleted: v.GetDeleted(), Provenance: v.GetProvenanceJson()})
			}
			records = append(records, record)
		}
		if err = p.Store.MergePeerRecords(binding, records); err != nil {
			return err
		}
		if changes.GetMore() && changes.GetAfterSequence() == pull.Sequence {
			return fmt.Errorf("peer made no progress")
		}
		pull = store.PeerCheckpoint{Epoch: changes.GetEpoch(), Sequence: changes.GetAfterSequence()}
		if err = p.Store.SavePeerCheckpoint(binding, peer, "pull", pull); err != nil {
			return err
		}
		diagnostic.Pull = pull
		if !changes.GetMore() {
			pullComplete = true
			break
		}
	}
	diagnostic.Direction = "push"
	push, err := p.Store.PeerCheckpoint(binding.Account, peer, "push")
	if err != nil {
		return err
	}
	// A replaced receiving replica has lost earlier acknowledgements too.
	if push.RemoteEpoch != pull.Epoch {
		push = store.PeerCheckpoint{RemoteEpoch: pull.Epoch}
	}
	diagnostic.Push = push
	for page := 0; page < peerExchangePages; page++ {
		changes, e := p.Store.PeerChanges(binding.Account, push.Epoch, push.Sequence)
		if errors.Is(e, peerstore.ErrConflict) && push.Epoch != "" {
			push = store.PeerCheckpoint{RemoteEpoch: pull.Epoch}
			continue
		}
		if e != nil {
			return e
		}
		request := &dieterv1.MergePeerRecordsRequest{Account: binding.Account}
		for _, r := range changes.Records {
			record := &dieterv1.PeerRecord{Kind: r.Kind, Id: r.ID}
			for _, v := range r.Versions {
				record.Versions = append(record.Versions, &dieterv1.PeerVersion{Clock: v.Clock, ValueJson: v.Value, Deleted: v.Deleted, ProvenanceJson: v.Provenance})
			}
			request.Records = append(request.Records, record)
		}
		if len(request.Records) > 0 {
			if _, err = client.MergePeerRecords(ctx, request); err != nil {
				return err
			}
		}
		push = store.PeerCheckpoint{Epoch: changes.Epoch, Sequence: changes.After, RemoteEpoch: pull.Epoch}
		if err = p.Store.SavePeerCheckpoint(binding, peer, "push", push); err != nil {
			return err
		}
		diagnostic.Push = push
		if !changes.More {
			pushComplete = true
			break
		}
	}
	if !pullComplete || !pushComplete {
		return ErrPeerCatchUp
	}
	return nil
}
