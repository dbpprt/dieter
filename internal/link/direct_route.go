package link

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"strconv"
	"strings"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
)

// DirectRoute is one bound authenticated TLS listener that forwards to the
// local API, together with the candidate the gateway advertises for it.
type DirectRoute struct {
	Listener  net.Listener
	Server    *DirectServer
	Candidate *gatewayv1.DirectCandidate
}

// NewDirectRoute binds listenAddress and prepares a direct TLS forwarder to
// localTarget. The advertised candidate uses the bound port, so an ephemeral
// listen port is advertised exactly.
func NewDirectRoute(identity *Identity, deviceTrust *Trust, localTarget, localToken, id, listenAddress, advertisedHost, network string, priority int32) (*DirectRoute, error) {
	listener, err := net.Listen("tcp", strings.TrimSpace(listenAddress))
	if err != nil {
		return nil, err
	}
	closeListener := true
	defer func() {
		if closeListener {
			_ = listener.Close()
		}
	}()
	_, portText, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		return nil, fmt.Errorf("resolve direct listener port: %w", err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return nil, fmt.Errorf("resolve direct listener port: invalid port %q", portText)
	}
	direct, err := NewDirectServer(identity, deviceTrust, localTarget, localToken)
	if err != nil {
		return nil, err
	}
	closeListener = false
	return &DirectRoute{
		Listener: listener,
		Server:   direct,
		Candidate: &gatewayv1.DirectCandidate{
			Id:                  strings.TrimSpace(id),
			Host:                strings.TrimSpace(advertisedHost),
			Port:                uint32(port),
			Network:             strings.TrimSpace(network),
			Priority:            priority,
			CertificateIdentity: identity.ID,
		},
	}, nil
}

// Serve runs the route until ctx ends. A listener failure while ctx is still
// live cancels the daemon through cancel.
func (r *DirectRoute) Serve(ctx context.Context, cancel context.CancelFunc, logger *slog.Logger) {
	go func() {
		if err := r.Server.Serve(r.Listener); err != nil && ctx.Err() == nil {
			logger.Error("direct daemon listener stopped", "route", r.Candidate.GetId(), "error", err)
			cancel()
		}
	}()
	go func() {
		<-ctx.Done()
		r.Server.Stop()
		_ = r.Listener.Close()
	}()
}
