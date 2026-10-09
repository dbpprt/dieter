package daemon

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/linkauth"
	"github.com/dbpprt/dieter/internal/relaypolicy"
	"github.com/dbpprt/dieter/internal/rpcraw"
	"github.com/dbpprt/dieter/internal/trust"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

type GatewayClient struct {
	ControlWebRTC         bool
	Identity              *Identity
	LocalTarget           string
	Version               string
	Routes                []*gatewayv1.DirectCandidate
	Log                   *slog.Logger
	OnStatus              func(GatewayEvent)
	OnAcknowledged        func(time.Time)
	RemoteDesktopPresence func() *gatewayv1.RemoteDesktopPresence
	ProviderQuotas        ProviderQuotaSource
	OnCompatibilityPolicy func(*gatewayv1.CompatibilityPolicy) error
	OnUpdateRequired      func(*gatewayv1.CompatibilityPolicy) error
	Timing                GatewayTiming

	replayMu         sync.Mutex
	relayProofs      map[string]int64
	laneBudgets      [4]*relaypolicy.Budget
	controlReady     chan struct{}
	controlReadyOnce sync.Once
}

type UpdateRequiredError struct {
	Installed string
	Minimum   string
	Policy    *gatewayv1.CompatibilityPolicy
	Cause     error
}

func (e *UpdateRequiredError) Error() string {
	message := fmt.Sprintf("daemon update required: installed %q, minimum %s", e.Installed, e.Minimum)
	if e.Cause != nil {
		return message + ": " + e.Cause.Error()
	}
	return message
}

func (e *UpdateRequiredError) Unwrap() error { return e.Cause }

func (c *GatewayClient) remoteDesktopPresence() *gatewayv1.RemoteDesktopPresence {
	if c.RemoteDesktopPresence == nil {
		return nil
	}
	return c.RemoteDesktopPresence()
}

const (
	gatewayHeartbeatActiveInterval  = 5 * time.Second
	gatewayHeartbeatIdleMaxInterval = 20 * time.Second
	gatewayHeartbeatAckTimeout      = 45 * time.Second
	gatewayHandshakeTimeout         = 15 * time.Second
	gatewayReconnectInitialBackoff  = time.Second
	gatewayReconnectMaximumBackoff  = 30 * time.Second
	gatewayReconnectStableAfter     = 30 * time.Second
	gatewayProviderQuotaCapability  = "provider_quota_v1"
	gatewayProviderResetCapability  = "provider_quota_reset_v1"
	maxGatewayRelayProofs           = 16384
	maxGatewayProviderQuotaBytes    = 64 << 10
	maxGatewayProviderQuotaProbes   = 2
	gatewayProviderDiscoveryTimeout = 75 * time.Second
)

// GatewayTiming exposes bounded timing overrides for isolated integration
// tests. Production callers leave it zero-valued and receive the defaults
// above.
type GatewayTiming struct {
	HeartbeatActiveInterval  time.Duration
	HeartbeatIdleMaxInterval time.Duration
	HeartbeatAckTimeout      time.Duration
	HandshakeTimeout         time.Duration
	ReconnectInitialBackoff  time.Duration
	ReconnectMaximumBackoff  time.Duration
	ReconnectStableAfter     time.Duration
}

func (c *GatewayClient) timing() GatewayTiming {
	value := c.Timing
	if value.HeartbeatActiveInterval <= 0 {
		value.HeartbeatActiveInterval = gatewayHeartbeatActiveInterval
	}
	if value.HeartbeatIdleMaxInterval < value.HeartbeatActiveInterval {
		value.HeartbeatIdleMaxInterval = gatewayHeartbeatIdleMaxInterval
	}
	if value.HeartbeatAckTimeout <= value.HeartbeatIdleMaxInterval {
		value.HeartbeatAckTimeout = gatewayHeartbeatAckTimeout
	}
	if value.HandshakeTimeout <= 0 {
		value.HandshakeTimeout = gatewayHandshakeTimeout
	}
	if value.ReconnectInitialBackoff <= 0 {
		value.ReconnectInitialBackoff = gatewayReconnectInitialBackoff
	}
	if value.ReconnectMaximumBackoff < value.ReconnectInitialBackoff {
		value.ReconnectMaximumBackoff = gatewayReconnectMaximumBackoff
	}
	if value.ReconnectStableAfter <= 0 {
		value.ReconnectStableAfter = gatewayReconnectStableAfter
	}
	return value
}

func nextGatewayHeartbeatInterval(current time.Duration, active bool) time.Duration {
	return nextGatewayHeartbeatIntervalWithin(current, active, gatewayHeartbeatActiveInterval, gatewayHeartbeatIdleMaxInterval)
}

func nextGatewayHeartbeatIntervalWithin(current time.Duration, active bool, activeInterval, maximumInterval time.Duration) time.Duration {
	if active || current < activeInterval {
		return activeInterval
	}
	next := current * 2
	if next > maximumInterval {
		return maximumInterval
	}
	return next
}

func gatewayReconnectBackoff(current, connectedFor time.Duration) (time.Duration, time.Duration) {
	return gatewayReconnectBackoffWithin(current, connectedFor, gatewayReconnectInitialBackoff, gatewayReconnectMaximumBackoff, gatewayReconnectStableAfter)
}

func gatewayReconnectBackoffWithin(current, connectedFor, initial, maximum, stableAfter time.Duration) (time.Duration, time.Duration) {
	if current <= 0 || connectedFor >= stableAfter {
		current = initial
	}
	next := current * 2
	if next > maximum {
		next = maximum
	}
	return current, next
}

func supportsGatewayCapability(frame *gatewayv1.DaemonLinkFrame, capability string) bool {
	for _, value := range frame.GetCapabilities() {
		if value == capability {
			return true
		}
	}
	return false
}

func matchesGatewayHeartbeatAck(frame *gatewayv1.DaemonLinkFrame, daemonID, requestID string) bool {
	return requestID != "" &&
		frame.GetKind() == gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG &&
		frame.GetDaemonId() == daemonID && frame.GetRequestId() == requestID
}

func gatewayFrameMarksRelayActivity(frame *gatewayv1.DaemonLinkFrame) bool {
	return frame.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG
}

func (c *GatewayClient) report(state string, err error) {
	if c.OnStatus == nil {
		return
	}
	message := ""
	if err != nil {
		message = err.Error()
	}
	c.OnStatus(GatewayEvent{State: state, Error: message})
}

func (c *GatewayClient) Run(ctx context.Context) error {
	if c.Identity == nil || !c.Identity.Enrolled() {
		return errors.New("daemon is not enrolled")
	}
	if c.Log == nil {
		c.Log = slog.Default()
	}
	sessionBytes := make([]byte, 32)
	if _, err := rand.Read(sessionBytes); err != nil {
		return err
	}
	sessionID := fmt.Sprintf("%x", sessionBytes)
	c.controlReady = make(chan struct{})
	c.controlReadyOnce = sync.Once{}
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	result := make(chan error, len(relaypolicy.Lanes))
	for _, lane := range relaypolicy.Lanes {
		go func() {
			if lane != relaypolicy.Control {
				select {
				case <-runCtx.Done():
					result <- nil
					return
				case <-c.controlReady:
				}
			}
			result <- c.runLane(runCtx, lane, sessionID)
		}()
	}
	var first error
	for range relaypolicy.Lanes {
		if err := <-result; err != nil && first == nil {
			first = err
			cancel()
		}
	}
	return first
}

func (c *GatewayClient) runLane(ctx context.Context, lane relaypolicy.Lane, sessionID string) error {
	timing := c.timing()
	backoff := timing.ReconnectInitialBackoff
	for ctx.Err() == nil {
		if lane == relaypolicy.Control {
			c.report(GatewayConnecting, nil)
		}
		connectedFor, err := c.runLaneOnce(ctx, lane, sessionID)
		if ctx.Err() != nil {
			return nil
		}
		var updateRequired *UpdateRequiredError
		if errors.As(err, &updateRequired) && lane == relaypolicy.Control {
			if c.OnUpdateRequired != nil {
				if e := c.OnUpdateRequired(updateRequired.Policy); e != nil {
					updateRequired.Cause = e
				}
			}
			c.report(GatewayIncompatible, updateRequired)
			return updateRequired
		}
		delay, next := gatewayReconnectBackoffWithin(backoff, connectedFor, timing.ReconnectInitialBackoff, timing.ReconnectMaximumBackoff, timing.ReconnectStableAfter)
		if lane == relaypolicy.Control {
			c.report(GatewayDisconnected, err)
		}
		c.Log.Warn("gateway relay lane disconnected", "lane", lane.String(), "error", err, "retry", delay)
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil
		case <-timer.C:
		}
		backoff = next
	}
	return nil
}

func (c *GatewayClient) relayBudget(lane relaypolicy.Lane) *relaypolicy.Budget {
	c.replayMu.Lock()
	defer c.replayMu.Unlock()
	if c.laneBudgets[lane] == nil {
		c.laneBudgets[lane] = relaypolicy.NewBudget(relaypolicy.BufferedBytes, nil)
	}
	return c.laneBudgets[lane]
}

func (c *GatewayClient) runOnce(ctx context.Context) (time.Duration, error) {
	session := make([]byte, 32)
	if _, err := rand.Read(session); err != nil {
		return 0, err
	}
	return c.runLaneOnce(ctx, relaypolicy.Control, fmt.Sprintf("%x", session))
}

func (c *GatewayClient) runLaneOnce(ctx context.Context, lane relaypolicy.Lane, sessionID string) (time.Duration, error) {
	timing := c.timing()
	connection, err := dialGateway(ctx, c.Identity, true)
	if err != nil {
		return 0, err
	}
	defer connection.Close()
	linkCtx, cancelLink := context.WithCancel(ctx)
	defer cancelLink()
	handshakeExpired := atomic.Bool{}
	handshakeTimer := time.AfterFunc(timing.HandshakeTimeout, func() {
		handshakeExpired.Store(true)
		cancelLink()
	})
	defer handshakeTimer.Stop()
	handshakeFailure := func(err error) error {
		if handshakeExpired.Load() && ctx.Err() == nil {
			return fmt.Errorf("gateway handshake timed out after %s", timing.HandshakeTimeout)
		}
		return err
	}
	stream, err := gatewayv1.NewDaemonLinkServiceClient(connection).Connect(linkCtx)
	if err != nil {
		return 0, handshakeFailure(err)
	}
	if err := stream.Send(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO, DaemonId: c.Identity.ID, ReleaseVersion: c.Version, Generation: c.Identity.Generation, Lane: lane, SessionId: sessionID, Capabilities: c.controlCapabilities(), DirectCandidates: c.Routes, RemoteDesktop: c.remoteDesktopPresence()}); err != nil {
		return 0, handshakeFailure(err)
	}
	challenge, err := stream.Recv()
	if err != nil {
		return 0, handshakeFailure(err)
	}
	if challenge.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PING || challenge.GetDaemonId() != c.Identity.ID || len(challenge.GetPayload()) != 32 {
		return 0, errors.New("gateway did not provide a valid daemon challenge")
	}
	proof := linkauth.Sign(c.Identity.PrivateKey, c.Identity.Issuer(), c.Identity.ID, challenge.GetPayload())
	if err := stream.Send(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG, DaemonId: c.Identity.ID, RequestId: challenge.GetRequestId(), Payload: proof}); err != nil {
		return 0, handshakeFailure(err)
	}
	first, err := stream.Recv()
	if err != nil {
		return 0, handshakeFailure(err)
	}
	if first.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO_ACK || first.GetDaemonId() != c.Identity.ID || first.GetGeneration() != c.Identity.Generation {
		return 0, errors.New("gateway rejected the daemon hello")
	}
	if policy := first.GetCompatibilityPolicy(); lane == relaypolicy.Control && policy != nil && c.OnCompatibilityPolicy != nil {
		if err := c.OnCompatibilityPolicy(policy); err != nil {
			return 0, fmt.Errorf("persist gateway compatibility policy: %w", err)
		}
	}
	if first.GetCompatibility() != gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_COMPATIBLE {
		minimum := first.GetCompatibilityPolicy().GetMinimumDaemonVersion()
		if minimum == "" {
			minimum = "unknown"
		}
		return 0, &UpdateRequiredError{Installed: c.Version, Minimum: minimum, Policy: first.GetCompatibilityPolicy()}
	}
	if first.GetLane() != lane || first.GetSessionId() != sessionID {
		return 0, errors.New("gateway did not acknowledge the relay lane and process session")
	}
	handshakeTimer.Stop()
	connectedAt := time.Now()
	if lane == relaypolicy.Control {
		if c.controlReady != nil {
			c.controlReadyOnce.Do(func() { close(c.controlReady) })
		}
		c.report(GatewayConnected, nil)
	}
	providerQuotaKey := append([]byte(nil), first.GetProviderAccountCorrelationKey()...)
	providerQuotasNegotiated := lane == relaypolicy.Control && c.ProviderQuotas != nil && supportsGatewayCapability(first, gatewayProviderQuotaCapability) && len(providerQuotaKey) == 32
	resetSource, resetSourceAvailable := c.ProviderQuotas.(ProviderQuotaResetSource)
	providerResetNegotiated := providerQuotasNegotiated && resetSourceAvailable && supportsGatewayCapability(first, gatewayProviderResetCapability)
	if lane == relaypolicy.Control && c.OnAcknowledged != nil {
		c.OnAcknowledged(connectedAt)
	}
	finish := func(err error) (time.Duration, error) { return time.Since(connectedAt), err }
	local, err := grpc.NewClient(c.LocalTarget, grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithDefaultCallOptions(grpc.ForceCodec(rpcraw.Codec{}), grpc.MaxCallRecvMsgSize(16<<20), grpc.MaxCallSendMsgSize(16<<20)))
	if err != nil {
		return finish(err)
	}
	defer local.Close()
	// Scope every local relayed RPC to this specific tunnel generation. A
	// gateway disconnect previously returned from runOnce while its local
	// StartRemoteDesktop stream stayed alive under the daemon-wide context,
	// leaving capture reconciliation to the much slower session lease. Canceling
	// the link scope tears all relays down immediately; a reconnected tunnel
	// creates fresh streams explicitly.
	responseQueue := relaypolicy.NewQueue(c.relayBudget(lane))
	defer responseQueue.Close()
	assembler := relaypolicy.NewAssembler(c.relayBudget(lane), relaypolicy.Limit(lane))
	defer assembler.Close()
	controlSend := make(chan *gatewayv1.DaemonLinkFrame, 2*relaypolicy.Limit(lane)+4)
	quotaSend := make(chan *gatewayv1.DaemonLinkFrame, 16)
	var relayActive atomic.Bool
	enqueue := func(callCtx context.Context, frame *gatewayv1.DaemonLinkFrame, _ bool) bool {
		relayActive.Store(true)
		if callCtx.Err() != nil || linkCtx.Err() != nil {
			return false
		}
		if err := responseQueue.AddWait(callCtx, frame); err != nil {
			responseQueue.Cancel(frame.StreamId)
			select {
			case controlSend <- relayError(frame.StreamId, codes.ResourceExhausted, "relay response consumer is stalled"):
			default:
				cancelLink()
			}
			return false
		}
		return true
	}
	tryEnqueueControl := func(frame *gatewayv1.DaemonLinkFrame) bool {
		select {
		case <-linkCtx.Done():
			return false
		case controlSend <- frame:
			return true
		default:
			return false
		}
	}
	enqueueQuota := func(frame *gatewayv1.DaemonLinkFrame) bool {
		if frame == nil || proto.Size(frame) > maxGatewayProviderQuotaBytes {
			return false
		}
		select {
		case <-linkCtx.Done():
			return false
		case quotaSend <- frame:
			return true
		default:
			return false
		}
	}
	sendErr := make(chan error, 1)
	go func() {
		send := func(frame *gatewayv1.DaemonLinkFrame, release func()) bool {
			watchdog := time.AfterFunc(relaypolicy.WriteTimeout, cancelLink)
			err := stream.Send(frame)
			watchdog.Stop()
			release()
			if err != nil {
				sendErr <- err
				return false
			}
			return true
		}
		for {
			select {
			case <-linkCtx.Done():
				return
			case f := <-controlSend:
				if !send(f, func() {}) {
					return
				}
				continue
			case f := <-quotaSend:
				if !send(f, func() {}) {
					return
				}
				continue
			default:
			}
			if f, release := responseQueue.Next(); f != nil {
				if !send(f, release) {
					return
				}
				continue
			}
			select {
			case <-linkCtx.Done():
				return
			case <-responseQueue.Wake:
			case f := <-controlSend:
				if !send(f, func() {}) {
					return
				}
			case f := <-quotaSend:
				if !send(f, func() {}) {
					return
				}
			}
		}
	}()
	var calls sync.Map
	activeRelays := make(chan struct{}, relaypolicy.Limit(lane))
	heartbeatInterval := timing.HeartbeatActiveInterval
	heartbeat := time.NewTimer(heartbeatInterval)
	defer heartbeat.Stop()
	var heartbeatSequence uint64
	var outstandingHeartbeat string
	heartbeatWatchdog := time.NewTimer(timing.HeartbeatAckTimeout)
	defer heartbeatWatchdog.Stop()
	recv := make(chan *gatewayv1.DaemonLinkFrame, 8)
	recvErr := make(chan error, 1)
	go func() {
		for {
			frame, err := stream.Recv()
			if err != nil {
				recvErr <- err
				return
			}
			select {
			case recv <- frame:
			case <-linkCtx.Done():
				return
			}
		}
	}()
	if providerQuotasNegotiated {
		go func() {
			discover := func() {
				discoveryCtx, cancel := context.WithTimeout(linkCtx, gatewayProviderDiscoveryTimeout)
				presence, err := c.ProviderQuotas.Discover(discoveryCtx, providerQuotaKey)
				cancel()
				if err != nil || presence == nil || proto.Size(presence) > maxGatewayProviderQuotaBytes {
					c.Log.Warn("provider quota account discovery failed")
					return
				}
				enqueueQuota(&gatewayv1.DaemonLinkFrame{
					Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_ACCOUNTS,
					DaemonId: c.Identity.ID, ProviderAccounts: presence,
				})
			}
			discover()
			ticker := time.NewTicker(time.Minute)
			defer ticker.Stop()
			for {
				select {
				case <-linkCtx.Done():
					return
				case <-ticker.C:
					discover()
				}
			}
		}()
	}
	var quotaCalls sync.Map
	quotaProbes := make(chan struct{}, maxGatewayProviderQuotaProbes)
	assemblyCheck := time.NewTicker(time.Second)
	defer assemblyCheck.Stop()
	for {
		select {
		case <-assemblyCheck.C:
			for _, id := range assembler.Expired(time.Now()) {
				if !tryEnqueueControl(relayError(id, codes.DeadlineExceeded, "relay payload assembly expired")) {
					return finish(errors.New("gateway relay control queue is stalled"))
				}
			}
		case <-ctx.Done():
			return finish(nil)
		case err := <-sendErr:
			return finish(err)
		case err := <-recvErr:
			return finish(err)
		case <-heartbeatWatchdog.C:
			return finish(fmt.Errorf("gateway heartbeat acknowledgement timed out after %s", timing.HeartbeatAckTimeout))
		case <-heartbeat.C:
			frame := &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HEARTBEAT, DaemonId: c.Identity.ID, ReleaseVersion: c.Version, Capabilities: c.controlCapabilities(), DirectCandidates: c.Routes, RemoteDesktop: c.remoteDesktopPresence()}
			if outstandingHeartbeat == "" {
				heartbeatSequence++
				outstandingHeartbeat = fmt.Sprintf("hb_%d", heartbeatSequence)
				frame.RequestId = outstandingHeartbeat
				if !tryEnqueueControl(frame) {
					return finish(errors.New("gateway heartbeat control queue is stalled"))
				}
			}
			heartbeatInterval = nextGatewayHeartbeatIntervalWithin(heartbeatInterval, relayActive.Swap(false), timing.HeartbeatActiveInterval, timing.HeartbeatIdleMaxInterval)
			heartbeat.Reset(heartbeatInterval)
		case frame := <-recv:
			if len(frame.Payload) > relaypolicy.ChunkBytes || proto.Size(frame) > 2*relaypolicy.ChunkBytes {
				return finish(errors.New("gateway relay fragment exceeds its wire limit"))
			}
			// A heartbeat acknowledgement proves liveness but is not relay
			// activity. Counting it here would pin an otherwise idle tunnel to
			// the five-second active heartbeat forever.
			if gatewayFrameMarksRelayActivity(frame) {
				relayActive.Store(true)
			}
			switch frame.GetKind() {
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_QUOTA_REFRESH_REQUEST:
				request := frame.GetProviderQuotaRefreshRequest()
				if !providerQuotasNegotiated || frame.GetDaemonId() != c.Identity.ID || frame.GetRequestId() == "" || request == nil {
					return finish(errors.New("gateway sent an invalid provider quota refresh request"))
				}
				accountIndex := fmt.Sprintf("%d:%s", request.GetProvider(), request.GetAccountKey())
				if _, loaded := quotaCalls.LoadOrStore(accountIndex, struct{}{}); loaded {
					enqueueQuota(&gatewayv1.DaemonLinkFrame{
						Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_QUOTA_REFRESH_RESULT,
						DaemonId: c.Identity.ID, RequestId: frame.GetRequestId(),
						ProviderQuotaRefreshResult: &gatewayv1.ProviderQuotaRefreshResult{ErrorCode: "already_refreshing", RetryAfterSeconds: 60},
					})
					continue
				}
				select {
				case quotaProbes <- struct{}{}:
				default:
					quotaCalls.Delete(accountIndex)
					enqueueQuota(&gatewayv1.DaemonLinkFrame{
						Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_QUOTA_REFRESH_RESULT,
						DaemonId: c.Identity.ID, RequestId: frame.GetRequestId(),
						ProviderQuotaRefreshResult: &gatewayv1.ProviderQuotaRefreshResult{ErrorCode: "probe_capacity", RetryAfterSeconds: 60},
					})
					continue
				}
				go func(requestID, accountIndex string, request *gatewayv1.ProviderQuotaRefreshRequest) {
					defer quotaCalls.Delete(accountIndex)
					defer func() { <-quotaProbes }()
					probeCtx, cancel := context.WithTimeout(linkCtx, 15*time.Second)
					defer cancel()
					result, err := c.ProviderQuotas.Refresh(probeCtx, providerQuotaKey, request)
					if err != nil || result == nil {
						result = &gatewayv1.ProviderQuotaRefreshResult{ErrorCode: "probe_failed"}
					}
					if snapshot := result.GetSnapshot(); snapshot != nil && (snapshot.GetProvider() != request.GetProvider() || snapshot.GetAccountKey() != request.GetAccountKey()) {
						result = &gatewayv1.ProviderQuotaRefreshResult{ErrorCode: "identity_mismatch"}
					}
					response := &gatewayv1.DaemonLinkFrame{
						Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_QUOTA_REFRESH_RESULT,
						DaemonId: c.Identity.ID, RequestId: requestID, ProviderQuotaRefreshResult: result,
					}
					if !enqueueQuota(response) {
						fallback := &gatewayv1.DaemonLinkFrame{
							Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_QUOTA_REFRESH_RESULT,
							DaemonId: c.Identity.ID, RequestId: requestID,
							ProviderQuotaRefreshResult: &gatewayv1.ProviderQuotaRefreshResult{ErrorCode: "result_too_large"},
						}
						enqueueQuota(fallback)
					}
				}(frame.GetRequestId(), accountIndex, proto.Clone(request).(*gatewayv1.ProviderQuotaRefreshRequest))
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_QUOTA_RESET_REQUEST:
				request := frame.GetProviderQuotaResetRequest()
				if !providerResetNegotiated || frame.GetDaemonId() != c.Identity.ID || frame.GetRequestId() == "" || request == nil {
					return finish(errors.New("gateway sent an invalid provider quota reset request"))
				}
				accountIndex := fmt.Sprintf("%d:%s", request.GetProvider(), request.GetAccountKey())
				if _, loaded := quotaCalls.LoadOrStore(accountIndex, struct{}{}); loaded {
					enqueueQuota(&gatewayv1.DaemonLinkFrame{
						Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_QUOTA_RESET_RESULT,
						DaemonId: c.Identity.ID, RequestId: frame.GetRequestId(),
						ProviderQuotaResetResult: &gatewayv1.ProviderQuotaResetResult{ErrorCode: "operation_in_progress", RetryAfterSeconds: 30},
					})
					continue
				}
				select {
				case quotaProbes <- struct{}{}:
				default:
					quotaCalls.Delete(accountIndex)
					enqueueQuota(&gatewayv1.DaemonLinkFrame{
						Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_QUOTA_RESET_RESULT,
						DaemonId: c.Identity.ID, RequestId: frame.GetRequestId(),
						ProviderQuotaResetResult: &gatewayv1.ProviderQuotaResetResult{ErrorCode: "probe_capacity", RetryAfterSeconds: 30},
					})
					continue
				}
				go func(requestID, accountIndex string, request *gatewayv1.ProviderQuotaResetRequest) {
					defer quotaCalls.Delete(accountIndex)
					defer func() { <-quotaProbes }()
					probeCtx, cancel := context.WithTimeout(linkCtx, 15*time.Second)
					defer cancel()
					result, err := resetSource.ConsumeReset(probeCtx, providerQuotaKey, request)
					if err != nil || result == nil {
						result = &gatewayv1.ProviderQuotaResetResult{ErrorCode: "reset_failed"}
					}
					if snapshot := result.GetSnapshot(); snapshot != nil && (snapshot.GetProvider() != request.GetProvider() || snapshot.GetAccountKey() != request.GetAccountKey()) {
						result = &gatewayv1.ProviderQuotaResetResult{ErrorCode: "identity_mismatch"}
					}
					response := &gatewayv1.DaemonLinkFrame{
						Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_QUOTA_RESET_RESULT,
						DaemonId: c.Identity.ID, RequestId: requestID, ProviderQuotaResetResult: result,
					}
					if !enqueueQuota(response) {
						enqueueQuota(&gatewayv1.DaemonLinkFrame{
							Kind:     gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_QUOTA_RESET_RESULT,
							DaemonId: c.Identity.ID, RequestId: requestID,
							ProviderQuotaResetResult: &gatewayv1.ProviderQuotaResetResult{ErrorCode: "result_too_large"},
						})
					}
				}(frame.GetRequestId(), accountIndex, proto.Clone(request).(*gatewayv1.ProviderQuotaResetRequest))
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_OPEN_RPC:
				if frame.PayloadOffset == 0 && relaypolicy.Method(frame.Method) != lane {
					if !tryEnqueueControl(relayError(frame.StreamId, codes.InvalidArgument, "RPC belongs to another relay lane")) {
						return finish(errors.New("gateway relay control queue is stalled"))
					}
					continue
				}
				assembled, release, err := assembler.Accept(frame)
				if err != nil {
					if !tryEnqueueControl(relayError(frame.StreamId, codes.ResourceExhausted, err.Error())) {
						return finish(errors.New("gateway relay control queue is stalled"))
					}
					continue
				}
				if assembled == nil {
					continue
				}
				frame = assembled
				if frame.GetStreamId() == 0 {
					release()
					if !tryEnqueueControl(relayError(frame.GetStreamId(), codes.InvalidArgument, "relay stream ID is required")) {
						return finish(errors.New("gateway relay control queue is stalled"))
					}
					continue
				}
				callCtx, cancel := context.WithCancel(linkCtx)
				if _, loaded := calls.LoadOrStore(frame.GetStreamId(), cancel); loaded {
					cancel()
					release()
					return finish(errors.New("gateway reused an active relay stream ID"))
				}
				select {
				case activeRelays <- struct{}{}:
				default:
					calls.Delete(frame.GetStreamId())
					cancel()
					release()
					if !tryEnqueueControl(relayError(frame.GetStreamId(), codes.ResourceExhausted, "daemon relay concurrency is exhausted")) {
						return finish(errors.New("gateway relay control queue is stalled"))
					}
					continue
				}
				go func(frame *gatewayv1.DaemonLinkFrame) {
					defer cancel()
					defer release()
					defer calls.Delete(frame.GetStreamId())
					defer func() { <-activeRelays }()
					c.relayLocal(callCtx, local, frame, enqueue)
				}(frame)
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_CANCEL_RPC:
				assembler.Cancel(frame.StreamId)
				responseQueue.Cancel(frame.StreamId)
				if value, ok := calls.Load(frame.GetStreamId()); ok {
					value.(context.CancelFunc)()
				}
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PING:
				if !tryEnqueueControl(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG, DaemonId: c.Identity.ID, RequestId: frame.GetRequestId()}) {
					return finish(errors.New("gateway relay control queue is stalled"))
				}
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG:
				if matchesGatewayHeartbeatAck(frame, c.Identity.ID, outstandingHeartbeat) {
					outstandingHeartbeat = ""
					acknowledgedAt := time.Now()
					if lane == relaypolicy.Control && c.OnAcknowledged != nil {
						c.OnAcknowledged(acknowledgedAt)
					}
					if !heartbeatWatchdog.Stop() {
						select {
						case <-heartbeatWatchdog.C:
						default:
						}
					}
					heartbeatWatchdog.Reset(timing.HeartbeatAckTimeout)
				}
			}
		}
	}
}

func (c *GatewayClient) relayLocal(ctx context.Context, local *grpc.ClientConn, frame *gatewayv1.DaemonLinkFrame, send func(context.Context, *gatewayv1.DaemonLinkFrame, bool) bool) {
	started := time.Now()
	priority := relayMethodPriority(frame.GetMethod())
	defer func() {
		c.Log.Debug("relayed Dieter RPC", "method", frame.GetMethod(), "stream_id", frame.GetStreamId(), "priority", priority, "elapsed", time.Since(started))
	}()
	emit := func(value *gatewayv1.DaemonLinkFrame) bool { return send(ctx, value, priority) }
	if frame.GetDaemonId() != c.Identity.ID || frame.GetGeneration() != c.Identity.Generation || !strings.HasPrefix(frame.GetMethod(), "/dieter.v1.DieterService/") {
		emit(relayError(frame.GetStreamId(), codes.Unauthenticated, "relay assertion target is invalid"))
		return
	}
	public, err := trust.PublicKeyFromPEM(c.Identity.GatewaySigningPublicKey)
	var operatorSubject string
	var claims trust.DelegationClaims
	if err == nil {
		claims, err = trust.ParseAndVerifyDelegation(public, frame.GetDelegationAssertion(), c.Identity.Issuer(), c.Identity.ID, frame.GetRequestId(), frame.GetMethod(), frame.GetPayload(), c.Identity.Generation, time.Now().UTC())
		operatorSubject = claims.Subject
	}
	if err != nil {
		emit(relayError(frame.GetStreamId(), codes.Unauthenticated, "relay assertion is invalid"))
		return
	}
	if err := c.consumeRelayProof(claims, time.Now()); err != nil {
		emit(relayStatusError(frame.GetStreamId(), err))
		return
	}
	if deadline := frame.GetDeadlineUnixMillis(); deadline > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithDeadline(ctx, time.UnixMilli(deadline))
		defer cancel()
	}
	clientVersion := frame.GetMetadata()["x-dieter-client-version"]
	ctx = metadata.NewOutgoingContext(ctx, metadata.Pairs(
		"x-dieter-operator-subject", operatorSubject,
		"x-dieter-client-version", clientVersion,
	))
	description := &grpc.StreamDesc{ServerStreams: true, ClientStreams: false}
	call, err := local.NewStream(ctx, description, frame.GetMethod(), grpc.ForceCodec(rpcraw.Codec{}))
	if err != nil {
		emit(relayStatusError(frame.GetStreamId(), err))
		return
	}
	if err := call.SendMsg(&rpcraw.Message{Data: frame.GetPayload()}); err != nil {
		emit(relayStatusError(frame.GetStreamId(), err))
		return
	}
	if err := call.CloseSend(); err != nil {
		emit(relayStatusError(frame.GetStreamId(), err))
		return
	}
	if headers, err := call.Header(); err == nil {
		if !emit(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_HEADER, StreamId: frame.GetStreamId(), Metadata: firstMetadata(headers)}) {
			return
		}
	}
	for {
		var response rpcraw.Message
		err := call.RecvMsg(&response)
		if errors.Is(err, io.EOF) {
			emit(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_END, StreamId: frame.GetStreamId(), StatusCode: int32(codes.OK), Metadata: firstMetadata(call.Trailer())})
			return
		}
		if err != nil {
			result := relayStatusError(frame.GetStreamId(), err)
			trailers := firstMetadata(call.Trailer())
			for key, value := range result.Metadata {
				trailers[key] = value
			}
			result.Metadata = trailers
			emit(result)
			return
		}
		if len(response.Data) > 16<<20 {
			emit(relayError(frame.GetStreamId(), codes.ResourceExhausted, "local response exceeds 16 MiB"))
			return
		}
		if !emit(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_MESSAGE, StreamId: frame.GetStreamId(), Payload: response.Data}) {
			return
		}
	}
}

// Keep consumed proofs across reconnects for their entire accepted lifetime.
// Admission is bounded and fails closed rather than evicting a live proof that
// could then be replayed to dispatch a mutation a second time.
func (c *GatewayClient) consumeRelayProof(claims trust.DelegationClaims, now time.Time) error {
	c.replayMu.Lock()
	defer c.replayMu.Unlock()
	if c.relayProofs == nil {
		c.relayProofs = make(map[string]int64)
	}
	unix := now.Unix()
	for id, expires := range c.relayProofs {
		if expires <= unix-10 {
			delete(c.relayProofs, id)
		}
	}
	if _, used := c.relayProofs[claims.ID]; used {
		return status.Error(codes.Unauthenticated, "relay assertion was already used")
	}
	if len(c.relayProofs) >= maxGatewayRelayProofs {
		return status.Error(codes.ResourceExhausted, "daemon relay assertion capacity is exhausted")
	}
	c.relayProofs[claims.ID] = claims.ExpiresAt
	return nil
}

func relayMethodPriority(method string) bool {
	return relaypolicy.Method(method) != relaypolicy.Subscription
}

func relayStatusError(streamID uint64, err error) *gatewayv1.DaemonLinkFrame {
	value := status.Convert(err)
	frame := relayError(streamID, value.Code(), value.Message())
	if len(value.Proto().Details) > 0 {
		if raw, err := proto.Marshal(value.Proto()); err == nil && len(raw) <= relaypolicy.ChunkBytes/2 {
			frame.Metadata = map[string]string{"grpc-status-details-bin": base64.StdEncoding.EncodeToString(raw)}
		}
	}
	return frame
}

func relayError(streamID uint64, code codes.Code, message string) *gatewayv1.DaemonLinkFrame {
	return &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RPC_ERROR, StreamId: streamID, StatusCode: int32(code), StatusMessage: message}
}

func firstMetadata(values metadata.MD) map[string]string {
	result := map[string]string{}
	for key, items := range values {
		key = strings.ToLower(strings.TrimSpace(key))
		if len(items) > 0 && key != "" && key != "authorization" && key != "cookie" && !strings.HasPrefix(key, "x-dieter-") {
			value := items[0]
			// Protobuf map strings require UTF-8; binary gRPC metadata does not.
			if strings.HasSuffix(key, "-bin") {
				value = base64.StdEncoding.EncodeToString([]byte(value))
			}
			result[key] = value
		}
	}
	return result
}

func dialGateway(ctx context.Context, identity *Identity, withCertificate bool) (*grpc.ClientConn, error) {
	origin, err := trust.GatewayOrigin(identity.GatewayURL)
	if err != nil {
		return nil, err
	}
	parsed, _ := url.Parse(origin)
	var transport credentials.TransportCredentials
	if parsed.Scheme == "http" {
		transport = insecure.NewCredentials()
	} else if parsed.Scheme == "https" {
		tlsConfig := &tls.Config{MinVersion: tls.VersionTLS13, ServerName: parsed.Hostname()}
		if withCertificate {
			certificate, err := tls.X509KeyPair(identity.CertificatePEM, privateKeyPEM(identity.PrivateKey))
			if err != nil {
				return nil, err
			}
			tlsConfig.Certificates = []tls.Certificate{certificate}
		}
		transport = credentials.NewTLS(tlsConfig)
	} else {
		return nil, errors.New("gateway URL must use HTTPS")
	}
	return grpc.NewClient(parsed.Host, grpc.WithTransportCredentials(transport), grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(16<<20), grpc.MaxCallSendMsgSize(16<<20)))
}

func privateKeyPEM(private ed25519.PrivateKey) []byte {
	raw, _ := x509.MarshalPKCS8PrivateKey(private)
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: raw})
}

func BeginEnrollment(ctx context.Context, identity *Identity) (*gatewayv1.DaemonEnrollment, error) {
	connection, err := dialGateway(ctx, identity, false)
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	public, _ := identity.PublicKeyDER()
	return gatewayv1.NewGatewayServiceClient(connection).BeginDaemonEnrollment(ctx, &gatewayv1.BeginDaemonEnrollmentRequest{Name: identity.Name, PublicKey: public})
}

func CompleteEnrollment(ctx context.Context, identity *Identity, enrollmentID, secret string) (*gatewayv1.DaemonCredential, error) {
	connection, err := dialGateway(ctx, identity, false)
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	return gatewayv1.NewGatewayServiceClient(connection).CompleteDaemonEnrollment(ctx, &gatewayv1.CompleteDaemonEnrollmentRequest{EnrollmentId: enrollmentID, EnrollmentSecret: secret})
}

func Unenroll(ctx context.Context, identity *Identity) error {
	if identity == nil || !identity.Enrolled() {
		return errors.New("daemon is not enrolled")
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return err
	}
	connection, err := dialGateway(ctx, identity, false)
	if err != nil {
		return err
	}
	defer connection.Close()
	_, err = gatewayv1.NewGatewayServiceClient(connection).UnenrollDaemon(ctx, &gatewayv1.UnenrollDaemonRequest{
		DaemonId:  identity.ID,
		Nonce:     nonce,
		Signature: linkauth.SignUnenrollment(identity.PrivateKey, identity.Issuer(), identity.ID, nonce),
	})
	return err
}

func (c *GatewayClient) controlCapabilities() []string {
	capabilities := []string{}
	if c.ProviderQuotas != nil {
		capabilities = append(capabilities, gatewayProviderQuotaCapability)
		if _, ok := c.ProviderQuotas.(ProviderQuotaResetSource); ok {
			capabilities = append(capabilities, gatewayProviderResetCapability)
		}
	}
	if c.ControlWebRTC {
		capabilities = append(capabilities, "control_webrtc_v1")
	}
	return capabilities
}
