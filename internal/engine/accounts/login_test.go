//go:build unix

package accounts

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

func TestClaudePasteCodeSignInBindsIdentity(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	work := h.create(t, ProviderClaude, "Work", "")
	login, err := h.svc.StartLogin(ctx, work.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if login.Phase != PhaseWaiting || login.Flow != FlowPasteCode || login.Challenge.Expects != ExpectsCode || !strings.HasPrefix(login.Challenge.OpenURL, "https://claude.ai/") || login.Challenge.CallbackPort == 0 || login.DaemonID != "d_one" {
		t.Fatalf("login = %+v", login)
	}
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "", ""); kindOf(err) != fault.Invalid {
		t.Fatalf("empty input = %v", err)
	}
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "a", "http://localhost:1/callback"); kindOf(err) != fault.Invalid {
		t.Fatalf("both inputs = %v", err)
	}
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "FIXTURE-CODE#state", ""); err != nil {
		t.Fatal(err)
	}
	final := waitLogin(t, h.svc, login.ID)
	if final.Phase != PhaseSucceeded || final.Identity.Email != "fixture@example.com" {
		t.Fatalf("final = %+v", final)
	}
	account := h.account(t, work.ID)
	if account.Identity.Email != "fixture@example.com" || account.Identity.OrganizationID != "org_fixture" {
		t.Fatalf("identity = %+v", account.Identity)
	}
	record, ok := h.login(t, work.ID)
	if !ok || record.State != StateSignedIn || record.Method != MethodClaudeCode || record.VerifiedAt == "" || record.Identity.Plan != "max" {
		t.Fatalf("login record = %+v", record)
	}
	if _, err := os.Stat(filepath.Join(h.svc.accountDir(work.ID), "session")); !os.IsNotExist(err) {
		t.Fatalf("session scratch kept: %v", err)
	}
	audit, _ := os.ReadFile(h.svc.auditPath())
	if !strings.Contains(string(audit), `"action":"sign_in","outcome":"succeeded"`) || strings.Contains(string(audit), "FIXTURE-CODE") {
		t.Fatalf("audit = %s", audit)
	}
	// A late submission is refused.
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "FIXTURE-CODE", ""); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("late input = %v", err)
	}
}

func TestSignInAsSomeoneElseIsSignedOut(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	work := h.create(t, ProviderClaude, "Work", "")
	if _, err := h.svc.bindIdentity(work.ID, Identity{Email: "alice@example.com", OrganizationID: "org_fixture"}); err != nil {
		t.Fatal(err)
	}
	login, err := h.svc.StartLogin(ctx, work.ID, FlowPasteCode)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "FIXTURE-CODE#bob@example.com", ""); err != nil {
		t.Fatal(err)
	}
	final := waitLogin(t, h.svc, login.ID)
	if final.Phase != PhaseFailed || final.ErrorCode != ErrorIdentityMismatch || !strings.Contains(final.ErrorMessage, "signed in as bob@example.com, this account is alice@example.com") {
		t.Fatalf("final = %+v", final)
	}
	record, _ := h.login(t, work.ID)
	if record.State != StateFailed || record.Error == nil || record.Error.Code != ErrorIdentityMismatch {
		t.Fatalf("record = %+v", record)
	}
	calls := strings.Join(h.fixture.Calls(), "\n")
	if !strings.Contains(calls, "SignOutClaude:"+h.svc.claudeDir(work.ID)) {
		t.Fatalf("not signed out: %s", calls)
	}
	if h.account(t, work.ID).Identity.Email != "alice@example.com" {
		t.Fatal("identity rebound")
	}
}

func TestCodexDeviceCodeApprovesOnItsOwn(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	chat := h.create(t, ProviderChatGPT, "Chat", "")
	login, err := h.svc.StartLogin(ctx, chat.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if login.Flow != FlowDeviceCode || login.Challenge.UserCode != "FIXT-12345" || login.Challenge.Expects != ExpectsNone || login.Challenge.ExpiresAt == "" {
		t.Fatalf("login = %+v", login)
	}
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "FIXT-12345", ""); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("code for a device sign-in = %v", err)
	}
	final := waitLogin(t, h.svc, login.ID)
	if final.Phase != PhaseSucceeded || final.Identity.WorkspaceID != "fixture-workspace" {
		t.Fatalf("final = %+v", final)
	}
	if _, err := os.Stat(filepath.Join(h.svc.codexAuthDir(chat.ID), "auth.json")); err != nil {
		t.Fatalf("auth home: %v", err)
	}
	if got := h.account(t, chat.ID).Identity.WorkspaceID; got != "fixture-workspace" {
		t.Fatalf("bound = %q", got)
	}
}

func TestFlowsAreCheckedPerMethod(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	work := h.create(t, ProviderClaude, "Work", "")
	chat := h.create(t, ProviderChatGPT, "Chat", "")
	if _, err := h.svc.StartLogin(ctx, work.ID, FlowDeviceCode); kindOf(err) != fault.Invalid {
		t.Fatalf("claude device = %v", err)
	}
	if _, err := h.svc.StartLogin(ctx, chat.ID, FlowPasteCode); kindOf(err) != fault.Invalid {
		t.Fatalf("codex paste = %v", err)
	}
	if _, err := h.svc.StartLogin(ctx, "pa_abcdefghijklmnopqrstuvwxyz", ""); kindOf(err) != fault.NotFound {
		t.Fatalf("missing account = %v", err)
	}
	if err := h.svc.WatchLogin(ctx, "pl_missing", func(Login) error { return nil }); kindOf(err) != fault.NotFound {
		t.Fatalf("missing login = %v", err)
	}
}

func TestSessionLimits(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	var ids []string
	for i := 0; i < 5; i++ {
		ids = append(ids, h.create(t, ProviderClaude, "Account "+string(rune('A'+i)), "").ID)
	}
	first, err := h.svc.StartLogin(ctx, ids[0], "")
	if err != nil {
		t.Fatal(err)
	}
	// A new sign-in of the same account replaces the running one.
	second, err := h.svc.StartLogin(ctx, ids[0], "")
	if err != nil {
		t.Fatal(err)
	}
	if replaced := waitLogin(t, h.svc, first.ID); replaced.Phase != PhaseCanceled {
		t.Fatalf("replaced = %+v", replaced)
	}
	for _, id := range ids[1:4] {
		if _, err := h.svc.StartLogin(ctx, id, ""); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := h.svc.StartLogin(ctx, ids[4], ""); kindOf(err) != fault.ResourceExhausted {
		t.Fatalf("fifth sign-in = %v", err)
	}
	canceled, err := h.svc.CancelLogin(ctx, second.ID)
	if err != nil || canceled.Phase != PhaseCanceled {
		t.Fatalf("cancel = %+v, %v", canceled, err)
	}
	if _, err := h.svc.StartLogin(ctx, ids[4], ""); err != nil {
		t.Fatalf("sign-in after a cancel = %v", err)
	}
}

func TestOneCodexBrowserSignInPerHost(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	a := h.create(t, ProviderChatGPT, "A", "")
	b := h.create(t, ProviderChatGPT, "B", "")
	login, err := h.svc.StartLogin(ctx, a.ID, FlowBrowser)
	if err != nil {
		t.Fatal(err)
	}
	if login.Challenge.CallbackPort != 1455 || login.Challenge.Expects != ExpectsCallback {
		t.Fatalf("browser login = %+v", login)
	}
	if _, err := h.svc.StartLogin(ctx, b.ID, FlowBrowser); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("second browser sign-in = %v", err)
	}
	if _, err := h.svc.StartLogin(ctx, b.ID, FlowDeviceCode); err != nil {
		t.Fatalf("device code beside a browser sign-in = %v", err)
	}
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "", "http://127.0.0.1:1455/elsewhere?code=fixture"); kindOf(err) != fault.Invalid {
		t.Fatalf("wrong path = %v", err)
	}
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "", "https://evil.example/auth/callback?code=fixture"); kindOf(err) != fault.Invalid {
		t.Fatalf("remote address = %v", err)
	}
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "", "http://localhost:1455/auth/callback?code=fixture&state=x"); err != nil {
		t.Fatal(err)
	}
	if final := waitLogin(t, h.svc, login.ID); final.Phase != PhaseSucceeded {
		t.Fatalf("final = %+v", final)
	}
}

func TestShutdownCancelsSignIns(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	work := h.create(t, ProviderClaude, "Work", "")
	login, err := h.svc.StartLogin(ctx, work.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan Login, 1)
	go func() { done <- waitLogin(t, h.svc, login.ID) }()
	time.Sleep(20 * time.Millisecond)
	h.svc.Shutdown()
	select {
	case final := <-done:
		if final.Phase != PhaseCanceled {
			t.Fatalf("final = %+v", final)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("watch did not end")
	}
	if _, err := h.svc.StartLogin(ctx, work.ID, ""); kindOf(err) != fault.Unavailable {
		t.Fatalf("sign-in after shutdown = %v", err)
	}
}

func TestSignOutOfManagedAndHostAccounts(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	work := h.create(t, ProviderClaude, "Work", "")
	login, _ := h.svc.StartLogin(ctx, work.ID, "")
	if _, err := h.svc.SubmitLoginInput(ctx, login.ID, "FIXTURE-CODE", ""); err != nil {
		t.Fatal(err)
	}
	waitLogin(t, h.svc, login.ID)
	account, err := h.svc.SignOut(ctx, work.ID)
	if err != nil || account.Logins[0].State != StateSignedOut {
		t.Fatalf("sign out = %+v, %v", account, err)
	}
	if status, _ := h.fixture.CheckClaude(ctx, h.svc.claudeDir(work.ID)); status.LoggedIn {
		t.Fatal("credential kept")
	}
	h.fixture.HostClaude = &Identity{Email: "host@example.com", OrganizationID: "org_h"}
	h.svc.adopt(ctx)
	list, _ := h.svc.List(ctx, ProviderClaude)
	var host Account
	for _, a := range list {
		if a.Method == MethodHost {
			host = a
		}
	}
	if _, err := h.svc.SignOut(ctx, host.ID); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("host sign-out = %v", err)
	}
}
