//go:build unix

package accounts

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/testkit"
)

func TestCleanupSignsOutRemovedAccountsOnEveryMachine(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	a := newHarness(t, "d_a")
	b := harnessOn(t, testkit.PeerStore(t, "d_b"), "d_b")
	host := filepath.Join(a.home, ".claude")
	writeFile(t, filepath.Join(host, "projects", "p", "s.jsonl"), "transcript")
	b.svc.opts.HostHome = a.home
	work := a.create(t, ProviderClaude, "Work", "")
	chat := a.create(t, ProviderChatGPT, "Chat", "")
	testkit.JoinPeers(t, a.store, b.store)
	signInWithFixture(t, a, work, "FIXTURE-CODE")
	signInWithFixture(t, b, work, "FIXTURE-CODE")
	signInWithFixture(t, a, chat, "")
	testkit.JoinPeers(t, b.store, a.store)
	must(t, a.svc.Delete(ctx, work.ID))
	must(t, a.svc.Delete(ctx, chat.ID))
	a.svc.cleanup(ctx)
	calls := strings.Join(a.fixture.Calls(), "\n")
	if !strings.Contains(calls, "SignOutClaude:"+a.svc.claudeDir(work.ID)) || !strings.Contains(calls, "SignOutCodex:"+a.svc.codexAuthDir(chat.ID)) {
		t.Fatalf("calls = %s", calls)
	}
	for _, id := range []string{work.ID, chat.ID} {
		if _, err := os.Lstat(a.svc.accountDir(id)); !os.IsNotExist(err) {
			t.Fatalf("account dir kept: %v", err)
		}
		if _, ok := a.login(t, id); ok {
			t.Fatal("own login record kept")
		}
	}
	if _, err := os.Stat(filepath.Join(host, "projects", "p", "s.jsonl")); err != nil {
		t.Fatalf("shared Claude data removed: %v", err)
	}
	audit, _ := os.ReadFile(a.svc.auditPath())
	if strings.Count(string(audit), `"action":"cleanup","outcome":"succeeded"`) != 2 {
		t.Fatalf("audit = %s", audit)
	}
	// The other machine cleans up its own login once it sees the tombstone.
	testkit.JoinPeers(t, a.store, b.store)
	b.svc.cleanup(ctx)
	if _, err := os.Lstat(b.svc.accountDir(work.ID)); !os.IsNotExist(err) {
		t.Fatalf("machine b kept the account: %v", err)
	}
	if _, ok := b.login(t, work.ID); ok {
		t.Fatal("machine b kept its login record")
	}
	// Nothing left to do: no further calls.
	before := len(a.fixture.Calls())
	a.svc.cleanup(ctx)
	if len(a.fixture.Calls()) != before {
		t.Fatal("cleanup repeated")
	}
}

// failingSignOut fails Claude sign-outs.
type failingSignOut struct{ *FixtureBackend }

func (failingSignOut) SignOutClaude(context.Context, string) error {
	return errors.New("keychain locked")
}

func TestCleanupRetriesFailedSignOuts(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	h := newHarness(t, "d_one")
	work := h.create(t, ProviderClaude, "Work", "")
	signInWithFixture(t, h, work, "FIXTURE-CODE")
	h.svc.backend = failingSignOut{h.fixture}
	must(t, h.svc.Delete(ctx, work.ID))
	for attempt := 1; attempt < cleanupRetries; attempt++ {
		h.svc.cleanup(ctx)
		if _, err := os.Stat(h.svc.accountDir(work.ID)); err != nil {
			t.Fatalf("attempt %d removed the directory before retrying: %v", attempt, err)
		}
	}
	h.svc.cleanup(ctx)
	if _, err := os.Stat(h.svc.accountDir(work.ID)); !os.IsNotExist(err) {
		t.Fatalf("directory kept after %d attempts: %v", cleanupRetries, err)
	}
	if audit, _ := os.ReadFile(h.svc.auditPath()); !strings.Contains(string(audit), `"outcome":"sign_out_failed"`) {
		t.Fatalf("audit = %s", audit)
	}
}

func TestAdoptionMatchesHostLoginsAndAPIKeys(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	a := newHarness(t, "d_a", withEnvironment(map[string]string{"CODEX_API_KEY": "sk-codex"}))
	b := harnessOn(t, testkit.PeerStore(t, "d_b"), "d_b")
	alice := Identity{Email: "alice@example.com", OrganizationID: "org_1", Plan: "max"}
	a.fixture.HostClaude, b.fixture.HostClaude = &alice, &alice
	a.fixture.ChatGPTIdentity.WorkspaceID = "ws-host"
	must(t, a.fixture.writeCodexAuth(filepath.Join(a.home, ".codex"), a.clock.Now()))
	a.svc.adopt(ctx)
	accounts, _ := a.svc.List(ctx, "")
	if len(accounts) != 3 {
		t.Fatalf("adopted = %+v", accounts)
	}
	byMethod := map[string]Account{}
	for _, account := range accounts {
		byMethod[account.Provider+"/"+account.Method] = account
	}
	claude := byMethod["claude/host"]
	if claude.Label != "alice@example.com" || claude.Identity.Email != "alice@example.com" || !claude.IsDefault || len(claude.Logins) != 1 || claude.Logins[0].State != StateSignedIn {
		t.Fatalf("claude host = %+v", claude)
	}
	if codex := byMethod["chatgpt/host"]; codex.Identity.WorkspaceID != "ws-host" || codex.Label != "fixture@example.com" {
		t.Fatalf("codex host = %+v", codex)
	}
	if env := byMethod["chatgpt/environment"]; env.Label != "OpenAI API key on d_a" || env.Identity.Subject != "environment:d_a:chatgpt" {
		t.Fatalf("environment = %+v", env)
	}
	// Adoption is idempotent.
	a.svc.adopt(ctx)
	if again, _ := a.svc.List(ctx, ""); len(again) != 3 {
		t.Fatalf("re-adoption created accounts: %d", len(again))
	}
	// Another machine with the same host login joins the same account.
	testkit.JoinPeers(t, a.store, b.store)
	b.svc.adopt(ctx)
	testkit.JoinPeers(t, b.store, a.store)
	shared := a.account(t, claude.ID)
	if len(shared.Logins) != 2 {
		t.Fatalf("logins = %+v", shared.Logins)
	}
	if list, _ := b.svc.List(ctx, ProviderClaude); len(list) != 1 {
		t.Fatalf("machine b created its own account: %+v", list)
	}
	// A removed host account stays hidden while the login is the same.
	must(t, a.svc.Delete(ctx, claude.ID))
	a.svc.adopt(ctx)
	if list, _ := a.svc.List(ctx, ProviderClaude); len(list) != 0 {
		t.Fatalf("removed account re-adopted: %+v", list)
	}
	// Cleanup never signs the host out.
	a.svc.cleanup(ctx)
	if strings.Contains(strings.Join(a.fixture.Calls(), "\n"), "SignOutClaude") {
		t.Fatal("host login signed out")
	}
	// A different host login is adopted as a new account.
	bob := Identity{Email: "bob@example.com", OrganizationID: "org_1"}
	a.fixture.HostClaude = &bob
	a.svc.adopt(ctx)
	if list, _ := a.svc.List(ctx, ProviderClaude); len(list) != 1 || list[0].Identity.Email != "bob@example.com" {
		t.Fatalf("new host login = %+v", list)
	}
}

func TestStatusChecksFollowTheProviderTools(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	h := newHarness(t, "d_one", withEnvironment(map[string]string{"ANTHROPIC_API_KEY": "sk-ant"}))
	work := h.create(t, ProviderClaude, "Work", "")
	signInWithFixture(t, h, work, "FIXTURE-CODE")
	alice := Identity{Email: "alice@example.com", OrganizationID: "org_1"}
	h.fixture.HostClaude = &alice
	h.svc.adopt(ctx)
	// Checks run only when due.
	h.svc.checkDue(ctx)
	first, _ := h.login(t, work.ID)
	h.clock.Advance(16 * time.Minute)
	// Claude Code lost its login meanwhile.
	must(t, os.Remove(filepath.Join(h.svc.claudeDir(work.ID), ".fixture-login.json")))
	// The host login now belongs to someone else.
	h.fixture.HostClaude = &Identity{Email: "mallory@example.com", OrganizationID: "org_9"}
	// The API key disappeared.
	delete(h.svc.opts.Environment, "ANTHROPIC_API_KEY")
	h.svc.checkDue(ctx)
	if record, _ := h.login(t, work.ID); record.State != StateSignedOut || record.VerifiedAt == first.VerifiedAt {
		t.Fatalf("managed = %+v", record)
	}
	accounts, _ := h.svc.List(ctx, ProviderClaude)
	for _, account := range accounts {
		state := account.Logins[0].State
		switch account.Method {
		case MethodHost:
			if state != StateSignedOut || account.Logins[0].ErrorCode != ErrorIdentityMismatch {
				t.Errorf("host = %+v", account.Logins[0])
			}
		case MethodEnvironment:
			if state != StateSignedOut {
				t.Errorf("environment = %+v", account.Logins[0])
			}
		}
	}
	// Check runs immediately on request.
	signInWithFixture(t, h, work, "FIXTURE-CODE")
	if account, err := h.svc.Check(ctx, work.ID); err != nil || account.Logins[0].State != StateSignedIn {
		t.Fatalf("check = %+v, %v", account, err)
	}
}

func TestRunDoesTheBackgroundWork(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	alice := Identity{Email: "alice@example.com", OrganizationID: "org_1"}
	h.fixture.HostClaude = &alice
	ctx, cancel := context.WithCancel(context.Background())
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		h.svc.Run(ctx)
	}()
	deadline := time.Now().Add(10 * time.Second)
	for {
		accounts, _ := h.svc.List(context.Background(), ProviderClaude)
		if len(accounts) == 1 && accounts[0].Usage != nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("Run did not adopt and probe: %+v", accounts)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := os.Stat(filepath.Join(h.svc.CodexHome(), "config.toml")); err != nil {
		t.Fatalf("Run did not render the Codex config: %v", err)
	}
	cancel()
	wg.Wait()
}
