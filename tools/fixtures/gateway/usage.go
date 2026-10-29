package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/protobuf/proto"
)

// Uses the real daemon/gateway quota exchange without reading host credentials.
type isolatedUsageQuotas struct{}

func usageAccountKey(key []byte) string {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte("isolated-usage-account"))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (isolatedUsageQuotas) Discover(_ context.Context, key []byte) (*gatewayv1.ProviderAccountsPresence, error) {
	return &gatewayv1.ProviderAccountsPresence{Accounts: []*gatewayv1.ProviderAccountPresence{{
		Provider:   gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX,
		AccountKey: usageAccountKey(key), AccountKind: gatewayv1.ProviderAccountKind_PROVIDER_ACCOUNT_KIND_SUBSCRIPTION,
		Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE, RefreshSupported: true,
	}}}, nil
}

func (isolatedUsageQuotas) Refresh(_ context.Context, key []byte, request *gatewayv1.ProviderQuotaRefreshRequest) (*gatewayv1.ProviderQuotaRefreshResult, error) {
	if request.GetAccountKey() != usageAccountKey(key) || request.GetProvider() != gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX {
		return &gatewayv1.ProviderQuotaRefreshResult{ErrorCode: "unknown_account"}, nil
	}
	return &gatewayv1.ProviderQuotaRefreshResult{Snapshot: &gatewayv1.ProviderQuotaSnapshot{
		Provider: request.GetProvider(), AccountKey: request.GetAccountKey(),
		AccountKind:  gatewayv1.ProviderAccountKind_PROVIDER_ACCOUNT_KIND_SUBSCRIPTION,
		Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
		DisplayEmail: "widget@example.test", Plan: "pro",
		Windows: []*gatewayv1.ProviderQuotaWindow{{Id: "weekly", Label: "Weekly", RemainingPercent: proto.Uint32(72), ResetsAt: time.Now().Add(24 * time.Hour).UTC().Format(time.RFC3339)}},
	}}, nil
}
