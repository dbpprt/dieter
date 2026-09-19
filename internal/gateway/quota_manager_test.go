package gateway

import (
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/protobuf/proto"
)

func TestSummarizeProviderQuotasUsesLowestDistinctAccountWindow(t *testing.T) {
	now := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)
	firstReset := now.Add(90 * time.Minute).Format(time.RFC3339)
	secondReset := now.Add(3 * time.Hour).Format(time.RFC3339)
	accounts := []*gatewayv1.ProviderQuotaSnapshot{
		{
			AccountKey: "account_key_aaaaaaaaaaaaaaaaaaaa", Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
			FreshUntil: now.Add(time.Hour).Format(time.RFC3339),
			Windows: []*gatewayv1.ProviderQuotaWindow{
				{Id: "five-hour", Label: "5 hour", RemainingPercent: proto.Uint32(72), ResetsAt: firstReset},
				{Id: "weekly", Label: "Weekly", RemainingPercent: proto.Uint32(49), ResetsAt: secondReset},
			},
		},
		{
			AccountKey: "account_key_bbbbbbbbbbbbbbbbbbbb", Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
			FreshUntil: now.Add(time.Hour).Format(time.RFC3339),
			Windows: []*gatewayv1.ProviderQuotaWindow{
				{Id: "five-hour", Label: "5 hour", RemainingPercent: proto.Uint32(18), ResetsAt: firstReset},
			},
		},
	}

	summary := summarizeProviderQuotas(accounts, now)
	if got, want := summary.GetRemainingPercent(), uint32(18); got != want {
		t.Fatalf("remaining = %d, want %d (account quotas must not be summed or averaged)", got, want)
	}
	if got, want := summary.GetSummaryAccountKey(), accounts[1].GetAccountKey(); got != want {
		t.Fatalf("summary account = %q, want %q", got, want)
	}
	if got, want := summary.GetTotalAccountCount(), uint32(2); got != want {
		t.Fatalf("total accounts = %d, want %d", got, want)
	}
	if got, want := summary.GetNumericAccountCount(), uint32(2); got != want {
		t.Fatalf("numeric accounts = %d, want %d", got, want)
	}
}

func TestSummarizeProviderQuotasReportsUnavailableAccountsAndStaleSelection(t *testing.T) {
	now := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)
	accounts := []*gatewayv1.ProviderQuotaSnapshot{
		{
			AccountKey: "account_key_aaaaaaaaaaaaaaaaaaaa", Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
			FreshUntil: now.Add(-time.Minute).Format(time.RFC3339),
			Windows:    []*gatewayv1.ProviderQuotaWindow{{Id: "weekly", RemainingPercent: proto.Uint32(31)}},
		},
		{
			AccountKey:   "account_key_bbbbbbbbbbbbbbbbbbbb",
			Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_TEMPORARILY_UNAVAILABLE,
			FreshUntil:   now.Add(-time.Minute).Format(time.RFC3339),
			Windows:      []*gatewayv1.ProviderQuotaWindow{{Id: "weekly", RemainingPercent: proto.Uint32(80)}},
		},
	}

	summary := summarizeProviderQuotas(accounts, now)
	if summary.GetFreshness() != gatewayv1.ProviderQuotaFreshness_PROVIDER_QUOTA_FRESHNESS_STALE {
		t.Fatalf("freshness = %s, want stale", summary.GetFreshness())
	}
	if got, want := summary.GetUnavailableAccountCount(), uint32(1); got != want {
		t.Fatalf("unavailable accounts = %d, want %d", got, want)
	}
	if got, want := summary.GetNumericAccountCount(), uint32(2); got != want {
		t.Fatalf("numeric accounts = %d, want %d", got, want)
	}
}

func TestValidateProviderQuotaSnapshotRejectsInconsistentPercentages(t *testing.T) {
	snapshot := &gatewayv1.ProviderQuotaSnapshot{
		Provider:     gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX,
		AccountKey:   "account_key_aaaaaaaaaaaaaaaaaaaa",
		Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
		Windows: []*gatewayv1.ProviderQuotaWindow{{
			Id: "weekly", UsedPercent: proto.Uint32(80), RemainingPercent: proto.Uint32(30),
		}},
	}
	if err := validateProviderQuotaSnapshot(snapshot); err == nil {
		t.Fatal("inconsistent percentages were accepted")
	}
}
