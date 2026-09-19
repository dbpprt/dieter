package providerquota

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/protobuf/proto"
)

func TestConfiguredCodexProfilesSupportsSeveralExplicitAccounts(t *testing.T) {
	root := t.TempDir()
	first, second := filepath.Join(root, "first"), filepath.Join(root, "second")
	if err := os.Mkdir(first, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(second, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIETER_CODEX_ACCOUNT_HOMES", first+string(os.PathListSeparator)+second+string(os.PathListSeparator)+first)
	t.Setenv("CODEX_HOME", "")
	profiles, err := configuredCodexProfiles()
	if err != nil {
		t.Fatal(err)
	}
	if got, want := len(profiles), 2; got != want {
		t.Fatalf("profiles = %v, want %d distinct entries", profiles, want)
	}
}

func TestCorrelateAccountIsStableProviderScopedAndOpaque(t *testing.T) {
	key := make([]byte, 32)
	for index := range key {
		key[index] = byte(index + 1)
	}
	first := correlateAccount(key, gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, "provider-account-123")
	again := correlateAccount(key, gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, "provider-account-123")
	other := correlateAccount(key, gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE, "provider-account-123")
	if first != again || first == other {
		t.Fatalf("correlation was not stable and provider-scoped: first=%q again=%q other=%q", first, again, other)
	}
	if first == "provider-account-123" || len(first) < 32 {
		t.Fatalf("correlation exposed or weakened the provider identity: %q", first)
	}
}

func TestNormalizeSnapshotPreservesMultipleWindows(t *testing.T) {
	now := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)
	result := probeResult{
		StableAccountID: "account-1", DisplayEmail: "person@example.com", AccountKind: "subscription", Plan: "plus", Availability: "available",
		Windows: []probeWindow{
			{ID: "five-hour", Label: "5 hour", Kind: "five_hour", UsedPercent: proto.Uint32(30), ResetsAt: now.Add(time.Hour).Format(time.RFC3339)},
			{ID: "weekly", Label: "Weekly", Kind: "weekly", RemainingPercent: proto.Uint32(62), ResetsAt: now.Add(48 * time.Hour).Format(time.RFC3339)},
		},
	}
	snapshot := normalizeSnapshot("account_key_aaaaaaaaaaaaaaaaaaaa", result, now)
	if got, want := len(snapshot.GetWindows()), 2; got != want {
		t.Fatalf("windows = %d, want %d", got, want)
	}
	if got, want := snapshot.GetWindows()[0].GetRemainingPercent(), uint32(70); got != want {
		t.Fatalf("derived remaining = %d, want %d", got, want)
	}
	if got, want := snapshot.GetNextResetWindowId(), "five-hour"; got != want {
		t.Fatalf("next reset window = %q, want %q", got, want)
	}
	if got, want := snapshot.GetDisplayEmail(), "person@example.com"; got != want {
		t.Fatalf("display email = %q, want %q", got, want)
	}
}

func TestResetIdempotencyKeyValidation(t *testing.T) {
	if !validIdempotencyKey("123e4567-e89b-42d3-a456-426614174000") {
		t.Fatal("valid reset UUID was rejected")
	}
	for _, value := range []string{"", "not-a-uuid", "123e4567-e89b-12d3-a456-42661417400z"} {
		if validIdempotencyKey(value) {
			t.Fatalf("invalid reset idempotency key %q was accepted", value)
		}
	}
}

func TestRefreshDoesNotExtendDiscoveryCacheWithoutAProbe(t *testing.T) {
	key := make([]byte, 32)
	for index := range key {
		key[index] = byte(index + 1)
	}
	discoveredAt := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)
	accountKey := correlateAccount(
		key,
		gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX,
		"account-1",
	)
	manager := New(t.TempDir(), nil)
	manager.now = func() time.Time { return discoveredAt.Add(30 * time.Second) }
	manager.handles[accountKey] = accountHandle{
		profileRoot:     t.TempDir(),
		stableAccountID: "account-1",
		lastProbe: probeResult{
			StableAccountID: "account-1",
			Availability:    "available",
		},
		probedAt: discoveredAt,
	}
	result, err := manager.Refresh(context.Background(), key, &gatewayv1.ProviderQuotaRefreshRequest{
		Provider:   gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX,
		AccountKey: accountKey,
	})
	if err != nil || result.GetSnapshot() == nil {
		t.Fatalf("refresh = %#v, %v", result, err)
	}
	if got := manager.handles[accountKey].probedAt; !got.Equal(discoveredAt) {
		t.Fatalf("cached refresh moved probe time to %s; want %s", got, discoveredAt)
	}
}
