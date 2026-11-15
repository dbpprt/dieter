//go:build unix

package accounts

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

func signInWithFixture(t *testing.T, h *harness, account Account, input string) {
	t.Helper()
	ctx := context.Background()
	login, err := h.svc.StartLogin(ctx, account.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if input != "" {
		code, callback := input, ""
		if strings.HasPrefix(input, "http") {
			code, callback = "", input
		}
		if _, err := h.svc.SubmitLoginInput(ctx, login.ID, code, callback); err != nil {
			t.Fatal(err)
		}
	}
	if final := waitLogin(t, h.svc, login.ID); final.Phase != PhaseSucceeded {
		t.Fatalf("sign-in = %+v", final)
	}
}

func TestResolveTurnForEveryMethod(t *testing.T) {
	t.Parallel()
	env := map[string]string{"ANTHROPIC_API_KEY": "sk-ant", "OPENAI_API_KEY": "sk-openai", "OPENAI_BASE_URL": "https://proxy.example/v1"}
	h := newHarness(t, "d_one", withEnvironment(env))
	ctx := context.Background()
	writeFile(t, filepath.Join(h.home, ".claude.json"), `{"mcpServers":{"docs":{"command":"docs"}}}`)
	work := h.create(t, ProviderClaude, "Work", "")
	signInWithFixture(t, h, work, "FIXTURE-CODE")
	chat := h.create(t, ProviderChatGPT, "Chat", "")
	signInWithFixture(t, h, chat, "")
	plan := h.create(t, ProviderChatGPT, "Plan", MethodSIWC)
	signInWithFixture(t, h, plan, "http://127.0.0.1:1456/auth/callback?code=fixture")
	h.fixture.HostClaude = &Identity{Email: "host@example.com", OrganizationID: "org_h"}
	h.fixture.ChatGPTIdentity = Identity{Email: "host@example.com", WorkspaceID: "ws-host", Plan: "plus"}
	must(t, h.fixture.writeCodexAuth(filepath.Join(h.home, ".codex"), h.clock.Now()))
	h.svc.adopt(ctx)
	accounts, _ := h.svc.List(ctx, "")
	byMethod := map[string]Account{}
	for _, account := range accounts {
		byMethod[account.Provider+"/"+account.Method] = account
	}
	if len(byMethod) != 7 {
		t.Fatalf("accounts = %v", byMethod)
	}

	auth, err := h.svc.ResolveTurn(ctx, "claude-code", work.ID)
	if err != nil {
		t.Fatal(err)
	}
	dir := h.svc.claudeDir(work.ID)
	if auth.AccountID != work.ID || auth.Env["CLAUDE_CONFIG_DIR"] != dir || len(auth.Auth) != 0 || auth.Auth == nil {
		t.Fatalf("claude-code = %+v", auth)
	}
	for _, key := range []string{"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"} {
		if value, ok := auth.Env[key]; !ok || value != "" {
			t.Errorf("%s not masked: %+v", key, auth.Env)
		}
	}
	if raw, _ := os.ReadFile(filepath.Join(dir, ".claude.json")); !strings.Contains(string(raw), "docs") {
		t.Fatalf("mcpServers not mirrored before the turn: %s", raw)
	}

	auth, err = h.svc.ResolveTurn(ctx, "claude-code", byMethod["claude/host"].ID)
	if err != nil || auth.Env["CLAUDE_CONFIG_DIR"] != "" || len(auth.Env) != 3 || auth.Auth == nil || len(auth.Auth) != 0 {
		t.Fatalf("claude host = %+v, %v", auth, err)
	}
	if _, ok := auth.Env["CLAUDE_CONFIG_DIR"]; ok {
		t.Fatal("host turn sets CLAUDE_CONFIG_DIR")
	}

	auth, err = h.svc.ResolveTurn(ctx, "claude-code", byMethod["claude/environment"].ID)
	if err != nil || auth.Env != nil || auth.Auth["ANTHROPIC_API_KEY"] != "sk-ant" {
		t.Fatalf("claude environment = %+v, %v", auth, err)
	}

	auth, err = h.svc.ResolveTurn(ctx, "codex", chat.ID)
	if err != nil || auth.Env["CODEX_HOME"] != h.svc.CodexHome() || auth.Auth["OPENAI_BASE_URL"] != chatGPTCodexBaseURL || auth.Auth["CODEX_API_KEY"] == "" {
		t.Fatalf("codex = %+v, %v", auth, err)
	}
	managed, _ := readCodexAuth(h.svc.codexAuthDir(chat.ID))
	if auth.Auth["CODEX_API_KEY"] != managed.AccessToken {
		t.Fatal("codex token is not the account's")
	}
	if raw, err := os.ReadFile(filepath.Join(h.svc.CodexHome(), "config.toml")); err != nil || !strings.Contains(string(raw), "agent_bridge_openai") {
		t.Fatalf("codex config not rendered: %v", err)
	}

	auth, err = h.svc.ResolveTurn(ctx, "codex", byMethod["chatgpt/host"].ID)
	host, _ := readCodexAuth(filepath.Join(h.home, ".codex"))
	if err != nil || auth.Auth["CODEX_API_KEY"] != host.AccessToken || auth.Auth["OPENAI_BASE_URL"] != chatGPTCodexBaseURL {
		t.Fatalf("codex host = %+v, %v", auth, err)
	}

	auth, err = h.svc.ResolveTurn(ctx, "codex", plan.ID)
	if err != nil || auth.Auth["OPENAI_BASE_URL"] != openAIAPIBaseURL || auth.Auth["CODEX_API_KEY"] == "" {
		t.Fatalf("siwc = %+v, %v", auth, err)
	}

	auth, err = h.svc.ResolveTurn(ctx, "codex", byMethod["chatgpt/environment"].ID)
	if err != nil || auth.Auth["CODEX_API_KEY"] != "sk-openai" || auth.Auth["OPENAI_BASE_URL"] != "https://proxy.example/v1" || auth.Env["CODEX_HOME"] != h.svc.CodexHome() {
		t.Fatalf("codex environment = %+v, %v", auth, err)
	}

	if _, err := h.svc.ResolveTurn(ctx, "codex", work.ID); kindOf(err) != fault.Invalid {
		t.Fatalf("claude account for codex = %v", err)
	}
	if auth, err := h.svc.ResolveTurn(ctx, "omp", ""); err != nil || auth.AccountID != "" || auth.Env != nil {
		t.Fatalf("omp = %+v, %v", auth, err)
	}
	if _, err := h.svc.ResolveTurn(ctx, "omp", work.ID); kindOf(err) != fault.Invalid {
		t.Fatalf("omp with an account = %v", err)
	}
}

func TestResolveTurnDefaultsAndRefusals(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	if _, err := h.svc.ResolveTurn(ctx, "claude-code", ""); kindOf(err) != fault.FailedPrecondition || err.Error() != "Add a Claude account in Settings › Providers" {
		t.Fatalf("no account = %v", err)
	}
	if _, err := h.svc.ResolveTurn(ctx, "codex", ""); err == nil || err.Error() != "Add a ChatGPT account in Settings › Providers" {
		t.Fatalf("no ChatGPT account = %v", err)
	}
	if _, ok := h.svc.QuickTitleAuth(ctx); ok {
		t.Fatal("quick titles without a ChatGPT account")
	}
	work := h.create(t, ProviderClaude, "Work", "")
	if _, err := h.svc.ResolveTurn(ctx, "claude-code", ""); kindOf(err) != fault.FailedPrecondition || err.Error() != "Work isn't signed in on d_one" {
		t.Fatalf("default not signed in = %v", err)
	}
	personal := h.create(t, ProviderClaude, "Personal", "")
	signInWithFixture(t, h, personal, "FIXTURE-CODE")
	// The default is signed in elsewhere only; the one signed in here runs.
	if auth, err := h.svc.ResolveTurn(ctx, "claude-code", ""); err != nil || auth.AccountID != personal.ID {
		t.Fatalf("fallback = %+v, %v", auth, err)
	}
	if _, err := h.svc.ResolveTurn(ctx, "claude-code", work.ID); err == nil || err.Error() != "Work isn't signed in on d_one" {
		t.Fatalf("explicit not signed in = %v", err)
	}
	signInWithFixture(t, h, work, "FIXTURE-CODE")
	if auth, err := h.svc.ResolveTurn(ctx, "claude-code", ""); err != nil || auth.AccountID != work.ID {
		t.Fatalf("default = %+v, %v", auth, err)
	}
	must(t, h.svc.Delete(ctx, work.ID))
	if _, err := h.svc.ResolveTurn(ctx, "claude-code", work.ID); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("removed account = %v", err)
	}
	chat := h.create(t, ProviderChatGPT, "Chat", "")
	signInWithFixture(t, h, chat, "")
	if auth, ok := h.svc.QuickTitleAuth(ctx); !ok || auth.AccountID != chat.ID || auth.Auth["CODEX_API_KEY"] == "" {
		t.Fatalf("quick title auth = %+v, %v", auth, ok)
	}
}

func TestMarkExpiredBlocksTurnsUntilACheckRecovers(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	work := h.create(t, ProviderClaude, "Work", "")
	signInWithFixture(t, h, work, "FIXTURE-CODE")
	h.svc.markExpired(work.ID, "HTTP 401: authentication_failed")
	record, _ := h.login(t, work.ID)
	if record.State != StateExpired || record.Error.Code != "auth_rejected" {
		t.Fatalf("record = %+v", record)
	}
	if _, err := h.svc.ResolveTurn(ctx, "claude-code", work.ID); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("expired turn = %v", err)
	}
	// Claude Code refreshed its own store; the follow-up check restores it.
	h.clock.Advance(2 * time.Minute)
	h.svc.checkDue(ctx)
	if record, _ := h.login(t, work.ID); record.State != StateSignedIn || record.Error != nil {
		t.Fatalf("after check = %+v", record)
	}
	h.svc.markExpired("not-an-account", "ignored")
}

func TestBrokerRefreshTriggersAndLocking(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	chat := h.create(t, ProviderChatGPT, "Chat", "")
	signInWithFixture(t, h, chat, "")
	account := h.account(t, chat.ID)
	if _, err := h.svc.codexToken(ctx, account); err != nil || h.fixture.Refreshes() != 0 {
		t.Fatalf("fresh token refreshed: %d, %v", h.fixture.Refreshes(), err)
	}
	// Ten-day token: due once it expires within a day.
	h.clock.Advance(9*24*time.Hour + time.Hour)
	var wg sync.WaitGroup
	tokens := make([]string, 4)
	for i := range tokens {
		wg.Add(1)
		go func() {
			defer wg.Done()
			token, err := h.svc.codexToken(ctx, account)
			if err != nil {
				t.Error(err)
			}
			tokens[i] = token
		}()
	}
	wg.Wait()
	if h.fixture.Refreshes() != 1 {
		t.Fatalf("concurrent turns refreshed %d times", h.fixture.Refreshes())
	}
	for _, token := range tokens[1:] {
		if token != tokens[0] {
			t.Fatal("turns got different tokens")
		}
	}
	// A login not refreshed for a week is refreshed although its token lives.
	h.clock.Advance(7*24*time.Hour + time.Minute)
	auth, _ := readCodexAuth(h.svc.codexAuthDir(chat.ID))
	auth.Expires = h.clock.Now().Add(100 * time.Hour)
	if !auth.due(h.clock.Now()) {
		t.Fatal("stale last_refresh not due")
	}
	// A missing login marks the account expired.
	must(t, os.Remove(filepath.Join(h.svc.codexAuthDir(chat.ID), "auth.json")))
	if _, err := h.svc.codexToken(ctx, account); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("missing auth = %v", err)
	}
	if record, _ := h.login(t, chat.ID); record.State != StateExpired {
		t.Fatalf("record = %+v", record)
	}
}
