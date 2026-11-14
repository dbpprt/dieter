//go:build e2e

package gateway_test

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/testkit/topology"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/protobuf/types/known/emptypb"
)

type lateQuotaSource struct {
	started, release, returned chan struct{}
	once                       sync.Once
}

func (*lateQuotaSource) Discover(context.Context, []byte) (*gatewayv1.ProviderAccountsPresence, error) {
	return &gatewayv1.ProviderAccountsPresence{Accounts: []*gatewayv1.ProviderAccountPresence{{Provider: gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, AccountKey: "account_key_aaaaaaaaaaaaaaaaaaaa", AccountKind: gatewayv1.ProviderAccountKind_PROVIDER_ACCOUNT_KIND_SUBSCRIPTION, Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE, RefreshSupported: true}}}, nil
}

func (s *lateQuotaSource) Refresh(ctx context.Context, _ []byte, _ *gatewayv1.ProviderQuotaRefreshRequest) (*gatewayv1.ProviderQuotaRefreshResult, error) {
	s.once.Do(func() { close(s.started) })
	<-ctx.Done()
	// Simulate a provider returning after the gateway has timed out the request.
	// The owning test always releases this barrier, including on failure.
	<-s.release
	select {
	case s.returned <- struct{}{}:
	default:
	}
	return &gatewayv1.ProviderQuotaRefreshResult{ErrorCode: "probe_timeout"}, nil
}

func TestLateProviderQuotaReplyKeepsControlLaneAlive(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(t.Context(), testkit.Budget(45*time.Second))
	defer cancel()
	source := &lateQuotaSource{started: make(chan struct{}), release: make(chan struct{}), returned: make(chan struct{}, 1)}
	var release sync.Once
	defer release.Do(func() { close(source.release) })
	var acks, disconnects atomic.Int64
	g := topology.StartGateway(t, topology.GatewayOptions{})
	daemon := topology.StartDaemon(t, g, topology.DaemonOptions{Tunnel: func(tunnel *link.GatewayClient) {
		tunnel.ProviderQuotas = source
		tunnel.OnStatus = func(event link.GatewayEvent) {
			if event.State == link.GatewayDisconnected {
				disconnects.Add(1)
			}
		}
		tunnel.OnAcknowledged = func(time.Time) { acks.Add(1) }
		tunnel.Timing = link.GatewayTiming{HeartbeatActiveInterval: 100 * time.Millisecond, HeartbeatIdleMaxInterval: 100 * time.Millisecond}
	}})
	select {
	case <-source.started:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	testkit.Eventually(t, 25*time.Second, func() bool {
		groups, err := g.Server.Quota.Catalog(topology.Account, gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX)
		return err == nil && len(groups) == 1 && groups[0].GetAccounts()[0].GetStatusCode() == "timeout"
	}, "quota request did not expire")
	beforeAcks, beforeDisconnects := acks.Load(), disconnects.Load()
	release.Do(func() { close(source.release) })
	select {
	case <-source.returned:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	// Several subsequent heartbeats prove that the result was consumed without
	// closing the control stream, rather than merely observing cached presence.
	testkit.Eventually(t, 10*time.Second, func() bool { return acks.Load() >= beforeAcks+5 }, "control acknowledgements did not continue")
	if disconnects.Load() != beforeDisconnects {
		t.Fatal("late quota reply disconnected the control lane")
	}
	phone := topology.StartClient(t, g, daemon, "Quota test client")
	client := dieterclient.New(topology.DialDaemon(t, phone, daemon, topology.Tunnel))
	if _, err := client.Health(ctx, &emptypb.Empty{}); err != nil {
		t.Fatal(err)
	}
}
