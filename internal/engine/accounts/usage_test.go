//go:build unix

package accounts

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestProbesAreDedupedAcrossMachines(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	a := newHarness(t, "d_a")
	b := harnessOn(t, testkit.PeerStore(t, "d_b"), "d_b")
	b.clock.Advance(0)
	work := a.create(t, ProviderClaude, "Work", "")
	testkit.JoinPeers(t, a.store, b.store)
	signInWithFixture(t, a, work, "FIXTURE-CODE")
	signInWithFixture(t, b, work, "FIXTURE-CODE")
	a.svc.probeDue(ctx)
	record, _ := a.login(t, work.ID)
	if record.Usage == nil || record.Usage.Source != "probe" || record.Usage.Plan != "max" || len(record.Usage.Windows) != 2 || record.Usage.Windows[0].UsedPercent != 20 {
		t.Fatalf("usage = %+v", record.Usage)
	}
	testkit.JoinPeers(t, a.store, b.store)
	b.svc.probeDue(ctx)
	if record, _ := b.login(t, work.ID); record.Usage != nil {
		t.Fatalf("machine b probed although a's usage is fresh: %+v", record.Usage)
	}
	// Once a's usage ages past the interval, b probes.
	b.clock.Advance(6 * time.Minute)
	b.svc.probeDue(ctx)
	if record, _ := b.login(t, work.ID); record.Usage == nil {
		t.Fatal("machine b never probed")
	}
	// The next probe is scheduled; an immediate pass does not probe again.
	calls := len(b.fixture.Calls())
	b.svc.probeDue(ctx)
	if len(b.fixture.Calls()) != calls {
		t.Fatal("probed twice in one interval")
	}
}

func TestUsageWritesOnlyOnMaterialChange(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	work := h.create(t, ProviderClaude, "Work", "")
	signInWithFixture(t, h, work, "FIXTURE-CODE")
	usage := Usage{Plan: "max", Windows: []UsageWindow{{Kind: "five_hour", Label: "5h", UsedPercent: 10.04, ResetsAt: "2026-11-14T12:00:00Z"}}}
	must(t, h.svc.writeUsage(work.ID, usage, "probe", false))
	first, _ := h.login(t, work.ID)
	h.clock.Advance(time.Minute)
	usage.Windows[0].UsedPercent = 10.6
	must(t, h.svc.writeUsage(work.ID, usage, "probe", false))
	if record, _ := h.login(t, work.ID); record.Usage.ObservedAt != first.Usage.ObservedAt {
		t.Fatal("a sub-point move was written")
	}
	usage.Windows[0].UsedPercent = 11.2
	must(t, h.svc.writeUsage(work.ID, usage, "probe", false))
	if record, _ := h.login(t, work.ID); record.Usage.Windows[0].UsedPercent != 11.2 {
		t.Fatalf("a one-point move was not written: %+v", record.Usage)
	}
	second, _ := h.login(t, work.ID)
	h.clock.Advance(16 * time.Minute)
	must(t, h.svc.writeUsage(work.ID, usage, "probe", false))
	if record, _ := h.login(t, work.ID); record.Usage.ObservedAt == second.Usage.ObservedAt {
		t.Fatal("usage not refreshed after 15 minutes")
	}
	usage.Windows[0].ResetsAt = "2026-11-14T17:00:00Z"
	if !materialChange(*second.Usage, normalizeUsage(usage)) {
		t.Fatal("a new reset time is not material")
	}
	// Out-of-range values are clamped to the schema.
	normalized := normalizeUsage(Usage{Windows: []UsageWindow{{Kind: "daily", UsedPercent: 140}}, Unavailable: "broken"})
	if normalized.Windows[0].Kind != "other" || normalized.Windows[0].UsedPercent != 100 || normalized.Unavailable != "unsupported" {
		t.Fatalf("normalized = %+v", normalized)
	}
}

func TestObservedUsageIsThrottledAndMerged(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	work := h.create(t, ProviderClaude, "Work", "")
	signInWithFixture(t, h, work, "FIXTURE-CODE")
	h.svc.probeDue(context.Background())
	// A Claude SDK rate_limit_event: utilization is a fraction.
	event := json.RawMessage(`{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","utilization":0.5,"resetsAt":1794661675}}`)
	h.svc.observeUsage(work.ID, event)
	record, _ := h.login(t, work.ID)
	if record.Usage.Source != "turn" || len(record.Usage.Windows) != 2 || record.Usage.Windows[0].UsedPercent != 50 || record.Usage.Windows[1].UsedPercent != 40 {
		t.Fatalf("merged usage = %+v", record.Usage)
	}
	// Within a minute only the pending observation changes.
	h.svc.observeUsage(work.ID, json.RawMessage(`{"rateLimitType":"seven_day","utilization":0.9}`))
	if record, _ := h.login(t, work.ID); record.Usage.Windows[1].UsedPercent != 40 {
		t.Fatalf("throttle broken: %+v", record.Usage)
	}
	h.clock.Advance(61 * time.Second)
	h.svc.flushObserved()
	if record, _ := h.login(t, work.ID); record.Usage.Windows[1].UsedPercent != 90 || record.Usage.Windows[0].UsedPercent != 50 {
		t.Fatalf("flushed usage = %+v", record.Usage)
	}
	// Codex snapshots and normalized usage are accepted too; junk is not.
	for _, data := range []string{
		`{"rateLimits":{"planType":"plus","primary":{"usedPercent":12,"windowDurationMins":300}}}`,
		`{"primary":{"usedPercent":12,"windowDurationMins":300}}`,
		`{"windows":[{"kind":"weekly","label":"Weekly","usedPercent":3}]}`,
	} {
		if usage, ok := parseObservedUsage(json.RawMessage(data)); !ok || len(usage.Windows) != 1 {
			t.Errorf("%s = %+v, %v", data, usage, ok)
		}
	}
	for _, data := range []string{`[]`, `{"type":"other"}`, `{"rateLimitType":"overage","utilization":1}`} {
		if _, ok := parseObservedUsage(json.RawMessage(data)); ok {
			t.Errorf("%s accepted", data)
		}
	}
}

func TestTokenLedgerSumsAndPrunes(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	work := h.create(t, ProviderClaude, "Work", "")
	signInWithFixture(t, h, work, "FIXTURE-CODE")
	now := h.clock.Now()
	h.svc.recordTurnTokens(work.ID, now.Add(-9*24*time.Hour), 1000, 1000, 2000)
	h.svc.recordTurnTokens(work.ID, now.Add(-2*24*time.Hour), 100, 50, 150)
	h.svc.recordTurnTokens(work.ID, now.Add(-time.Hour), 10, 5, 0)
	h.svc.recordTurnTokens(work.ID, now, 0, 0, 0)
	record, _ := h.login(t, work.ID)
	tokens := record.DieterTokens
	if tokens == nil || tokens.FiveHour != (TokenTotals{Input: 10, Output: 5, Total: 15}) || tokens.SevenDay != (TokenTotals{Input: 110, Output: 55, Total: 165}) {
		t.Fatalf("tokens = %+v", tokens)
	}
	entries, _ := h.svc.readLedger()
	if len(entries) != 2 {
		t.Fatalf("ledger kept %d entries; the 9-day-old one should be pruned", len(entries))
	}
	info, _ := os.Stat(h.svc.ledgerPath())
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("ledger mode = %v", info.Mode())
	}
	// As turns age out of the window the sweep updates the sums.
	h.clock.Advance(6 * time.Hour)
	h.svc.sweepTokens()
	if record, _ := h.login(t, work.ID); record.DieterTokens.FiveHour != (TokenTotals{}) || record.DieterTokens.SevenDay.Total != 165 {
		t.Fatalf("swept = %+v", record.DieterTokens)
	}
}

func TestRefreshUsageAndResetCredits(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	chat := h.create(t, ProviderChatGPT, "Chat", "")
	work := h.create(t, ProviderClaude, "Work", "")
	if _, err := h.svc.RefreshUsage(ctx, chat.ID); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("refresh while signed out = %v", err)
	}
	signInWithFixture(t, h, chat, "")
	signInWithFixture(t, h, work, "FIXTURE-CODE")
	account, err := h.svc.RefreshUsage(ctx, chat.ID)
	if err != nil || account.Usage == nil || account.Usage.ResetCredits.Available != 1 || account.Usage.Windows[0].UsedPercent != 15 {
		t.Fatalf("refresh = %+v, %v", account.Usage, err)
	}
	if _, _, err := h.svc.ConsumeReset(ctx, chat.ID, "not-a-uuid", ""); kindOf(err) != fault.Invalid {
		t.Fatalf("bad key = %v", err)
	}
	if _, _, err := h.svc.ConsumeReset(ctx, work.ID, "00000000-0000-4000-8000-000000000002", ""); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("claude reset = %v", err)
	}
	outcome, account, err := h.svc.ConsumeReset(ctx, chat.ID, "00000000-0000-4000-8000-000000000002", "")
	if err != nil || outcome != "reset" || account.Usage.ResetCredits.Available != 0 || account.Usage.Windows[0].UsedPercent != 0 {
		t.Fatalf("reset = %q %+v, %v", outcome, account.Usage, err)
	}
	if outcome, _, _ := h.svc.ConsumeReset(ctx, chat.ID, "00000000-0000-4000-8000-000000000002", ""); outcome != "alreadyRedeemed" {
		t.Fatalf("repeat = %q", outcome)
	}
	audit, _ := os.ReadFile(h.svc.auditPath())
	if !strings.Contains(string(audit), `"action":"reset","outcome":"reset"`) {
		t.Fatalf("audit = %s", audit)
	}
	// A second refresh within 30 seconds does not probe.
	if _, err := h.svc.RefreshUsage(ctx, work.ID); err != nil {
		t.Fatal(err)
	}
	calls := len(h.fixture.Calls())
	if account, err := h.svc.RefreshUsage(ctx, work.ID); err != nil || account.Usage == nil || len(h.fixture.Calls()) != calls {
		t.Fatalf("refresh floor broken: %+v, %v, calls %v", account.Usage, err, h.fixture.Calls()[calls:])
	}
	h.clock.Advance(31 * time.Second)
	if _, err := h.svc.RefreshUsage(ctx, work.ID); err != nil || len(h.fixture.Calls()) != calls+1 {
		t.Fatalf("refresh after the floor = %v, calls %v", err, h.fixture.Calls()[calls:])
	}
}

func TestTurnNotificationsRunInTheBackground(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	work := h.create(t, ProviderClaude, "Work", "")
	signInWithFixture(t, h, work, "FIXTURE-CODE")
	// The caller may hold the store's writer lock: notifications must not wait
	// for it.
	release, err := h.store.BeginWriteLock()
	if err != nil {
		t.Fatal(err)
	}
	h.svc.RecordTurnTokens(work.ID, h.clock.Now(), 3, 4, 7)
	h.svc.ObserveUsage(work.ID, json.RawMessage(`{"rateLimitType":"five_hour","utilization":0.25}`))
	h.svc.MarkExpired(work.ID, "HTTP 401")
	release()
	// Shutdown waits for the background writes.
	h.svc.Shutdown()
	record, _ := h.login(t, work.ID)
	if record.State != StateExpired || record.DieterTokens == nil || record.DieterTokens.FiveHour.Total != 7 {
		t.Fatalf("record = %+v", record)
	}
	// After shutdown, notifications are dropped.
	h.svc.MarkExpired(work.ID, "late")
}
