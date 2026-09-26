package cli

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	dieterdaemon "github.com/dbpprt/dieter/internal/daemon"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/linkauth"
	"github.com/dbpprt/dieter/internal/trust"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/types/known/emptypb"
)

type gatewayTransport struct {
	url    string
	conn   *grpc.ClientConn
	client gatewayv1.GatewayServiceClient
}

type dieterTransport struct {
	conn     *grpc.ClientConn
	client   dieterv1.DieterServiceClient
	route    string
	daemonID string
	relay    bool
}

type dieterMetadataConn struct {
	grpc.ClientConnInterface
	daemonID string
}

func (c dieterMetadataConn) context(ctx context.Context) context.Context {
	ctx = metadata.AppendToOutgoingContext(ctx, "x-dieter-client-version", Version)
	if c.daemonID != "" {
		ctx = metadata.AppendToOutgoingContext(ctx, "x-dieter-daemon-id", c.daemonID)
	}
	return ctx
}

func (c dieterMetadataConn) Invoke(ctx context.Context, method string, in, out any, options ...grpc.CallOption) error {
	return c.ClientConnInterface.Invoke(c.context(ctx), method, in, out, options...)
}

func (c dieterMetadataConn) NewStream(ctx context.Context, description *grpc.StreamDesc, method string, options ...grpc.CallOption) (grpc.ClientStream, error) {
	return c.ClientConnInterface.NewStream(c.context(ctx), description, method, options...)
}

func (value *dieterTransport) context(ctx context.Context) context.Context {
	return ctx
}

// daemonGatewayCredential gives the CLI the same account authority as its
// installed daemon without creating or persisting a second gateway session.
// A fresh, short-lived proof is generated for every RPC and stream.
type daemonGatewayCredential struct {
	identity *dieterdaemon.Identity
	secure   bool
}

func (credential daemonGatewayCredential) GetRequestMetadata(context.Context, ...string) (map[string]string, error) {
	identity := credential.identity
	if identity == nil || !identity.Enrolled() {
		return nil, errors.New("the local Dieter daemon is not enrolled; run `dieter setup`")
	}
	proof := linkauth.SignPeer(identity.PrivateKey, identity.ID, identity.Issuer(), identity.Generation, time.Now())
	return map[string]string{"authorization": "Bearer " + proof, "x-dieter-client-version": Version}, nil
}

func (credential daemonGatewayCredential) RequireTransportSecurity() bool { return credential.secure }

func (c *CLI) Close() {
	if c.transport != nil && c.transport.conn != nil {
		_ = c.transport.conn.Close()
	}
	if c.gateway != nil && c.gateway.conn != nil && (c.transport == nil || c.transport.conn != c.gateway.conn) {
		_ = c.gateway.conn.Close()
	}
	c.transport, c.gateway = nil, nil
}

func (c *CLI) commandContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), c.connectionTimeout())
}

func (c *CLI) connectionTimeout() time.Duration {
	if c.Timeout > 0 {
		return c.Timeout
	}
	return 15 * time.Second
}

func normalizeGatewayURL(value string) (string, error) {
	return trust.GatewayOrigin(value)
}

func (c *CLI) gatewayIdentity() (*dieterdaemon.Identity, string, error) {
	identity, err := dieterdaemon.LoadIdentity(c.Store.Root)
	if errors.Is(err, os.ErrNotExist) {
		return nil, "", errors.New("the local Dieter daemon is not enrolled; run `dieter setup`")
	}
	if err != nil {
		return nil, "", fmt.Errorf("load local Dieter daemon enrollment: %w", err)
	}
	if !identity.Enrolled() {
		return nil, "", errors.New("the local Dieter daemon is not enrolled; run `dieter setup`")
	}
	origin, err := normalizeGatewayURL(identity.GatewayURL)
	if err != nil {
		return nil, "", fmt.Errorf("load local Dieter daemon gateway: %w", err)
	}
	requested := strings.TrimSpace(c.GatewayURL)
	if requested == "" {
		requested = strings.TrimSpace(os.Getenv("DIETER_GATEWAY"))
	}
	if requested != "" {
		requested, err = normalizeGatewayURL(requested)
		if err != nil {
			return nil, "", err
		}
		if requested != origin {
			return nil, "", fmt.Errorf("gateway %s does not match this daemon's enrollment at %s; enroll the daemon with the intended gateway", requested, origin)
		}
	}
	return identity, origin, nil
}

func (c *CLI) dialGateway(ctx context.Context) (*gatewayTransport, error) {
	if c.gateway != nil {
		return c.gateway, nil
	}
	connectCtx, cancel := context.WithTimeout(ctx, c.connectionTimeout())
	defer cancel()
	ctx = connectCtx
	identity, origin, err := c.gatewayIdentity()
	if err != nil {
		return nil, err
	}
	parsed, err := url.Parse(origin)
	if err != nil || parsed.Host == "" {
		return nil, fmt.Errorf("invalid gateway URL %q", origin)
	}
	secure := parsed.Scheme == "https"
	var transport credentials.TransportCredentials
	if secure {
		transport = credentials.NewTLS(&tls.Config{MinVersion: tls.VersionTLS13, ServerName: parsed.Hostname()})
	} else {
		transport = insecure.NewCredentials()
	}
	connection, err := grpc.NewClient(
		parsed.Host,
		grpc.WithTransportCredentials(transport),
		grpc.WithPerRPCCredentials(daemonGatewayCredential{identity: identity, secure: secure}),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(16<<20), grpc.MaxCallSendMsgSize(16<<20)),
	)
	if err != nil {
		return nil, err
	}
	result := &gatewayTransport{url: origin, conn: connection, client: gatewayv1.NewGatewayServiceClient(connection)}
	compatibilityResult, err := result.client.GetCompatibility(ctx, &gatewayv1.CompatibilityRequest{
		ReleaseVersion: Version, Component: gatewayv1.CompatibilityComponent_COMPATIBILITY_COMPONENT_CLIENT,
	})
	if err != nil {
		_ = connection.Close()
		return nil, fmt.Errorf("check Dieter gateway compatibility: %w", err)
	}
	if compatibilityResult.GetStatus() != gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_COMPATIBLE {
		_ = connection.Close()
		return nil, fmt.Errorf("Dieter update required: installed %q, minimum %s", Version, compatibilityResult.GetMinimumReleaseVersion())
	}
	if _, err := result.client.GetAccount(ctx, &emptypb.Empty{}); err != nil {
		_ = connection.Close()
		return nil, fmt.Errorf("authenticate with Dieter gateway %s: %w", origin, err)
	}
	c.gateway = result
	return result, nil
}

func resolveDaemon(items []*gatewayv1.Daemon, reference string) (*gatewayv1.Daemon, error) {
	reference = strings.TrimSpace(reference)
	if reference == "" {
		return nil, errors.New("--machine is required for a remote command")
	}
	var matches []*gatewayv1.Daemon
	for _, item := range items {
		if item.GetId() == reference || strings.EqualFold(item.GetName(), reference) {
			matches = append(matches, item)
		}
	}
	if len(matches) == 0 {
		return nil, fmt.Errorf("Dieter machine %q was not found", reference)
	}
	if len(matches) > 1 {
		return nil, fmt.Errorf("Dieter machine name %q is ambiguous; use an exact machine ID", reference)
	}
	return matches[0], nil
}

func (c *CLI) dialDieter(ctx context.Context) (*dieterTransport, error) {
	if c.transport != nil {
		return c.transport, nil
	}
	connectCtx, cancelConnection := context.WithTimeout(ctx, c.connectionTimeout())
	defer cancelConnection()
	ctx = connectCtx
	if strings.TrimSpace(c.Machine) == "" {
		statusValue, err := dieterdaemon.LoadRuntimeStatus(c.Store.Root)
		if err != nil {
			if os.IsNotExist(err) {
				return nil, errors.New("the local Dieter daemon is not running; start it with `dieter daemon start`")
			}
			return nil, fmt.Errorf("read local Dieter daemon status: %w", err)
		}
		if !dieterdaemon.RuntimeStatusCurrent(statusValue, time.Now().UTC()) || strings.TrimSpace(statusValue.ListenAddress) == "" {
			return nil, errors.New("the local Dieter daemon is not running; start it with `dieter daemon start`")
		}
		connection, err := grpc.NewClient(
			statusValue.ListenAddress,
			grpc.WithTransportCredentials(insecure.NewCredentials()),
			grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(16<<20), grpc.MaxCallSendMsgSize(16<<20)),
		)
		if err != nil {
			return nil, err
		}
		result := &dieterTransport{conn: connection, client: dieterv1.NewDieterServiceClient(readResumingConn{dieterMetadataConn{ClientConnInterface: connection}}), route: "local"}
		if _, err := result.client.Health(ctx, &emptypb.Empty{}); err != nil {
			_ = connection.Close()
			return nil, fmt.Errorf("connect to local Dieter daemon at %s: %w", statusValue.ListenAddress, err)
		}
		c.transport = result
		return result, nil
	}
	gateway, err := c.dialGateway(ctx)
	if err != nil {
		return nil, err
	}
	directory, err := gateway.client.ListDaemons(ctx, &emptypb.Empty{})
	if err != nil {
		return nil, err
	}
	machine, err := resolveDaemon(directory.GetDaemons(), c.Machine)
	if err != nil {
		return nil, err
	}
	if machine.GetCompatibility() != gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_COMPATIBLE {
		return nil, fmt.Errorf("Dieter daemon update required: installed %q, minimum %s", machine.GetReleaseVersion(), machine.GetMinimumReleaseVersion())
	}
	if !machine.GetOnline() {
		return nil, fmt.Errorf("Dieter machine %s (%s) is offline", machine.GetName(), machine.GetId())
	}
	route, err := gateway.client.ResolveDaemonRoute(ctx, &gatewayv1.DaemonRef{DaemonId: machine.GetId()})
	if err != nil {
		return nil, fmt.Errorf("resolve route to %s: %w", machine.GetName(), err)
	}
	candidates := append([]*gatewayv1.DirectCandidate(nil), route.GetDirectCandidates()...)
	sort.SliceStable(candidates, func(i, j int) bool { return candidates[i].GetPriority() > candidates[j].GetPriority() })
	if len(candidates) > 0 {
		access, accessErr := gateway.client.ExchangeDaemonToken(ctx, &gatewayv1.ExchangeDaemonTokenRequest{DaemonId: machine.GetId()})
		if accessErr != nil {
			return nil, fmt.Errorf("issue direct token for %s: %w", machine.GetName(), accessErr)
		}
		credential := &directCredential{access: access, timeout: c.connectionTimeout(), exchange: func(ctx context.Context) (*gatewayv1.DaemonAccessToken, error) {
			return gateway.client.ExchangeDaemonToken(ctx, &gatewayv1.ExchangeDaemonTokenRequest{DaemonId: machine.GetId()})
		}}
		for _, candidate := range candidates {
			address := net.JoinHostPort(candidate.GetHost(), strconv.Itoa(int(candidate.GetPort())))
			probeCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
			connection, dialErr := dieterdaemon.DialDirectWithCredentials(probeCtx, address, machine.GetId(), route.GetDaemonCaPem(), credential)
			if dialErr == nil {
				client := dieterv1.NewDieterServiceClient(readResumingConn{dieterMetadataConn{ClientConnInterface: connection}})
				_, dialErr = client.Health(probeCtx, &emptypb.Empty{})
				if dialErr == nil {
					cancel()
					result := &dieterTransport{conn: connection, client: client, route: "direct", daemonID: machine.GetId()}
					c.transport = result
					return result, nil
				}
				_ = connection.Close()
			}
			cancel()
		}
	}

	if route.GetControlWebrtc() && route.GetRelayAvailable() {
		// Reserve part of the command deadline for the relay. Unreachable ICE
		// must not consume the entire budget and prevent fallback.
		budget := 12 * time.Second
		if deadline, ok := ctx.Deadline(); ok {
			budget = min(budget, time.Until(deadline)*2/3)
		}
		probe, cancel := context.WithTimeout(ctx, budget)
		connection, err := c.dialControl(probe, gateway, route)
		cancel()
		if err == nil {
			c.transport = connection
			return connection, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
	}
	if !route.GetRelayAvailable() {
		return nil, fmt.Errorf("Dieter machine %s has no reachable direct route and its relay is unavailable", machine.GetName())
	}
	result := &dieterTransport{
		conn: gateway.conn, client: dieterv1.NewDieterServiceClient(readResumingConn{dieterMetadataConn{ClientConnInterface: gateway.conn, daemonID: machine.GetId()}}),
		route: "relay", daemonID: machine.GetId(), relay: true,
	}
	c.transport = result
	return result, nil
}

func (c *CLI) rpc(ctx context.Context) (dieterv1.DieterServiceClient, context.Context, error) {
	transport, err := c.dialDieter(ctx)
	if err != nil {
		return nil, ctx, err
	}
	rpcCtx := transport.context(ctx)
	_, err = transport.client.Health(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return nil, ctx, err
	}
	return transport.client, rpcCtx, nil
}
