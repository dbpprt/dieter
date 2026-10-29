package gateway

import (
	"fmt"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
)

func TestProviderResultValidatesBeforeConsumingRequest(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"refresh", "reset"} {
		t.Run(kind, func(t *testing.T) {
			m := NewQuotaManager(nil, nil, nil)
			p := pendingProviderRefresh{githubID: 1, daemonID: "owner", kind: kind, provider: gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, accountKey: "account_key_aaaaaaaaaaaaaaaaaaaa"}
			index := providerAccountIndex(p.githubID, p.provider, p.accountKey)
			m.pending["request"], m.byAccount[index] = p, "request"
			for _, wrong := range []struct {
				owner        int64
				daemon, kind string
			}{{2, "owner", kind}, {1, "other", kind}, {1, "owner", "other"}} {
				if _, _, err := m.claimProviderResult(wrong.owner, wrong.daemon, "request", wrong.kind, func(pendingProviderRefresh) error { return nil }); err == nil {
					t.Fatal("unauthorized result accepted")
				}
				if len(m.pending) != 1 || m.byAccount[index] != "request" {
					t.Fatal("invalid result consumed pending operation")
				}
			}
			badAccount := &gatewayv1.ProviderQuotaSnapshot{Provider: p.provider, AccountKey: "other"}
			if _, _, err := m.claimProviderResult(1, "owner", "request", kind, func(p pendingProviderRefresh) error { return validateProviderResultAccount(p, badAccount) }); err == nil || len(m.pending) != 1 {
				t.Fatal("mismatched snapshot consumed request")
			}
			for i := range 2 {
				_, apply, err := m.claimProviderResult(1, "owner", "request", kind, func(pendingProviderRefresh) error { return nil })
				if err != nil || apply != (i == 0) {
					t.Fatalf("result %d: apply=%v err=%v", i, apply, err)
				}
			}
			if len(m.pending) != 0 || len(m.byAccount) != 0 {
				t.Fatal("completed operation retained admission")
			}
			if _, _, err := m.claimProviderResult(2, "owner", "request", kind, func(pendingProviderRefresh) error { return nil }); err == nil {
				t.Fatal("retired result accepted wrong account")
			}
		})
	}
}

func TestLateQuotaResultsAreIgnoredWithinBoundedCorrelationWindow(t *testing.T) {
	t.Parallel()
	m := NewQuotaManager(nil, nil, nil)
	now := time.Now()
	m.now = func() time.Time { return now }
	for i := range maxRetiredProviderRequests + 10 {
		m.retireProviderRequest(fmt.Sprint(i), pendingProviderRefresh{githubID: 1, daemonID: "owner", kind: "refresh"}, now)
	}
	if len(m.retired) != maxRetiredProviderRequests {
		t.Fatal("unbounded retired requests")
	}
	id := fmt.Sprint(maxRetiredProviderRequests + 9)
	if err := m.HandleResult(DaemonRecord{GitHubID: 1}, "owner", id, &gatewayv1.ProviderQuotaRefreshResult{ErrorCode: "late"}); err != nil {
		t.Fatal(err)
	}
	if err := m.HandleResult(DaemonRecord{GitHubID: 1}, "owner", "unsolicited", &gatewayv1.ProviderQuotaRefreshResult{ErrorCode: "late"}); err == nil {
		t.Fatal("unsolicited reply accepted")
	}
	if err := m.HandleResult(DaemonRecord{GitHubID: 1}, "owner", id, nil); err == nil {
		t.Fatal("malformed reply accepted")
	}
	now = now.Add(retiredProviderRequestTTL)
	if err := m.HandleResult(DaemonRecord{GitHubID: 1}, "owner", id, &gatewayv1.ProviderQuotaRefreshResult{ErrorCode: "late"}); err == nil {
		t.Fatal("expired correlation accepted")
	}
	m.retireProviderRequest("new", pendingProviderRefresh{}, now)
	if len(m.retired) != 1 {
		t.Fatal("expired entries retained")
	}
}
