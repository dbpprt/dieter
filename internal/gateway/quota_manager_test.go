package gateway

import (
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/protobuf/proto"
)

func TestClaudeQuotaPresenceAndRefreshRespectFiveAndTenMinuteWindows(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	const owner int64 = 91
	const daemonID = "daemon-claude-polling"
	start := time.Date(2026, 10, 8, 12, 0, 0, 0, time.UTC)
	now := start
	if _, err := store.DB.Exec(`INSERT INTO daemons(id, name, github_id, login, public_key, certificate, created_at)
		VALUES(?, ?, ?, ?, ?, ?, ?)`, daemonID, "quota test", owner, "owner", []byte("key"), []byte("cert"), start.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	hub := NewHub(store, Config{})
	link := &daemonLink{id: daemonID, quota: make(chan *gatewayv1.DaemonLinkFrame, 1), done: make(chan struct{}), capabilities: map[string]bool{providerQuotaCapability: true}}
	link.markSeen(time.Now())
	hub.links[daemonID] = link
	manager := NewQuotaManager(store, hub, nil)
	manager.now = func() time.Time { return now }
	provider := gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE
	account := &gatewayv1.ProviderAccountPresence{Provider: provider, AccountKey: "account_key_aaaaaaaaaaaaaaaaaaaa", AccountKind: gatewayv1.ProviderAccountKind_PROVIDER_ACCOUNT_KIND_SUBSCRIPTION, Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE, RefreshSupported: true}
	record := DaemonRecord{GitHubID: owner}
	presence := func() {
		t.Helper()
		if err := manager.HandlePresence(record, daemonID, &gatewayv1.ProviderAccountsPresence{Accounts: []*gatewayv1.ProviderAccountPresence{account}}); err != nil {
			t.Fatal(err)
		}
	}
	request := func() *gatewayv1.DaemonLinkFrame {
		t.Helper()
		select {
		case frame := <-link.quota:
			return frame
		default:
			t.Fatal("expected a refresh request")
			return nil
		}
	}
	noRequest := func() {
		t.Helper()
		select {
		case frame := <-link.quota:
			t.Fatalf("refresh escaped the polling cooldown: %v", frame)
		default:
		}
	}
	presence()
	frame := request()
	if err := manager.HandleResult(record, daemonID, frame.GetRequestId(), &gatewayv1.ProviderQuotaRefreshResult{Snapshot: &gatewayv1.ProviderQuotaSnapshot{Provider: provider, AccountKey: account.GetAccountKey(), AccountKind: account.GetAccountKind(), Availability: account.GetAvailability(), Windows: []*gatewayv1.ProviderQuotaWindow{{Id: "weekly", RemainingPercent: proto.Uint32(76)}}}}); err != nil {
		t.Fatal(err)
	}
	now = start.Add(4*time.Minute + 59*time.Second)
	presence()
	if accepted, err := manager.Refresh(owner, provider, account.GetAccountKey()); err != nil || accepted {
		t.Fatalf("early refresh = %v, %v", accepted, err)
	}
	noRequest()
	groups, err := manager.Catalog(owner, provider)
	if err != nil {
		t.Fatal(err)
	}
	if groups[0].GetSummary().GetFreshness() != gatewayv1.ProviderQuotaFreshness_PROVIDER_QUOTA_FRESHNESS_FRESH {
		t.Fatal("Claude data became stale before its next scheduled probe")
	}
	if got := parseStoredTime(groups[0].GetAccounts()[0].GetNextRefreshAt()); !got.Equal(start.Add(5 * time.Minute)) {
		t.Fatalf("next refresh = %s", got)
	}
	now = start.Add(5 * time.Minute)
	presence()
	frame = request()
	if err := manager.HandleResult(record, daemonID, frame.GetRequestId(), &gatewayv1.ProviderQuotaRefreshResult{ErrorCode: "temporarily_unavailable", RetryAfterSeconds: 1}); err != nil {
		t.Fatal(err)
	}
	now = start.Add(15*time.Minute - time.Second)
	presence()
	manager.Refresh(owner, provider, account.GetAccountKey())
	noRequest()
	now = start.Add(15 * time.Minute)
	presence()
	request()
}

func TestSummarizeProviderQuotasUsesLowestDistinctAccountWindow(t *testing.T) {
	now := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)
	firstReset := now.Add(90 * time.Minute).Format(time.RFC3339)
	secondReset := now.Add(3 * time.Hour).Format(time.RFC3339)
	accounts := []*gatewayv1.ProviderQuotaSnapshot{
		{
			AccountKey: "account_key_aaaaaaaaaaaaaaaaaaaa", Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
			IncludedInSummary: proto.Bool(true),
			FreshUntil:        now.Add(time.Hour).Format(time.RFC3339),
			Windows: []*gatewayv1.ProviderQuotaWindow{
				{Id: "five-hour", Label: "5 hour", RemainingPercent: proto.Uint32(72), ResetsAt: firstReset},
				{Id: "weekly", Label: "Weekly", RemainingPercent: proto.Uint32(49), ResetsAt: secondReset},
			},
		},
		{
			AccountKey: "account_key_bbbbbbbbbbbbbbbbbbbb", Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
			IncludedInSummary: proto.Bool(true),
			FreshUntil:        now.Add(time.Hour).Format(time.RFC3339),
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

func TestSummarizeProviderQuotasExcludesOptedOutAccounts(t *testing.T) {
	now := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)
	accounts := []*gatewayv1.ProviderQuotaSnapshot{
		{AccountKey: "account_key_aaaaaaaaaaaaaaaaaaaa", Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
			IncludedInSummary: proto.Bool(true), FreshUntil: now.Add(time.Hour).Format(time.RFC3339),
			Windows: []*gatewayv1.ProviderQuotaWindow{{Id: "weekly", RemainingPercent: proto.Uint32(72)}}},
		{AccountKey: "account_key_bbbbbbbbbbbbbbbbbbbb", Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
			IncludedInSummary: proto.Bool(false), FreshUntil: now.Add(time.Hour).Format(time.RFC3339),
			Windows: []*gatewayv1.ProviderQuotaWindow{{Id: "weekly", RemainingPercent: proto.Uint32(5)}}},
	}
	summary := summarizeProviderQuotas(accounts, now)
	if got, want := summary.GetRemainingPercent(), uint32(72); got != want {
		t.Fatalf("remaining = %d, want included account value %d", got, want)
	}
	if summary.GetIncludedAccountCount() != 1 || summary.GetExcludedAccountCount() != 1 || summary.GetTotalAccountCount() != 2 {
		t.Fatalf("summary counts = %#v", summary)
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

func TestValidateProviderQuotaSnapshotRejectsDaemonSuppliedMachines(t *testing.T) {
	snapshot := &gatewayv1.ProviderQuotaSnapshot{
		Provider:     gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX,
		AccountKey:   "account_key_aaaaaaaaaaaaaaaaaaaa",
		Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
		Machines:     []*gatewayv1.ProviderQuotaMachine{{DaemonId: "untrusted"}},
	}
	if err := validateProviderQuotaSnapshot(snapshot); err == nil {
		t.Fatal("daemon-supplied machine metadata was accepted")
	}
}

func TestStartResetRoutesExactAccountAndIdempotencyKey(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)
	hub := NewHub(store, Config{})
	link := &daemonLink{
		id: "daemon-reset", quota: make(chan *gatewayv1.DaemonLinkFrame, 1), done: make(chan struct{}),
		capabilities: map[string]bool{providerQuotaCapability: true, providerQuotaResetCapability: true},
	}
	link.markSeen(time.Now())
	hub.links[link.id] = link
	manager := NewQuotaManager(store, hub, nil)
	manager.now = func() time.Time { return now }
	record := ProviderQuotaRecord{
		GitHubID: 91,
		Account: &gatewayv1.ProviderAccountPresence{
			Provider:   gatewayv1.ProviderQuotaProvider_PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX,
			AccountKey: "account_key_aaaaaaaaaaaaaaaaaaaa", Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
		},
		Sources: []ProviderQuotaSourceRecord{{
			DaemonID: link.id, RefreshSupported: true, Availability: gatewayv1.ProviderQuotaAvailability_PROVIDER_QUOTA_AVAILABILITY_AVAILABLE,
		}},
	}
	const idempotencyKey = "123e4567-e89b-42d3-a456-426614174000"
	accepted, err := manager.startReset(record, idempotencyKey)
	if err != nil || !accepted {
		t.Fatalf("start reset accepted=%t err=%v", accepted, err)
	}
	frame := <-link.quota
	request := frame.GetProviderQuotaResetRequest()
	if frame.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PROVIDER_QUOTA_RESET_REQUEST ||
		request.GetAccountKey() != record.Account.GetAccountKey() || request.GetIdempotencyKey() != idempotencyKey {
		t.Fatalf("reset frame = %#v", frame)
	}
}
