package main

import (
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/engine/accounts"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/testkit"
)

// The seeded accounts are what client and Maestro flows rely on: "Work"
// signed in on the primary only, "Personal" on both machines with a reset
// credit, a default per provider, and seeding a restarted fixture changes
// nothing. JoinPeers stands in for peer sync here; the topology e2e covers
// the real one.
func TestFixtureSeedsProviderAccountsIdempotently(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	primary, second := testkit.PeerStore(t, "dm_fixture_primary"), testkit.PeerStore(t, "dm_fixture_second")
	fixtures := newFixtureProviderAccounts(slog.New(slog.NewTextHandler(io.Discard, nil)), t.TempDir())
	t.Cleanup(fixtures.shutdown)
	a, b := fixtures.forStore(primary, nil), fixtures.forStore(second, nil)
	if fixtures.forStore(primary, nil) != a {
		t.Fatal("a restarted daemon API got a second accounts engine")
	}

	if err := seedPrimaryProviderAccounts(ctx, a, primary); err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, primary, second)
	if err := signInFixtureAccounts(ctx, b, second, fixturePersonal); err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, second, primary)

	values, err := a.List(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	byLabel := map[string]accounts.Account{}
	for _, value := range values {
		byLabel[value.Label] = value
	}
	work, personal := byLabel["Work"], byLabel["Personal"]
	if len(values) != 2 || work.ID != fixtureWorkAccount || personal.ID != fixturePersonalAccount {
		t.Fatalf("accounts = %+v", values)
	}
	if work.Provider != accounts.ProviderClaude || work.Method != accounts.MethodClaudeCode || !work.IsDefault ||
		personal.Provider != accounts.ProviderChatGPT || personal.Method != accounts.MethodCodex || !personal.IsDefault {
		t.Fatalf("seeded records: work=%+v personal=%+v", work, personal)
	}
	if states := loginStates(work); states != "dm_fixture_primary=signed_in" {
		t.Fatalf("Work logins = %s", states)
	}
	if states := loginStates(personal); states != "dm_fixture_primary=signed_in,dm_fixture_second=signed_in" {
		t.Fatalf("Personal logins = %s", states)
	}
	if work.Identity.Email == "" || personal.Identity.WorkspaceID == "" {
		t.Fatalf("the first sign-ins did not bind identities: %+v %+v", work.Identity, personal.Identity)
	}
	if usage := work.Usage; usage == nil || len(usage.Windows) != 2 || usage.Windows[0].Kind != "five_hour" || usage.Windows[0].UsedPercent != 38 ||
		usage.Windows[1].Kind != "weekly" || usage.Windows[1].UsedPercent != 12 || usage.Plan != "max" {
		t.Fatalf("Work usage = %+v", work.Usage)
	}
	if usage := personal.Usage; usage == nil || usage.ResetCredits == nil || usage.ResetCredits.Available != 1 || len(usage.Windows) != 2 {
		t.Fatalf("Personal usage = %+v", personal.Usage)
	}

	// Turns resolve the seeded accounts: the second machine has no Work login.
	if auth, err := a.ResolveTurn(ctx, "claude-code", ""); err != nil || auth.AccountID != fixtureWorkAccount || auth.Env["CLAUDE_CONFIG_DIR"] == "" {
		t.Fatalf("primary Claude turn = %+v, %v", auth, err)
	}
	if auth, err := b.ResolveTurn(ctx, "codex", ""); err != nil || auth.AccountID != fixturePersonalAccount || auth.Auth["CODEX_API_KEY"] == "" {
		t.Fatalf("second Codex turn = %+v, %v", auth, err)
	}
	if _, err := b.ResolveTurn(ctx, "claude-code", ""); !isFaultKind(err, fault.FailedPrecondition) || !strings.Contains(err.Error(), "Work") {
		t.Fatalf("second Claude turn: %v, want Work not signed in", err)
	}

	// A restart seeds again: no new sign-in, the same records, and an account a
	// test renamed keeps its name.
	time.Sleep(1100 * time.Millisecond)
	renamed := "Day job"
	if _, err := a.Update(ctx, fixtureWorkAccount, &renamed, nil); err != nil {
		t.Fatal(err)
	}
	if err := seedPrimaryProviderAccounts(ctx, a, primary); err != nil {
		t.Fatal(err)
	}
	again, err := a.List(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(again) != 2 {
		t.Fatalf("reseeding added accounts: %+v", again)
	}
	for _, value := range again {
		if value.ID == fixtureWorkAccount && value.Label != renamed {
			t.Fatalf("reseeding renamed Work back: %+v", value)
		}
		for _, login := range value.Logins {
			if login.DaemonID == "dm_fixture_primary" && login.VerifiedAt != verifiedAt(values, value.ID, login.DaemonID) {
				t.Fatalf("reseeding signed %s in again: %s", value.Label, login.VerifiedAt)
			}
		}
	}

	// A removed account stays removed.
	if err := a.Delete(ctx, fixturePersonalAccount); err != nil {
		t.Fatal(err)
	}
	if err := seedPrimaryProviderAccounts(ctx, a, primary); err != nil {
		t.Fatal(err)
	}
	if values, err := a.List(ctx, accounts.ProviderChatGPT); err != nil || len(values) != 0 {
		t.Fatalf("reseeding restored a removed account: %+v, %v", values, err)
	}
}

func loginStates(account accounts.Account) string {
	var states []string
	for _, login := range account.Logins {
		states = append(states, login.DaemonID+"="+login.State)
	}
	return strings.Join(states, ",")
}

func verifiedAt(values []accounts.Account, accountID, daemonID string) string {
	for _, value := range values {
		for _, login := range value.Logins {
			if value.ID == accountID && login.DaemonID == daemonID {
				return login.VerifiedAt
			}
		}
	}
	return ""
}

func isFaultKind(err error, kind fault.Kind) bool {
	got, ok := fault.KindOf(err)
	return ok && got == kind
}
