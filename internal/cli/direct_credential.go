package cli

import (
	"context"
	"sync"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Refresh only before a new RPC. An existing stream still expires on the
// server; read subscriptions reopen with the renewed credential and cursor.
type directCredential struct {
	mu         sync.Mutex
	access     *gatewayv1.DaemonAccessToken
	refreshing chan struct{}
	exchange   func(context.Context) (*gatewayv1.DaemonAccessToken, error)
	timeout    time.Duration
}

func (c *directCredential) RequireTransportSecurity() bool { return true }

func (c *directCredential) GetRequestMetadata(ctx context.Context, _ ...string) (map[string]string, error) {
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		c.mu.Lock()
		expires, _ := time.Parse(time.RFC3339Nano, c.access.GetExpiresAt())
		if c.access.GetTokenType() == "Bearer" && c.access.GetAccessToken() != "" && expires.After(time.Now().Add(30*time.Second)) {
			token := c.access.GetAccessToken()
			c.mu.Unlock()
			return map[string]string{"authorization": "Bearer " + token}, nil
		}
		if pending := c.refreshing; pending != nil {
			c.mu.Unlock()
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-pending:
				continue
			}
		}
		pending := make(chan struct{})
		c.refreshing = pending
		c.mu.Unlock()
		refreshCtx, cancel := context.WithTimeout(ctx, c.timeout)
		access, err := c.exchange(refreshCtx)
		cancel()
		expires, parseErr := time.Parse(time.RFC3339Nano, access.GetExpiresAt())
		if err == nil && (access.GetTokenType() != "Bearer" || access.GetAccessToken() == "" || parseErr != nil || !expires.After(time.Now())) {
			err = status.Error(codes.Unauthenticated, "gateway returned an invalid direct credential")
		}
		c.mu.Lock()
		if err == nil {
			c.access = access
		}
		c.refreshing = nil
		close(pending)
		c.mu.Unlock()
		if err != nil {
			return nil, err
		}
		return map[string]string{"authorization": "Bearer " + access.GetAccessToken()}, nil
	}
}
