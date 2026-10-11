// Package topology runs isolated in-process gateway and daemon topologies on
// random loopback ports: a gateway with its own state root, enrolled daemons
// serving the Dieter API through reverse tunnels and optional direct TLS
// routes, and signed-in client sessions. Tests use the testing.TB helpers;
// fixture programs use the error-returning constructors.
package topology

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	"github.com/dbpprt/dieter/internal/gateway"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/security/localauth"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/transport/controlrtc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
)

const (
	// Account is the GitHub user a topology approves by default.
	Account int64 = 42
	// ClientVersion is the release tests report for clients and tunnels.
	ClientVersion = "0.4.1-dev"
	// ReadyTimeout bounds how long a started daemon may take to register its
	// relay with the gateway.
	ReadyTimeout = 10 * time.Second
)

// GatewayOptions configures an isolated gateway. Configure runs last and may
// adjust anything, including PublicURL for a proxy in front of Address.
type GatewayOptions struct {
	Root     string
	Address  string
	Accounts []int64
	Issuer   string
	// Login is the GitHub login that approves enrollments; empty is "owner".
	Login      string
	AuthSecret []byte
	SessionTTL time.Duration
	Logger     *slog.Logger
	Configure  func(*gateway.Config)
}

// Gateway is a running in-process gateway.
type Gateway struct {
	Config  gateway.Config
	Store   *gateway.Store
	Server  *gateway.Server
	Address string
	// URL is the public origin daemons and clients use.
	URL string

	listener net.Listener
	login    string
}

// NewGateway starts a gateway in development mode (plaintext, no GitHub).
func NewGateway(options GatewayOptions) (*Gateway, error) {
	if options.Root == "" {
		return nil, errors.New("topology: gateway root is required")
	}
	address := options.Address
	if address == "" {
		address = "127.0.0.1:0"
	}
	accounts := options.Accounts
	if len(accounts) == 0 {
		accounts = []int64{Account}
	}
	secret := options.AuthSecret
	if len(secret) == 0 {
		secret = []byte("0123456789abcdef0123456789abcdef")
	}
	ttl := options.SessionTTL
	if ttl == 0 {
		ttl = time.Hour
	}
	logger := options.Logger
	if logger == nil {
		logger = discard()
	}
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return nil, err
	}
	public, err := url.Parse("http://" + listener.Addr().String())
	if err != nil {
		_ = listener.Close()
		return nil, err
	}
	allowed := make(map[int64]struct{}, len(accounts))
	for _, account := range accounts {
		allowed[account] = struct{}{}
	}
	config := gateway.Config{
		Root: options.Root, Address: listener.Addr().String(), PublicURL: public,
		GitHubClientID: "test", GitHubSecret: "test", AllowedUserIDs: allowed,
		AuthSecret: secret, SessionTTL: ttl, RTCTTL: 5 * time.Minute,
		NativeRedirects: map[string]struct{}{}, GitHubBaseURL: "https://github.invalid",
		GitHubAPIURL: "https://api.github.invalid", DevInsecure: true,
	}
	if options.Issuer != "" {
		if config.IssuerURL, err = url.Parse(options.Issuer); err != nil {
			_ = listener.Close()
			return nil, err
		}
	}
	if options.Configure != nil {
		options.Configure(&config)
	}
	data, err := gateway.OpenStore(config.Root)
	if err != nil {
		_ = listener.Close()
		return nil, err
	}
	server, err := gateway.NewServer(config, data, logger)
	if err != nil {
		_ = data.Close()
		_ = listener.Close()
		return nil, err
	}
	go func() { _ = server.Serve(listener) }()
	login := options.Login
	if login == "" {
		login = "owner"
	}
	return &Gateway{Config: config, Store: data, Server: server, Address: listener.Addr().String(), URL: config.PublicURL.String(), listener: listener, login: login}, nil
}

// Close stops the gateway's listener, gRPC services, and store.
func (g *Gateway) Close() {
	_ = g.listener.Close()
	g.Server.APIGRPC.Stop()
	g.Server.RelayGRPC.Stop()
	_ = g.Store.Close()
}

// Enroll creates a daemon identity in root and enrolls it, approved by
// account, exactly as `dieter daemon enroll` does.
func (g *Gateway) Enroll(ctx context.Context, root, name string, account int64) (*link.Identity, error) {
	identity, err := link.LoadOrCreateEnrollmentIdentity(root, name, g.URL)
	if err != nil {
		return nil, err
	}
	enrollment, err := link.BeginEnrollment(ctx, identity)
	if err != nil {
		return nil, fmt.Errorf("begin enrollment of %s: %w", name, err)
	}
	if err := g.Store.ApproveEnrollment(enrollment.GetEnrollmentId(), enrollment.GetUserCode(), account, g.login); err != nil {
		return nil, fmt.Errorf("approve enrollment of %s: %w", name, err)
	}
	credential, err := link.CompleteEnrollment(ctx, identity, enrollment.GetEnrollmentId(), enrollment.GetEnrollmentSecret())
	if err != nil {
		return nil, fmt.Errorf("complete enrollment of %s: %w", name, err)
	}
	identity.GatewayIssuer = credential.GetGatewayIssuer()
	if err := identity.SaveCredential(credential.GetDaemonId(), credential.GetDaemonName(), credential.GetCertificatePem(), credential.GetDaemonCaPem(), credential.GetGatewaySigningPublicKey(), credential.GetExpiresAt(), credential.GetGeneration()); err != nil {
		return nil, err
	}
	return identity, nil
}

// AddSession stores a signed-in session for token, as the GitHub OAuth flow
// would for account.
func (g *Gateway) AddSession(token string, account int64, login string) error {
	mac := hmac.New(sha256.New, g.Config.AuthSecret)
	_, _ = mac.Write([]byte(token))
	digest := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	now := time.Now().UTC()
	return g.Store.UpdateAuthState(func(state *gateway.AuthState) error {
		state.Sessions = append(state.Sessions, gateway.Session{
			TokenHash: digest, GitHubID: account, Login: login, CreatedAt: now, ExpiresAt: now.Add(g.Config.SessionTTL),
		})
		return nil
	})
}

// NewSession signs account in with a fresh random token.
func (g *Gateway) NewSession(prefix string, account int64, login string) (string, error) {
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	token := prefix + hex.EncodeToString(raw)
	return token, g.AddSession(token, account, login)
}

// Dial opens a plaintext gRPC connection to the gateway.
func (g *Gateway) Dial() (*grpc.ClientConn, error) {
	return grpc.NewClient(g.Address, grpc.WithTransportCredentials(insecure.NewCredentials()))
}

// Authorized attaches a client session to ctx.
func Authorized(ctx context.Context, session string) context.Context {
	return metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+session, "x-dieter-client-version", ClientVersion)
}

// Routed attaches a client session and a target daemon to ctx, so gateway
// Daemon API calls relay to that daemon.
func Routed(ctx context.Context, session, daemonID string) context.Context {
	return metadata.AppendToOutgoingContext(Authorized(ctx, session), "x-dieter-daemon-id", daemonID)
}

// DaemonOptions configures an in-process daemon behind a gateway.
type DaemonOptions struct {
	// Root is the daemon's Dieter home; required.
	Root string
	// Name is the enrolled machine name.
	Name string
	// Account approves the enrollment; zero selects Account.
	Account int64
	// Identity reuses an enrolled identity instead of enrolling in Root.
	Identity *link.Identity
	// Store is the daemon's central store; it defaults to one in the
	// identity's root. Pass the instance a test also writes through.
	Store *store.Store
	// API configures the daemon's API server. Runner and Catalog are required.
	API api.Options
	// Version is the release the tunnel reports; empty selects ClientVersion.
	Version string
	// Direct serves and advertises an authenticated loopback direct TLS route.
	Direct bool
	// ControlWebRTC offers WebRTC control connections. They forward to their
	// own unadvertised direct TLS route, so a test can stop the advertised
	// route and keep WebRTC, or the reverse.
	ControlWebRTC bool
	// Tunnel adjusts the gateway client before it runs.
	Tunnel func(*link.GatewayClient)
	// NoWait returns before the gateway registered the relay.
	NoWait bool
	Logger *slog.Logger
}

// Daemon is an enrolled in-process daemon: its store, API server, optional
// direct route, and reverse tunnel.
type Daemon struct {
	Identity *link.Identity
	Store    *store.Store
	API      *api.Server
	// Address is the loopback API address; Token authenticates it.
	Address string
	Token   string
	Direct  *link.DirectRoute
	Control *controlrtc.Manager
	Tunnel  *link.GatewayClient

	http         *http.Server
	controlRoute *link.DirectRoute
	stopTunnel   context.CancelFunc
	tunnelDone   chan struct{}
}

// StartDaemon enrolls (unless options.Identity is set) and starts a daemon
// whose tunnel connects to g. It waits until the gateway relays to it.
func (g *Gateway) StartDaemon(ctx context.Context, options DaemonOptions) (*Daemon, error) {
	if options.API.Runner == nil || options.API.Catalog == nil {
		return nil, errors.New("topology: daemon API needs a runner and a catalog")
	}
	logger := options.Logger
	if logger == nil {
		logger = discard()
	}
	identity := options.Identity
	if identity == nil {
		if options.Root == "" {
			return nil, errors.New("topology: daemon root is required")
		}
		account := options.Account
		if account == 0 {
			account = Account
		}
		var err error
		if identity, err = g.Enroll(ctx, options.Root, options.Name, account); err != nil {
			return nil, err
		}
	}
	data := options.Store
	if data == nil {
		data = store.New(identity.Root)
	}
	if err := data.Ensure(); err != nil {
		return nil, err
	}
	token, err := localauth.Ensure(data.Root)
	if err != nil {
		return nil, err
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	daemon := &Daemon{Identity: identity, Store: data, Address: listener.Addr().String(), Token: token}
	var routes []*gatewayv1.DirectCandidate
	if options.Direct {
		if daemon.Direct, err = serveDirectRoute(identity, daemon.Address, token, "loopback"); err != nil {
			_ = listener.Close()
			return nil, err
		}
		routes = append(routes, daemon.Direct.Candidate)
	}
	if options.ControlWebRTC {
		if daemon.controlRoute, err = serveDirectRoute(identity, daemon.Address, token, "control"); err != nil {
			daemon.Close()
			_ = listener.Close()
			return nil, err
		}
		daemon.Control = controlrtc.New(controlrtc.Identity{DaemonID: identity.ID, GatewayURL: identity.Issuer(), Generation: identity.Generation, GatewaySigningPublicKey: identity.GatewaySigningPublicKey}, daemon.controlRoute.Listener.Addr().String())
		options.API.ControlRTC = daemon.Control
	}
	daemon.API = api.NewWithOptions(data, logger, options.API)
	daemon.http = &http.Server{Handler: daemon.API.Handler(), Protocols: api.LoopbackProtocols()}
	go func() { _ = daemon.http.Serve(listener) }()
	version := options.Version
	if version == "" {
		version = ClientVersion
	}
	daemon.Tunnel = &link.GatewayClient{Identity: identity, LocalTarget: daemon.Address, LocalToken: token, Version: version, Routes: routes, ControlWebRTC: options.ControlWebRTC, Log: logger}
	if options.Tunnel != nil {
		options.Tunnel(daemon.Tunnel)
	}
	daemon.StartTunnel(ctx)
	if options.NoWait {
		return daemon, nil
	}
	if err := g.WaitRelay(ctx, identity.ID); err != nil {
		daemon.Close()
		return nil, err
	}
	return daemon, nil
}

// WaitRelay waits until the gateway relays to daemonID.
func (g *Gateway) WaitRelay(ctx context.Context, daemonID string) error {
	deadline := time.Now().Add(ReadyTimeout)
	for !g.Server.Hub.RelayReady(daemonID) {
		if time.Now().After(deadline) {
			return fmt.Errorf("daemon %s did not connect to the gateway within %s", daemonID, ReadyTimeout)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(10 * time.Millisecond):
		}
	}
	return nil
}

// StartTunnel runs the daemon's gateway tunnel until StopTunnel or Close.
func (d *Daemon) StartTunnel(ctx context.Context) {
	d.StopTunnel()
	tunnelContext, stop := context.WithCancel(context.WithoutCancel(ctx))
	done := make(chan struct{})
	d.stopTunnel, d.tunnelDone = stop, done
	go func() {
		defer close(done)
		_ = d.Tunnel.Run(tunnelContext)
	}()
}

// StopTunnel disconnects the daemon from the gateway and waits for the
// tunnel to exit. The API and direct route keep serving.
func (d *Daemon) StopTunnel() {
	if d.stopTunnel == nil {
		return
	}
	d.stopTunnel()
	<-d.tunnelDone
	d.stopTunnel, d.tunnelDone = nil, nil
}

// Close stops the tunnel, the control connections, the direct route, and
// the API server.
func (d *Daemon) Close() {
	d.StopTunnel()
	if d.Control != nil {
		d.Control.Close()
	}
	for _, route := range []*link.DirectRoute{d.controlRoute, d.Direct} {
		if route != nil {
			route.Server.Stop()
			_ = route.Listener.Close()
		}
	}
	if d.http != nil {
		_ = d.http.Close()
	}
}

func serveDirectRoute(identity *link.Identity, target, token, id string) (*link.DirectRoute, error) {
	route, err := link.NewDirectRoute(identity, target, token, id, "127.0.0.1:0", "127.0.0.1", "loopback", 1000)
	if err != nil {
		return nil, err
	}
	go func() { _ = route.Server.Serve(route.Listener) }()
	return route, nil
}

func discard() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }
