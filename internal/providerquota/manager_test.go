package providerquota

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
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
	t.Setenv("CODEX_HOME", first)
	profiles, err := configuredCodexProfiles()
	if err != nil {
		t.Fatal(err)
	}
	if got, want := len(profiles), 2; got != want {
		t.Fatalf("profiles = %v, want %d distinct entries", profiles, want)
	}
}

func TestClaudeDiscoveryAndRefreshShareFiveMinutePollingAndTenMinuteRecovery(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	t.Setenv("DIETER_CLAUDE_ACCOUNT_HOMES", "")
	t.Setenv("CODEX_HOME", t.TempDir())
	t.Setenv("DIETER_CODEX_ACCOUNT_HOMES", "")
	provider := gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE
	key := make([]byte, 32)
	start := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	now := start
	manager := New(t.TempDir(), nil)
	manager.now = func() time.Time { return now }
	var calls int
	fail := false
	manager.readProbe = func(_ context.Context, got gatewayv1.ProviderQuotaProvider, _ string) (probeResult, error) {
		if got != provider {
			return probeResult{}, nil
		}
		calls++
		if fail {
			return probeResult{}, errors.New("provider throttled")
		}
		return probeResult{StableAccountID: "claude-account", Availability: "available"}, nil
	}
	discover := func() {
		t.Helper()
		if _, err := manager.Discover(context.Background(), key); err != nil {
			t.Fatal(err)
		}
	}
	discover()
	accountKey := manager.ActiveAccountKey("claude-code")
	if accountKey == "" {
		t.Fatal("successful discovery must associate the active profile")
	}
	refresh := func() *gatewayv1.ProviderQuotaRefreshResult {
		t.Helper()
		result, err := manager.Refresh(context.Background(), key, &gatewayv1.ProviderQuotaRefreshRequest{Provider: provider, AccountKey: accountKey})
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	for _, elapsed := range []time.Duration{time.Minute, 4*time.Minute + 59*time.Second} {
		now = start.Add(elapsed)
		discover()
		if result := refresh(); result.GetSnapshot() == nil {
			t.Fatalf("cached refresh = %v", result)
		}
		if got := manager.handles[accountKey].probedAt; !got.Equal(start) {
			t.Fatalf("cached discovery moved probe time to %s", got)
		}
	}
	if calls != 1 {
		t.Fatalf("made %d provider calls inside the five-minute interval", calls)
	}
	now = start.Add(5 * time.Minute)
	fail = true
	discover()
	if result := refresh(); result.GetErrorCode() != "temporarily_unavailable" || result.GetRetryAfterSeconds() != 600 {
		t.Fatalf("failed refresh = %v", result)
	}
	if calls != 2 {
		t.Fatalf("failed discovery and refresh made %d calls, want 2 total", calls)
	}
	if manager.ActiveAccountKey("claude-code") != accountKey {
		t.Fatal("temporary failure lost the known account association")
	}
	now = start.Add(15*time.Minute - time.Second)
	discover()
	refresh()
	if calls != 2 {
		t.Fatalf("retried before the ten-minute cooldown: %d calls", calls)
	}
	now = start.Add(15 * time.Minute)
	fail = false
	discover()
	if result := refresh(); result.GetSnapshot() == nil {
		t.Fatalf("recovered refresh = %v", result)
	}
	if calls != 3 {
		t.Fatalf("recovery made %d calls, want 3 total", calls)
	}
}

func TestClaudeColdDiscoveryFailureWaitsTenMinutesAndConcurrentReadsCoalesce(t *testing.T) {
	manager := New(t.TempDir(), nil)
	provider := gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE
	start := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	now := start
	manager.now = func() time.Time { return now }
	var calls atomic.Int32
	fail := true
	manager.readProbe = func(context.Context, gatewayv1.ProviderQuotaProvider, string) (probeResult, error) {
		calls.Add(1)
		if fail {
			return probeResult{}, errors.New("provider throttled")
		}
		return probeResult{StableAccountID: "claude-account", Availability: "available"}, nil
	}
	if _, err := manager.probe(context.Background(), provider, ""); err == nil {
		t.Fatal("expected cold probe failure")
	}
	now = start.Add(10*time.Minute - time.Second)
	if _, err := manager.probe(context.Background(), provider, ""); err == nil {
		t.Fatal("cooldown must retain the failed state")
	}
	if calls.Load() != 1 {
		t.Fatal("cold discovery retried during cooldown")
	}
	now = start.Add(10 * time.Minute)
	fail = false
	var group sync.WaitGroup
	for range 20 {
		group.Add(1)
		go func() {
			defer group.Done()
			if _, err := manager.probe(context.Background(), provider, ""); err != nil {
				t.Error(err)
			}
		}()
	}
	group.Wait()
	if calls.Load() != 2 {
		t.Fatalf("overlapping reads made %d provider calls, want 2 total", calls.Load())
	}
}

func TestActiveAccountKeyUsesTheHarnessCodexProfile(t *testing.T) {
	active, other := t.TempDir(), t.TempDir()
	t.Setenv("CODEX_HOME", active)
	manager := New(t.TempDir(), nil)
	manager.handles["active-account-key"] = accountHandle{
		provider: gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, profileRoot: active,
	}
	manager.handles["other-account-key"] = accountHandle{
		provider: gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX, profileRoot: other,
	}

	if got, want := manager.ActiveAccountKey("codex"), "active-account-key"; got != want {
		t.Fatalf("active account key = %q, want %q", got, want)
	}
	manager.handles["claude-account-key"] = accountHandle{
		provider: gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE,
	}
	if got, want := manager.ActiveAccountKey("claude-code"), "claude-account-key"; got != want {
		t.Fatalf("Claude account key = %q, want %q", got, want)
	}
}

func TestConfiguredClaudeProfilesPreservesTheUnsetDefaultProfile(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	other := t.TempDir()
	t.Setenv("DIETER_CLAUDE_ACCOUNT_HOMES", other)
	profiles, err := configuredClaudeProfiles()
	if err != nil {
		t.Fatal(err)
	}
	if len(profiles) != 2 || profiles[0] != "" || profiles[1] != other {
		t.Fatalf("Claude profiles = %#v, want default plus %q", profiles, other)
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
	snapshot := normalizeSnapshot(
		gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX,
		"account_key_aaaaaaaaaaaaaaaaaaaa", result, now,
	)
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
		provider:        gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX,
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
