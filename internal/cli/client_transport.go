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
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/types/known/emptypb"
)

type gatewayTransport struct {
	url     string
	session clientSession
	conn    *grpc.ClientConn
	client  gatewayv1.GatewayServiceClient
}

type dieterTransport struct {
	conn     *grpc.ClientConn
	client   dieterv1.DieterServiceClient
	route    string
	daemonID string
	relay    bool
}

func (value *dieterTransport) context(ctx context.Context) context.Context {
	if value != nil && value.relay {
		return metadata.AppendToOutgoingContext(ctx, "x-dieter-daemon-id", value.daemonID)
	}
	return ctx
}

type bearerCredential struct {
	token    string
	secure   bool
	metadata map[string]string
}

func (credential bearerCredential) GetRequestMetadata(context.Context, ...string) (map[string]string, error) {
	result := make(map[string]string, len(credential.metadata)+1)
	for key, value := range credential.metadata {
		result[key] = value
	}
	if strings.TrimSpace(credential.token) != "" {
		result["authorization"] = "Bearer " + credential.token
	}
	return result, nil
}

func (credential bearerCredential) RequireTransportSecurity() bool { return credential.secure }

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

func (c *CLI) gatewayOrigin() (string, error) {
	if value := strings.TrimSpace(c.GatewayURL); value != "" {
		return normalizeGatewayURL(value)
	}
	if value := strings.TrimSpace(os.Getenv("DIETER_GATEWAY")); value != "" {
		return normalizeGatewayURL(value)
	}
	configuration, err := loadClientConfig(c.Store.Root)
	if err != nil {
		return "", err
	}
	if value := strings.TrimSpace(configuration.DefaultGateway); value != "" {
		return normalizeGatewayURL(value)
	}
	if identity, identityErr := dieterdaemon.LoadIdentity(c.Store.Root); identityErr == nil && strings.TrimSpace(identity.GatewayURL) != "" {
		return normalizeGatewayURL(identity.GatewayURL)
	}
	return normalizeGatewayURL("https://board.dbpprt.com")
}

func (c *CLI) dialGateway(ctx context.Context) (*gatewayTransport, error) {
	if c.gateway != nil {
		return c.gateway, nil
	}
	connectCtx, cancel := context.WithTimeout(ctx, c.connectionTimeout())
	defer cancel()
	ctx = connectCtx
	origin, err := c.gatewayOrigin()
	if err != nil {
		return nil, err
	}
	configuration, err := loadClientConfig(c.Store.Root)
	if err != nil {
		return nil, err
	}
	session := configuration.Sessions[origin]
	if !session.valid(time.Now()) {
		return nil, fmt.Errorf("not signed in to %s; run dieter auth login --gateway %s", origin, origin)
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
		grpc.WithPerRPCCredentials(bearerCredential{token: session.AccessToken, secure: secure}),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(16<<20), grpc.MaxCallSendMsgSize(16<<20)),
	)
	if err != nil {
		return nil, err
	}
	result := &gatewayTransport{url: origin, session: session, conn: connection, client: gatewayv1.NewGatewayServiceClient(connection)}
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
		result := &dieterTransport{conn: connection, client: dieterv1.NewDieterServiceClient(connection), route: "local"}
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
		for _, candidate := range candidates {
			address := net.JoinHostPort(candidate.GetHost(), strconv.Itoa(int(candidate.GetPort())))
			probeCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
			connection, dialErr := dieterdaemon.DialDirect(probeCtx, address, machine.GetId(), route.GetDaemonCaPem(), access.GetAccessToken())
			if dialErr == nil {
				client := dieterv1.NewDieterServiceClient(connection)
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
	if !route.GetRelayAvailable() {
		return nil, fmt.Errorf("Dieter machine %s has no reachable direct route and its relay is unavailable", machine.GetName())
	}
	result := &dieterTransport{
		conn: gateway.conn, client: dieterv1.NewDieterServiceClient(gateway.conn),
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
	return transport.client, transport.context(ctx), nil
}
