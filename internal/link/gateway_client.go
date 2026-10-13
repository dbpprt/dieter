package link

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/url"
	"sync"
	"sync/atomic"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/security/linkauth"
	"github.com/dbpprt/dieter/internal/security/trust"
	"github.com/dbpprt/dieter/internal/transport/relay"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/proto"
)

type GatewayClient struct {
	ControlWebRTC bool
	Identity      *Identity
	// TunnelTarget is the daemon's loopback TLS endpoint (a DirectRoute) that
	// relay tunnels connect to; empty refuses tunnels.
	TunnelTarget          string
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

	budgetMu    sync.Mutex
	laneBudgets [4]*relay.Budget
	// activeAt is when any lane last carried tunnel traffic. Clients reach
	// the daemon through command-lane tunnels, while presence follows the
	// control lane's heartbeat, so every lane's traffic keeps it active.
	activeAt         atomic.Int64
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
	result := make(chan error, len(relay.Lanes))
	for _, lane := range relay.Lanes {
		go func() {
			if lane != relay.Control {
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
	for range relay.Lanes {
		if err := <-result; err != nil && first == nil {
			first = err
			cancel()
		}
	}
	return first
}

func (c *GatewayClient) runLane(ctx context.Context, lane relay.Lane, sessionID string) error {
	timing := c.timing()
	backoff := timing.ReconnectInitialBackoff
	for ctx.Err() == nil {
		if lane == relay.Control {
			c.report(GatewayConnecting, nil)
		}
		connectedFor, err := c.runLaneOnce(ctx, lane, sessionID)
		if ctx.Err() != nil {
			return nil
		}
		var updateRequired *UpdateRequiredError
		if errors.As(err, &updateRequired) && lane == relay.Control {
			if c.OnUpdateRequired != nil {
				if e := c.OnUpdateRequired(updateRequired.Policy); e != nil {
					updateRequired.Cause = e
				}
			}
			c.report(GatewayIncompatible, updateRequired)
			return updateRequired
		}
		delay, next := gatewayReconnectBackoffWithin(backoff, connectedFor, timing.ReconnectInitialBackoff, timing.ReconnectMaximumBackoff, timing.ReconnectStableAfter)
		if lane == relay.Control {
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

func (c *GatewayClient) relayBudget(lane relay.Lane) *relay.Budget {
	c.budgetMu.Lock()
	defer c.budgetMu.Unlock()
	if c.laneBudgets[lane] == nil {
		c.laneBudgets[lane] = relay.NewBudget(relay.BufferedBytes, nil)
	}
	return c.laneBudgets[lane]
}

func (c *GatewayClient) runOnce(ctx context.Context) (time.Duration, error) {
	session := make([]byte, 32)
	if _, err := rand.Read(session); err != nil {
		return 0, err
	}
	return c.runLaneOnce(ctx, relay.Control, fmt.Sprintf("%x", session))
}

func (c *GatewayClient) runLaneOnce(ctx context.Context, lane relay.Lane, sessionID string) (time.Duration, error) {
	timing := c.timing()
	connection, err := DialGateway(ctx, c.Identity, true)
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
	if policy := first.GetCompatibilityPolicy(); lane == relay.Control && policy != nil && c.OnCompatibilityPolicy != nil {
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
	if lane == relay.Control {
		if c.controlReady != nil {
			c.controlReadyOnce.Do(func() { close(c.controlReady) })
		}
		c.report(GatewayConnected, nil)
	}
	providerQuotaKey := append([]byte(nil), first.GetProviderAccountCorrelationKey()...)
	providerQuotasNegotiated := lane == relay.Control && c.ProviderQuotas != nil && supportsGatewayCapability(first, gatewayProviderQuotaCapability) && len(providerQuotaKey) == 32
	resetSource, resetSourceAvailable := c.ProviderQuotas.(ProviderQuotaResetSource)
	providerResetNegotiated := providerQuotasNegotiated && resetSourceAvailable && supportsGatewayCapability(first, gatewayProviderResetCapability)
	if lane == relay.Control && c.OnAcknowledged != nil {
		c.OnAcknowledged(connectedAt)
	}
	finish := func(err error) (time.Duration, error) { return time.Since(connectedAt), err }
	// Tunnels belong to this link: a gateway disconnect closes their sockets
	// immediately, while agents and RPCs inside the daemon keep running.
	responseQueue := relay.NewQueue(c.relayBudget(lane))
	defer responseQueue.Close()
	tunnels := newLinkTunnels()
	defer tunnels.close()
	controlSend := make(chan *gatewayv1.DaemonLinkFrame, 8)
	quotaSend := make(chan *gatewayv1.DaemonLinkFrame, 16)
	var relayActive atomic.Bool
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
			watchdog := time.AfterFunc(relay.WriteTimeout, cancelLink)
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
	for {
		select {
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
			active := relayActive.Swap(false) || time.Since(time.Unix(0, c.activeAt.Load())) < heartbeatInterval
			heartbeatInterval = nextGatewayHeartbeatIntervalWithin(heartbeatInterval, active, timing.HeartbeatActiveInterval, timing.HeartbeatIdleMaxInterval)
			heartbeat.Reset(heartbeatInterval)
		case frame := <-recv:
			if len(frame.Payload) > relay.ChunkBytes || proto.Size(frame) > 2*relay.ChunkBytes {
				return finish(errors.New("gateway relay fragment exceeds its wire limit"))
			}
			// A heartbeat acknowledgement proves liveness but is not relay
			// activity. Counting it here would pin an otherwise idle tunnel to
			// the five-second active heartbeat forever.
			if gatewayFrameMarksRelayActivity(frame) {
				relayActive.Store(true)
				c.activeAt.Store(time.Now().UnixNano())
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
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPEN:
				if err := c.openTunnel(linkCtx, lane, frame, tunnels, responseQueue); err != nil {
					return finish(err)
				}
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_DATA:
				// Frames of a tunnel that already ended are dropped: its CLOSE
				// may cross them on the wire.
				if t := tunnels.get(frame.GetStreamId()); t != nil {
					t.deliver(frame.GetPayload())
				}
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_WINDOW:
				if t := tunnels.get(frame.GetStreamId()); t != nil {
					t.grant(frame.GetCredit())
				}
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE:
				if t := tunnels.get(frame.GetStreamId()); t != nil {
					t.Close()
				}
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PING:
				if !tryEnqueueControl(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG, DaemonId: c.Identity.ID, RequestId: frame.GetRequestId()}) {
					return finish(errors.New("gateway relay control queue is stalled"))
				}
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG:
				if matchesGatewayHeartbeatAck(frame, c.Identity.ID, outstandingHeartbeat) {
					outstandingHeartbeat = ""
					acknowledgedAt := time.Now()
					if lane == relay.Control && c.OnAcknowledged != nil {
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

// openTunnel admits a client tunnel on this lane: it dials the daemon's own
// TLS endpoint and splices bytes with end-to-end credits. Every frame of a
// tunnel shares its ordered slot in the link's fair queue, so the gateway sees
// OPENED before any byte and every byte before CLOSE, and the receive loop
// never waits for the dial.
func (c *GatewayClient) openTunnel(ctx context.Context, lane relay.Lane, frame *gatewayv1.DaemonLinkFrame, tunnels *linkTunnels, queue *relay.Queue) error {
	id := frame.GetStreamId()
	closeFrame := func(code codes.Code, message string) *gatewayv1.DaemonLinkFrame {
		return &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE, StreamId: id, StatusCode: int32(code), StatusMessage: message}
	}
	if id == 0 {
		return errors.New("gateway opened a tunnel without an ID")
	}
	if frame.GetDaemonId() != c.Identity.ID || frame.GetLane() != lane {
		return queue.Add(closeFrame(codes.InvalidArgument, "tunnel target is invalid"))
	}
	admitted, duplicate := tunnels.reserve(id, relay.TunnelLimit(lane))
	if duplicate {
		return errors.New("gateway reused an active tunnel ID")
	}
	if !admitted {
		return queue.Add(closeFrame(codes.ResourceExhausted, "daemon tunnel capacity is exhausted"))
	}
	go func() {
		var socket net.Conn
		err := errors.New("daemon endpoint is not configured")
		if c.TunnelTarget != "" {
			dialCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
			var dialer net.Dialer
			socket, err = dialer.DialContext(dialCtx, "tcp", c.TunnelTarget)
			cancel()
		}
		if err != nil {
			tunnels.release(id)
			_ = queue.Add(closeFrame(codes.Unavailable, "daemon endpoint is unavailable"))
			return
		}
		send := func(frame tunnelFrame) error {
			switch frame.kind {
			case tunnelData:
				return queue.Add(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_DATA, StreamId: id, Payload: frame.data})
			case tunnelWindow:
				return queue.Add(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_WINDOW, StreamId: id, Credit: frame.credit})
			default:
				return queue.Add(closeFrame(frame.code, frame.message))
			}
		}
		reset := func(code codes.Code, message string) {
			queue.Cancel(id)
			_ = queue.Add(closeFrame(code, message))
		}
		t := newTunnel(socket, send, reset, func() { tunnels.release(id) })
		if !tunnels.activate(id, t) {
			_ = socket.Close()
			return
		}
		if err := queue.Add(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPENED, StreamId: id}); err != nil {
			t.Close()
			return
		}
		t.start()
	}()
	return nil
}

// DialGateway connects to the enrolled gateway, presenting the daemon
// certificate when withCertificate is set.
func DialGateway(ctx context.Context, identity *Identity, withCertificate bool) (*grpc.ClientConn, error) {
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
	connection, err := DialGateway(ctx, identity, false)
	if err != nil {
		return nil, err
	}
	defer connection.Close()
	public, _ := identity.PublicKeyDER()
	return gatewayv1.NewGatewayServiceClient(connection).BeginDaemonEnrollment(ctx, &gatewayv1.BeginDaemonEnrollmentRequest{Name: identity.Name, PublicKey: public})
}

func CompleteEnrollment(ctx context.Context, identity *Identity, enrollmentID, secret string) (*gatewayv1.DaemonCredential, error) {
	connection, err := DialGateway(ctx, identity, false)
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
	connection, err := DialGateway(ctx, identity, false)
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
