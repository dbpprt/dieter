//go:build unix

package accounts

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/testkit"
)

func kindOf(err error) fault.Kind {
	kind, _ := fault.KindOf(err)
	return kind
}

func TestCreateAppliesMethodRulesAndDefaults(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	work := h.create(t, ProviderClaude, "  Work ", "")
	if work.Method != MethodClaudeCode || work.Label != "Work" || !work.IsDefault || !work.IncludeInSummary || work.CreatedBy != "d_one" || !schema.ValidProviderAccountID(work.ID) {
		t.Fatalf("work = %+v", work)
	}
	h.clock.Advance(time.Second)
	personal := h.create(t, ProviderClaude, "Personal", MethodClaudeCode)
	if personal.IsDefault {
		t.Fatal("second account became the default")
	}
	chat := h.create(t, ProviderChatGPT, "Chat", "")
	if chat.Method != MethodCodex || !chat.IsDefault {
		t.Fatalf("chat = %+v", chat)
	}
	for name, in := range map[string]CreateInput{
		"provider":    {Provider: "gemini", Label: "x"},
		"method":      {Provider: ProviderClaude, Label: "x", Method: MethodCodex},
		"siwc":        {Provider: ProviderClaude, Label: "x", Method: MethodSIWC},
		"host":        {Provider: ProviderClaude, Label: "x", Method: MethodHost},
		"environment": {Provider: ProviderChatGPT, Label: "x", Method: MethodEnvironment},
		"label":       {Provider: ProviderClaude, Label: " "},
		"multiline":   {Provider: ProviderClaude, Label: "a\nb"},
		"id":          {Provider: ProviderClaude, Label: "x", AccountID: "pa_nope"},
	} {
		if _, err := h.svc.Create(ctx, in); kindOf(err) != fault.Invalid {
			t.Errorf("%s: %v", name, err)
		}
	}
	siwc, err := h.svc.Create(ctx, CreateInput{Provider: ProviderChatGPT, Label: "Plan", Method: MethodSIWC})
	if err != nil || siwc.Method != MethodSIWC {
		t.Fatalf("siwc = %+v, %v", siwc, err)
	}
	list, err := h.svc.List(ctx, ProviderClaude)
	if err != nil || len(list) != 2 || list[0].ID != work.ID || list[1].ID != personal.ID {
		t.Fatalf("claude list = %+v, %v", list, err)
	}
	if all, _ := h.svc.List(ctx, ""); len(all) != 4 {
		t.Fatalf("all = %d", len(all))
	}
	if _, err := h.svc.List(ctx, "gemini"); kindOf(err) != fault.Invalid {
		t.Fatalf("unknown provider list = %v", err)
	}
}

func TestCreateWithAnIDIsIdempotent(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	id := newAccountID()
	first, err := h.svc.Create(ctx, CreateInput{Provider: ProviderClaude, Label: "Work", AccountID: id})
	if err != nil || first.ID != id {
		t.Fatalf("first = %+v, %v", first, err)
	}
	if again, err := h.svc.Create(ctx, CreateInput{Provider: ProviderClaude, Label: "Work", AccountID: id}); err != nil || again.ID != id {
		t.Fatalf("retry = %+v, %v", again, err)
	}
	if _, err := h.svc.Create(ctx, CreateInput{Provider: ProviderClaude, Label: "Other", AccountID: id}); kindOf(err) != fault.AlreadyExists {
		t.Fatalf("conflicting create = %v", err)
	}
	must(t, h.svc.Delete(ctx, id))
	if _, err := h.svc.Create(ctx, CreateInput{Provider: ProviderClaude, Label: "Work", AccountID: id}); kindOf(err) != fault.NotFound {
		t.Fatalf("create after delete = %v", err)
	}
}

func TestUpdateDeleteAndSetDefault(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	work := h.create(t, ProviderClaude, "Work", "")
	personal := h.create(t, ProviderClaude, "Personal", "")
	label, include := "Day job", false
	updated, err := h.svc.Update(ctx, work.ID, &label, &include, nil)
	if err != nil || updated.Label != "Day job" || updated.IncludeInSummary {
		t.Fatalf("update = %+v, %v", updated, err)
	}
	bad := "x\ny"
	if _, err := h.svc.Update(ctx, work.ID, &bad, nil, nil); kindOf(err) != fault.Invalid {
		t.Fatalf("bad label = %v", err)
	}
	if acct, err := h.svc.SetDefault(ctx, personal.ID); err != nil || !acct.IsDefault {
		t.Fatalf("set default = %+v, %v", acct, err)
	}
	if h.account(t, work.ID).IsDefault {
		t.Fatal("old default kept")
	}
	must(t, h.svc.Delete(ctx, personal.ID))
	if _, err := h.svc.get(personal.ID); kindOf(err) != fault.NotFound {
		t.Fatalf("deleted account = %v", err)
	}
	r, _ := h.svc.load()
	if _, ok := r.defaults[ProviderClaude]; ok {
		t.Fatal("default of a removed account kept")
	}
	if err := h.svc.Delete(ctx, personal.ID); kindOf(err) != fault.NotFound {
		t.Fatalf("second delete = %v", err)
	}
	if _, err := h.svc.Update(ctx, personal.ID, &label, nil, nil); kindOf(err) != fault.NotFound {
		t.Fatalf("update removed = %v", err)
	}
	if _, err := h.svc.SetDefault(ctx, personal.ID); kindOf(err) != fault.NotFound {
		t.Fatalf("default removed = %v", err)
	}
}

func TestAccountWritesNeedADaemonIdentity(t *testing.T) {
	t.Parallel()
	h := harnessOn(t, store.New(t.TempDir()), "")
	if _, err := h.svc.Create(context.Background(), CreateInput{Provider: ProviderClaude, Label: "Work"}); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("create while unenrolled = %v", err)
	}
	if list, err := h.svc.List(context.Background(), ""); err != nil || len(list) != 0 {
		t.Fatalf("list = %v, %v", list, err)
	}
	if _, err := h.store.Replica.PeerIdentity(); err == nil {
		t.Fatal("reading accounts created a replica identity")
	}
}

func TestIdentityBindsOnceByCompareAndSet(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	work := h.create(t, ProviderClaude, "Work", "")
	alice := Identity{Email: "Alice@Example.com", OrganizationID: "org_1", Plan: "max"}
	bound, err := h.svc.bindIdentity(work.ID, alice)
	if err != nil || bound.Email != "Alice@Example.com" {
		t.Fatalf("bind = %+v, %v", bound, err)
	}
	// The same person with a different email case and a new plan matches.
	if _, err := h.svc.bindIdentity(work.ID, Identity{Email: "alice@example.com", OrganizationID: "org_1", Plan: "pro"}); err != nil {
		t.Fatalf("rebind = %v", err)
	}
	var mismatch *mismatchError
	if _, err := h.svc.bindIdentity(work.ID, Identity{Email: "bob@example.com", OrganizationID: "org_1"}); !errors.As(err, &mismatch) || mismatch.Error() != "signed in as bob@example.com, this account is Alice@Example.com" {
		t.Fatalf("mismatch = %v", err)
	}
	if got := h.account(t, work.ID).Identity; got.Plan != "max" || got.Email != "Alice@Example.com" {
		t.Fatalf("identity changed: %+v", got)
	}
	if _, err := h.svc.bindIdentity(work.ID, Identity{Plan: "max"}); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("empty identity = %v", err)
	}
	chat := h.create(t, ProviderChatGPT, "Chat", "")
	if _, err := h.svc.bindIdentity(chat.ID, Identity{Email: "carol@example.com", WorkspaceID: "acct-1"}); err != nil {
		t.Fatal(err)
	}
	if _, err := h.svc.bindIdentity(chat.ID, Identity{Email: "carol@example.com", WorkspaceID: "acct-2"}); !errors.As(err, &mismatch) {
		t.Fatalf("other ChatGPT account = %v", err)
	}
}

func TestListJoinsLoginsAcrossMachines(t *testing.T) {
	t.Parallel()
	a := newHarness(t, "d_a")
	work := a.create(t, ProviderClaude, "Work", "")
	b := harnessOn(t, testkit.PeerStore(t, "d_b"), "d_b")
	testkit.JoinPeers(t, a.store, b.store)
	a.signIn(t, work.ID, MethodClaudeCode, Identity{Email: "alice@example.com"})
	b.signIn(t, work.ID, MethodClaudeCode, Identity{Email: "alice@example.com"})
	must(t, a.svc.updateLogin(work.ID, func(record *schema.ProviderLoginRecord, _ bool) bool {
		record.Usage = &Usage{ObservedAt: "2026-11-14T10:00:00Z", Windows: []UsageWindow{{Kind: "five_hour", UsedPercent: 10}}}
		record.DieterTokens = &TokenUsage{FiveHour: TokenTotals{Input: 1, Output: 2, Total: 3}, SevenDay: TokenTotals{Total: 10}, ObservedAt: "2026-11-14T10:00:00Z"}
		return true
	}))
	must(t, b.svc.updateLogin(work.ID, func(record *schema.ProviderLoginRecord, _ bool) bool {
		record.Usage = &Usage{ObservedAt: "2026-11-14T10:05:00Z", Windows: []UsageWindow{{Kind: "five_hour", UsedPercent: 25}}}
		record.DieterTokens = &TokenUsage{FiveHour: TokenTotals{Input: 10, Output: 20, Total: 30}, SevenDay: TokenTotals{Total: 5}, ObservedAt: "2026-11-14T10:05:00Z"}
		return true
	}))
	testkit.JoinPeers(t, b.store, a.store)
	account := a.account(t, work.ID)
	if len(account.Logins) != 2 || account.Logins[0].DaemonID != "d_a" || account.Logins[1].DaemonID != "d_b" {
		t.Fatalf("logins = %+v", account.Logins)
	}
	if account.Usage == nil || account.Usage.Windows[0].UsedPercent != 25 {
		t.Fatalf("freshest usage = %+v", account.Usage)
	}
	if tokens := account.DieterTokens; tokens == nil || tokens.FiveHour.Total != 33 || tokens.SevenDay.Total != 15 || tokens.ObservedAt != "2026-11-14T10:05:00Z" {
		t.Fatalf("tokens = %+v", tokens)
	}
	// A daemon that left the roster no longer counts.
	a.svc.opts.Roster = func() map[string]bool { return map[string]bool{"d_a": true} }
	if account := a.account(t, work.ID); len(account.Logins) != 1 || account.Usage.Windows[0].UsedPercent != 10 {
		t.Fatalf("roster filter = %+v", account)
	}
}
