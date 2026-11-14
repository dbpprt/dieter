package topology

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"strconv"
	"sync"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/security/roster"
	"github.com/dbpprt/dieter/internal/transport/relay"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/emptypb"
)

// Client is a paired app device for tests: a software P-256 key signed into
// the account's roster through the production pairing path, and a gateway
// session. It dials daemons over the same mutual TLS as the native apps.
type Client struct {
	Key        *ecdsa.PrivateKey
	Descriptor *roster.Descriptor
	Session    string
	// Gateway carries the client session on every call.
	Gateway grpc.ClientConnInterface

	mu     sync.Mutex
	pinned *roster.State
	conn   *grpc.ClientConn
}

// DeviceID is the client's roster device ID.
func (c *Client) DeviceID() string { return c.Descriptor.GetDeviceId() }

// Roster is the roster the client pinned.
func (c *Client) Roster() *roster.State {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.pinned
}

// Close releases the client's gateway connection.
func (c *Client) Close() { _ = c.conn.Close() }

// NewClient signs a client device of account in and pairs it: it posts a
// pairing request with a fresh code, approver approves the code exactly as
// `dieter device approve` does, and the client pins the roster only after the
// approver's confirmation verifies.
func (g *Gateway) NewClient(ctx context.Context, approver *Daemon, name string) (*Client, error) {
	secret, code, err := roster.NewPairingSecret()
	if err != nil {
		return nil, err
	}
	return g.newClient(ctx, approver.Account, name, secret, func() error {
		_, err := approver.Trust.Approve(ctx, code)
		return err
	})
}

// NewClientWithCode pairs a client device of account with a shared code that
// a trusted device keeps approving, as the isolated fixture gateway does.
func (g *Gateway) NewClientWithCode(ctx context.Context, account int64, name, code string) (*Client, error) {
	secret, err := roster.ParsePairingCode(code)
	if err != nil {
		return nil, err
	}
	return g.newClient(ctx, account, name, secret, nil)
}

func (g *Gateway) newClient(ctx context.Context, account int64, name string, secret []byte, approve func() error) (*Client, error) {
	session, err := g.NewSession("client_", account, g.login)
	if err != nil {
		return nil, err
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, err
	}
	descriptor, err := roster.Describe(gatewayv1.DeviceKind_DEVICE_KIND_CLIENT, "jvm", name, "", key.Public())
	if err != nil {
		return nil, err
	}
	conn, err := g.Dial()
	if err != nil {
		return nil, err
	}
	client := &Client{Key: key, Descriptor: descriptor, Session: session, Gateway: SessionConn(conn, session), conn: conn}
	if err := client.pair(ctx, secret, approve); err != nil {
		client.Close()
		return nil, err
	}
	return client, nil
}

// Pair asks to join with the code of secret and pins the roster once the
// confirmation of a device that saw the code verifies; approve, when set, runs
// after the request was posted.
func (c *Client) pair(ctx context.Context, secret []byte, approve func() error) error {
	gateway := gatewayv1.NewGatewayServiceClient(c.Gateway)
	request, err := gateway.PostPairingRequest(ctx, &gatewayv1.PostPairingRequestRequest{Device: c.Descriptor, Proof: roster.PairingProof(secret, c.Descriptor)})
	if err != nil {
		return err
	}
	if approve != nil {
		if err := approve(); err != nil {
			return fmt.Errorf("approve the test client: %w", err)
		}
	}
	var confirmation []byte
	if err := waitFor(ctx, func() bool {
		list, err := gateway.ListPairingRequests(ctx, &emptypb.Empty{})
		if err != nil {
			return false
		}
		for _, candidate := range list.GetRequests() {
			if candidate.GetId() == request.GetId() && len(candidate.GetConfirmation()) > 0 {
				confirmation = candidate.GetConfirmation()
				return true
			}
		}
		return false
	}, "the pairing confirmation"); err != nil {
		return err
	}
	served, err := gateway.GetDeviceRoster(ctx, &gatewayv1.GetDeviceRosterRequest{})
	if err != nil {
		return err
	}
	state, err := roster.Verify(served.GetEntries())
	if err != nil {
		return err
	}
	member := state.Member(c.DeviceID())
	if !member.Active() || !roster.VerifyPairingConfirmation(secret, state.Root(), state.HashAt(member.AddedAt), confirmation) {
		return errors.New("the pairing confirmation does not verify")
	}
	c.mu.Lock()
	c.pinned = state
	c.mu.Unlock()
	_, err = gateway.DeletePairingRequest(ctx, &gatewayv1.PairingRequestRef{Id: request.GetId()})
	return err
}

// Refresh extends the pinned roster from the gateway.
func (c *Client) Refresh(ctx context.Context) error {
	served, err := gatewayv1.NewGatewayServiceClient(c.Gateway).GetDeviceRoster(ctx, &gatewayv1.GetDeviceRosterRequest{})
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	next, err := c.pinned.Extend(served.GetEntries())
	if err != nil {
		return err
	}
	c.pinned = next
	return nil
}

// Route selects the carrier of a daemon connection.
type Route int

const (
	// Tunnel relays opaque TLS bytes through the gateway.
	Tunnel Route = iota
	// Direct connects to the daemon's advertised direct route.
	Direct
)

// Certificate is the client's TLS device certificate.
func (c *Client) Certificate() (tls.Certificate, error) { return link.DeviceCertificate(c.Key) }

// DaemonKey is the roster key of daemonID that the client pinned.
func (c *Client) DaemonKey(ctx context.Context, daemonID string) ([]byte, error) {
	if c.Roster().Daemon(daemonID) == nil {
		if err := c.Refresh(ctx); err != nil {
			return nil, err
		}
	}
	member := c.Roster().Daemon(daemonID)
	if member == nil {
		return nil, fmt.Errorf("daemon %s is not in the client's roster", daemonID)
	}
	return member.Descriptor.GetPublicKey(), nil
}

// Token exchanges the client session for a daemon token bound to the device.
func (c *Client) Token(ctx context.Context, daemonID string) (string, error) {
	token, err := gatewayv1.NewGatewayServiceClient(c.Gateway).ExchangeDaemonToken(ctx, &gatewayv1.ExchangeDaemonTokenRequest{DaemonId: daemonID, ClientKeyThumbprint: c.DeviceID()})
	if err != nil {
		return "", err
	}
	return token.GetAccessToken(), nil
}

// Dial connects to daemonID over route with mutual TLS pinned to the roster.
func (c *Client) Dial(ctx context.Context, daemonID string, route Route) (*grpc.ClientConn, error) {
	daemonKey, err := c.DaemonKey(ctx, daemonID)
	if err != nil {
		return nil, err
	}
	token, err := c.Token(ctx, daemonID)
	if err != nil {
		return nil, err
	}
	certificate, err := c.Certificate()
	if err != nil {
		return nil, err
	}
	dial, err := c.Dialer(ctx, daemonID, route)
	if err != nil {
		return nil, err
	}
	return link.DialDaemon(certificate, daemonKey, link.TokenCredentials(token), dial)
}

// Dialer opens the byte stream of route to daemonID.
func (c *Client) Dialer(ctx context.Context, daemonID string, route Route) (link.Dialer, error) {
	if route == Tunnel {
		return func(ctx context.Context, _ string) (net.Conn, error) {
			return link.DialTunnel(ctx, c.Gateway, daemonID, relay.Command)
		}, nil
	}
	resolved, err := gatewayv1.NewGatewayServiceClient(c.Gateway).ResolveDaemonRoute(ctx, &gatewayv1.DaemonRef{DaemonId: daemonID})
	if err != nil {
		return nil, err
	}
	if len(resolved.GetDirectCandidates()) == 0 {
		return nil, fmt.Errorf("daemon %s advertises no direct route", daemonID)
	}
	candidate := resolved.GetDirectCandidates()[0]
	return link.TCPDialer(net.JoinHostPort(candidate.GetHost(), strconv.Itoa(int(candidate.GetPort())))), nil
}
