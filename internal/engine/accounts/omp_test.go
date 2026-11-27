//go:build unix

package accounts

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

func ompAccess(t *testing.T, h *harness, id string, allowed bool) {
	t.Helper()
	if _, err := h.svc.Update(context.Background(), id, nil, nil, &allowed); err != nil {
		t.Fatal(err)
	}
}

// ompAccounts signs in two Claude accounts (Work, the default, and Side) and
// two ChatGPT accounts (Chat, the default, and Spare) on d_one.
func ompAccounts(t *testing.T, h *harness) (work, side, chat, spare Account) {
	t.Helper()
	work, side = h.create(t, ProviderClaude, "Work", ""), h.create(t, ProviderClaude, "Side", "")
	chat, spare = h.create(t, ProviderChatGPT, "Chat", ""), h.create(t, ProviderChatGPT, "Spare", "")
	for _, account := range []Account{work, side} {
		signInWithFixture(t, h, account, FixtureCode)
	}
	for _, account := range []Account{chat, spare} {
		signInWithFixture(t, h, account, "")
	}
	return work, side, chat, spare
}

func TestOMPModelProviderFollowsTheModelPrefix(t *testing.T) {
	t.Parallel()
	for selector, want := range map[string]string{
		"anthropic/claude-opus-5-5": ProviderClaude, " openai-codex/gpt-6-sol ": ProviderChatGPT,
		"claude-opus-5-5": "", "tailscale/glm": "", "openai/gpt-6-sol": "", "": "",
	} {
		if got := OMPModelProvider(selector); got != want {
			t.Errorf("OMPModelProvider(%q) = %q, want %q", selector, got, want)
		}
	}
}

func TestResolveOMPTurnResolvesTheImplementationAndAdvisorAccounts(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	work, side, chat, spare := ompAccounts(t, h)
	const claude, codex = "anthropic/claude-sonnet-5-5", "openai-codex/gpt-6-sol"

	if _, err := h.svc.ResolveOMPTurn(ctx, "tailscale/glm", "", "", ""); kindOf(err) != fault.Invalid {
		t.Fatalf("an unmanaged model = %v", err)
	}
	// A Claude login needs the account's opt-in, for either role.
	if _, err := h.svc.ResolveOMPTurn(ctx, claude, work.ID, "", ""); kindOf(err) != fault.FailedPrecondition || err.Error() != "Allow Oh My Pi to use Work in Settings › Providers first" {
		t.Fatalf("Claude without Oh My Pi access = %v", err)
	}
	if _, err := h.svc.ResolveOMPTurn(ctx, codex, chat.ID, claude, ""); kindOf(err) != fault.FailedPrecondition || !strings.Contains(err.Error(), "Allow Oh My Pi to use Work") {
		t.Fatalf("a Claude advisor without Oh My Pi access = %v", err)
	}
	// ChatGPT logins need no opt-in; the provider default runs.
	for _, advisor := range []string{"", "off"} {
		if turn, err := h.svc.ResolveOMPTurn(ctx, codex, "", advisor, spare.ID); err != nil || turn != (OMPTurn{AccountID: chat.ID}) {
			t.Fatalf("ChatGPT without an advisor (%q) = %+v, %v", advisor, turn, err)
		}
	}
	ompAccess(t, h, work.ID, true)
	if _, err := h.svc.ResolveOMPTurn(ctx, claude, work.ID, "tailscale/glm", ""); kindOf(err) != fault.Invalid {
		t.Fatalf("an unmanaged advisor = %v", err)
	}
	if _, err := h.svc.ResolveOMPTurn(ctx, claude, chat.ID, "", ""); kindOf(err) != fault.Invalid || err.Error() != "Chat is a ChatGPT account" {
		t.Fatalf("an implementation account of the other provider = %v", err)
	}

	for name, test := range map[string]struct {
		model, account, advisor, advisorAccount string
		want                                    OMPTurn
	}{
		// OMP holds one credential per provider: a same-provider advisor
		// runs on the implementation account, whatever was chosen.
		"same provider":           {claude, work.ID, "anthropic/claude-haiku-5-5", side.ID, OMPTurn{work.ID, work.ID}},
		"same provider, ChatGPT":  {codex, spare.ID, "openai-codex/gpt-6-luna", chat.ID, OMPTurn{spare.ID, spare.ID}},
		"advisor default":         {claude, "", codex, "", OMPTurn{work.ID, chat.ID}},
		"advisor account":         {claude, work.ID, codex, spare.ID, OMPTurn{work.ID, spare.ID}},
		"stale advisor account":   {claude, work.ID, codex, side.ID, OMPTurn{work.ID, chat.ID}},
		"Claude advisor":          {codex, spare.ID, "anthropic/claude-opus-5-5", "", OMPTurn{spare.ID, work.ID}},
		"stale Claude advisor":    {codex, spare.ID, "anthropic/claude-opus-5-5", chat.ID, OMPTurn{spare.ID, work.ID}},
		"advisor effort selector": {codex, chat.ID, " anthropic/claude-opus-5-5 ", "", OMPTurn{chat.ID, work.ID}},
	} {
		turn, err := h.svc.ResolveOMPTurn(ctx, test.model, test.account, test.advisor, test.advisorAccount)
		if err != nil || turn != test.want {
			t.Errorf("%s = %+v, %v; want %+v", name, turn, err, test.want)
		}
	}
	// Side has no Oh My Pi access, as an explicit advisor too.
	if _, err := h.svc.ResolveOMPTurn(ctx, codex, chat.ID, claude, side.ID); kindOf(err) != fault.FailedPrecondition || !strings.Contains(err.Error(), "Allow Oh My Pi to use Side") {
		t.Fatalf("an advisor without Oh My Pi access = %v", err)
	}

	// Accounts not signed in here are refused for either role.
	idle := h.create(t, ProviderClaude, "Idle", "")
	ompAccess(t, h, idle.ID, true)
	if _, err := h.svc.ResolveOMPTurn(ctx, claude, idle.ID, "", ""); kindOf(err) != fault.FailedPrecondition || err.Error() != "Idle isn't signed in on d_one" {
		t.Fatalf("a signed-out implementation account = %v", err)
	}
	if _, err := h.svc.SignOut(ctx, spare.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := h.svc.ResolveOMPTurn(ctx, claude, work.ID, codex, spare.ID); kindOf(err) != fault.FailedPrecondition || err.Error() != "Spare isn't signed in on d_one" {
		t.Fatalf("a signed-out advisor account = %v", err)
	}
}

func TestOMPTurnTokenServesTheTurnsAccountOfEachProvider(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	work, _, chat, _ := ompAccounts(t, h)
	ompAccess(t, h, work.ID, true)

	token, expires, err := h.svc.OMPTurnToken(ctx, ProviderClaude, work.ID, chat.ID)
	if err != nil || !strings.HasPrefix(token, "sk-ant-oat01-fixture-") || !expires.After(h.clock.Now().Add(time.Hour)) {
		t.Fatalf("Claude token = %q (expires %v), %v", token, expires, err)
	}
	managed, err := readCodexAuth(h.svc.codexAuthDir(chat.ID))
	if err != nil {
		t.Fatal(err)
	}
	// The advisor's account answers for its provider; unknown IDs are skipped.
	if token, _, err := h.svc.OMPTurnToken(ctx, ProviderChatGPT, "pa_missingmissingmissing22222", work.ID, chat.ID); err != nil || token != managed.AccessToken {
		t.Fatalf("ChatGPT token = %q, %v", token, err)
	}
	if _, _, err := h.svc.OMPTurnToken(ctx, ProviderChatGPT, work.ID, ""); kindOf(err) != fault.FailedPrecondition || err.Error() != "this turn uses no ChatGPT account" {
		t.Fatalf("a provider the turn does not use = %v", err)
	}
	if _, _, err := h.svc.OMPTurnToken(ctx, ProviderClaude); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("a turn without accounts = %v", err)
	}
	// Turning the opt-in off applies to the next token a running turn asks for.
	ompAccess(t, h, work.ID, false)
	if _, _, err := h.svc.OMPTurnToken(ctx, ProviderClaude, work.ID, chat.ID); kindOf(err) != fault.FailedPrecondition || !strings.Contains(err.Error(), "Allow Oh My Pi to use Work") {
		t.Fatalf("a Claude token after the opt-in was revoked = %v", err)
	}
}

func claudeProbes(h *harness, dir string) int {
	return countCalls(h.fixture.Calls(), "ProbeClaudeUsage:"+dir)
}

func countCalls(calls []string, call string) int {
	count := 0
	for _, value := range calls {
		if value == call {
			count++
		}
	}
	return count
}

func TestOMPClaudeTokenRefreshesThroughClaudeCode(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	work := h.create(t, ProviderClaude, "Work", "")
	signInWithFixture(t, h, work, FixtureCode)
	ompAccess(t, h, work.ID, true)
	dir := h.svc.claudeDir(work.ID)

	first, _, err := h.svc.OMPTurnToken(ctx, ProviderClaude, work.ID)
	if err != nil {
		t.Fatal(err)
	}
	if probes := claudeProbes(h, dir); probes != 0 {
		t.Fatalf("a fresh token ran %d usage probes", probes)
	}
	// An expired token: Claude Code's prompt-less usage probe renews the
	// login, and the store is read again. Dieter never refreshes itself.
	h.fixture.ExpireClaudeToken(dir)
	second, expires, err := h.svc.OMPTurnToken(ctx, ProviderClaude, work.ID)
	if err != nil || second == first || !expires.After(h.clock.Now()) {
		t.Fatalf("refreshed token = %q (was %q, expires %v), %v", second, first, expires, err)
	}
	if probes := claudeProbes(h, dir); probes != 1 {
		t.Fatalf("the refresh ran %d usage probes, want 1", probes)
	}
	if again, _, err := h.svc.OMPTurnToken(ctx, ProviderClaude, work.ID); err != nil || again != second || claudeProbes(h, dir) != 1 {
		t.Fatalf("the refreshed token is not reused: %q, %v", again, err)
	}
	// The turn's admission refreshes too, so the helper OMP runs only reads.
	h.fixture.ExpireClaudeToken(dir)
	if _, err := h.svc.ResolveOMPTurn(ctx, "anthropic/claude-opus-5-5", work.ID, "", ""); err != nil || claudeProbes(h, dir) != 2 {
		t.Fatalf("admission of an expired login = %v (%d probes)", err, claudeProbes(h, dir))
	}
	if record, _ := h.login(t, work.ID); record.State != StateSignedIn {
		t.Fatalf("login after the refreshes = %+v", record)
	}
}

// stuckClaude is a fixture backend whose Claude Code cannot refresh.
type stuckClaude struct{ *FixtureBackend }

func (b stuckClaude) ProbeClaudeUsage(_ context.Context, configDir string) (ClaudeProbe, error) {
	b.record("ProbeClaudeUsage:" + configDir)
	return ClaudeProbe{}, errors.New("Claude Code could not reach Anthropic")
}

func TestOMPClaudeTokenThatCannotRefreshExpiresTheLogin(t *testing.T) {
	t.Parallel()
	backend := stuckClaude{NewFixtureBackend()}
	h := newHarness(t, "d_one", withBackend(backend))
	backend.Clock = h.clock.Now
	ctx := context.Background()
	work := h.create(t, ProviderClaude, "Work", "")
	signInWithFixture(t, h, work, FixtureCode)
	ompAccess(t, h, work.ID, true)
	dir := h.svc.claudeDir(work.ID)
	backend.ExpireClaudeToken(dir)
	if _, _, err := h.svc.OMPTurnToken(ctx, ProviderClaude, work.ID); kindOf(err) != fault.FailedPrecondition || err.Error() != "Work isn't signed in on d_one" {
		t.Fatalf("an expired login Claude Code cannot refresh = %v", err)
	}
	if countCalls(backend.Calls(), "ProbeClaudeUsage:"+dir) != 1 {
		t.Fatalf("calls = %v", backend.Calls())
	}
	if record, _ := h.login(t, work.ID); record.State != StateExpired {
		t.Fatalf("login after the failed refresh = %+v", record)
	}
	if _, err := h.svc.ResolveOMPTurn(ctx, "anthropic/claude-opus-5-5", work.ID, "", ""); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("a turn on the expired login = %v", err)
	}
}

func TestOMPTokensForEveryLoginMethod(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one", withEnvironment(map[string]string{"ANTHROPIC_API_KEY": "sk-ant-api", "OPENAI_API_KEY": "sk-openai"}))
	ctx := context.Background()
	plan := h.create(t, ProviderChatGPT, "Plan", MethodSIWC)
	signInWithFixture(t, h, plan, "http://127.0.0.1:1456/auth/callback?code=fixture")
	h.svc.adopt(ctx)
	listed, err := h.svc.List(ctx, "")
	if err != nil {
		t.Fatal(err)
	}
	byMethod := map[string]Account{}
	for _, account := range listed {
		byMethod[account.Provider+"/"+account.Method] = account
	}
	claudeKey, chatGPTKey := byMethod["claude/environment"], byMethod["chatgpt/environment"]
	if claudeKey.ID == "" || chatGPTKey.ID == "" {
		t.Fatalf("adopted accounts = %v", byMethod)
	}

	// OMP's openai-codex provider talks to the ChatGPT Codex backend, which
	// takes ChatGPT logins only: Sign in with ChatGPT and API keys are out.
	for _, account := range []Account{plan, chatGPTKey} {
		if _, _, err := h.svc.OMPTurnToken(ctx, ProviderChatGPT, account.ID); kindOf(err) != fault.FailedPrecondition || !strings.Contains(err.Error(), "only on ChatGPT logins") {
			t.Errorf("%s token = %v", account.Method, err)
		}
		if _, err := h.svc.ResolveOMPTurn(ctx, "openai-codex/gpt-6-sol", account.ID, "", ""); kindOf(err) != fault.FailedPrecondition {
			t.Errorf("%s turn = %v", account.Method, err)
		}
	}
	// An Anthropic API key account still needs the opt-in, then serves the key.
	if _, _, err := h.svc.OMPTurnToken(ctx, ProviderClaude, claudeKey.ID); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("API key without Oh My Pi access = %v", err)
	}
	ompAccess(t, h, claudeKey.ID, true)
	if token, expires, err := h.svc.OMPTurnToken(ctx, ProviderClaude, claudeKey.ID); err != nil || token != "sk-ant-api" || !expires.IsZero() {
		t.Fatalf("API key token = %q (expires %v), %v", token, expires, err)
	}
}

func TestUpdateOMPAccessIsClaudeOnly(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	ctx := context.Background()
	work := h.create(t, ProviderClaude, "Work", "")
	chat := h.create(t, ProviderChatGPT, "Chat", "")
	if work.OMPAccess || chat.OMPAccess {
		t.Fatalf("new accounts have Oh My Pi access: %+v %+v", work, chat)
	}
	on, off := true, false
	updated, err := h.svc.Update(ctx, work.ID, nil, nil, &on)
	if err != nil || !updated.OMPAccess || updated.Label != "Work" {
		t.Fatalf("Claude on = %+v, %v", updated, err)
	}
	listed, _ := h.svc.List(ctx, ProviderClaude)
	if len(listed) != 1 || !listed[0].OMPAccess {
		t.Fatalf("listed after on = %+v", listed)
	}
	// Other edits keep the opt-in.
	label := "Office"
	if updated, err := h.svc.Update(ctx, work.ID, &label, nil, nil); err != nil || !updated.OMPAccess || updated.Label != "Office" {
		t.Fatalf("rename = %+v, %v", updated, err)
	}
	if updated, err := h.svc.Update(ctx, work.ID, nil, nil, &off); err != nil || updated.OMPAccess {
		t.Fatalf("Claude off = %+v, %v", updated, err)
	}
	if _, err := h.svc.Update(ctx, chat.ID, nil, nil, &on); kindOf(err) != fault.Invalid {
		t.Fatalf("ChatGPT on = %v", err)
	}
	if updated, err := h.svc.Update(ctx, chat.ID, nil, nil, &off); err != nil || updated.OMPAccess {
		t.Fatalf("ChatGPT off = %+v, %v", updated, err)
	}
	if calls := h.fixture.Calls(); slices.ContainsFunc(calls, func(call string) bool { return strings.HasPrefix(call, "ReadClaudeToken") }) {
		t.Fatalf("toggling the opt-in read a Claude token: %v", calls)
	}
}
