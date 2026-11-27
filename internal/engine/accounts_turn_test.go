package engine

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/engine/accounts"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

// accountTurnSetup is an engine over an enrolled store whose turns resolve
// provider accounts through accts.
func accountTurnSetup(t *testing.T, runner harness.Runner, accts func(*store.Store) ProviderAccounts) (*Service, model.Project, model.Board) {
	t.Helper()
	data := testkit.PeerStore(t, "dm_turns")
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Accounts", Path: testkit.ProjectDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Delivery", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	noReserve := uint64(0)
	options := Options{Runner: runner, Catalog: harness.StaticCatalog(true), MinimumFreeBytes: &noReserve}
	if accts != nil {
		options.Accounts = accts(data)
	}
	return NewWithOptions(data, options), project, board
}

// fixtureAccounts is the real accounts engine over the fixture backend.
func fixtureAccounts(t *testing.T, data *store.Store) *accounts.Service {
	t.Helper()
	fixture := accounts.NewFixtureBackend()
	fixture.DeviceApproval = 20 * time.Millisecond
	service, err := accounts.New(accounts.Options{
		Store: data, Backend: fixture, Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		MachineName: func() string { return "desk" },
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(service.Shutdown)
	return service
}

func createAccount(t *testing.T, service *accounts.Service, provider, label string) accounts.Account {
	t.Helper()
	account, err := service.Create(context.Background(), accounts.CreateInput{Provider: provider, Label: label})
	if err != nil {
		t.Fatal(err)
	}
	return account
}

// signInAccount signs this machine in through the fixture backend: a pasted
// FIXTURE-CODE for Claude, a self-approving device code for ChatGPT.
func signInAccount(t *testing.T, service *accounts.Service, account accounts.Account) {
	t.Helper()
	ctx := context.Background()
	login, err := service.StartLogin(ctx, account.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if account.Provider == accounts.ProviderClaude {
		if _, err := service.SubmitLoginInput(ctx, login.ID, accounts.FixtureCode, ""); err != nil {
			t.Fatal(err)
		}
	}
	watch, cancel := context.WithTimeout(ctx, testkit.Budget(20*time.Second))
	defer cancel()
	var last accounts.Login
	if err := service.WatchLogin(watch, login.ID, func(value accounts.Login) error {
		last = value
		return nil
	}); err != nil || last.Phase != accounts.PhaseSucceeded {
		t.Fatalf("sign %s in: %+v, %v", account.Label, last, err)
	}
}

func accountCard(t *testing.T, service *Service, project model.Project, board model.Board, provider, modelName, accountID string) model.Card {
	t.Helper()
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: provider + " work", Prompt: "Work",
		Provider: provider, Model: modelName, WorkspaceMode: model.WorkspaceModeProject, AccountID: accountID,
	})
	if err != nil {
		t.Fatal(err)
	}
	return card
}

func sendAndWait(t *testing.T, service *Service, cardID string, selection model.HarnessSelection, text string) {
	t.Helper()
	if _, err := service.SubmitCardPartsWithSelection(cardID, []model.UIMessagePart{{Type: "text", Text: text}}, selection, ""); err != nil {
		t.Fatalf("send %q: %v", text, err)
	}
	waitIdleWithRequests(t, service, cardID)
}

// waitIdleWithRequests waits until the card has no active turn and no queue.
func waitIdleWithRequests(t *testing.T, service *Service, cardID string) {
	t.Helper()
	waitFor(t, func() bool {
		service.mu.Lock()
		active := service.active[cardID] != nil
		service.mu.Unlock()
		conversation, err := service.Store.Conversations.Get(cardID)
		return !active && err == nil && len(conversation.Queue) == 0 && conversation.ActiveTurn == nil
	})
}

// emitAccountReply streams a reply under the turn's response message ID, as
// the worker does, with 120 input and 30 output tokens.
func emitAccountReply(_ context.Context, request harness.Request, emit func(harness.Output) error) error {
	for _, chunk := range []string{
		`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`,
		`{"type":"text-start","id":"text"}`,
		`{"type":"text-delta","id":"text","delta":"done"}`,
		`{"type":"text-end","id":"text"}`,
		`{"type":"finish","finishReason":"stop","messageMetadata":{"usage":{"inputTokens":120,"outputTokens":30,"totalTokens":150}}}`,
	} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return testkit.EmitSession(emit, testkit.FakeThreadID)
}

func storedAccount(t *testing.T, service *Service, cardID string) string {
	t.Helper()
	card, err := service.Store.Kanban.ResolveCard(cardID)
	if err != nil {
		t.Fatal(err)
	}
	return card.ProviderAccountID
}

func TestTurnsRunOnTheResolvedProviderAccount(t *testing.T) {
	t.Parallel()
	runner := &testkit.FakeRunner{Script: emitAccountReply}
	var engineAccounts *accounts.Service
	service, project, board := accountTurnSetup(t, runner, func(data *store.Store) ProviderAccounts {
		engineAccounts = fixtureAccounts(t, data)
		return engineAccounts
	})
	work := createAccount(t, engineAccounts, accounts.ProviderClaude, "Work")
	personal := createAccount(t, engineAccounts, accounts.ProviderChatGPT, "Personal")
	signInAccount(t, engineAccounts, work)
	signInAccount(t, engineAccounts, personal)

	claude := accountCard(t, service, project, board, "claude-code", "sonnet", "")
	sendAndWait(t, service, claude.ID, model.HarnessSelection{}, "Fix it")
	request := runner.Request(0)
	if request.Adapter != "claude-code" || request.ProviderAccountID != work.ID {
		t.Fatalf("Claude turn adapter=%q account=%q", request.Adapter, request.ProviderAccountID)
	}
	if request.Auth == nil || len(request.Auth) != 0 {
		t.Fatalf("a Claude login turn hands the adapter {} so Claude Code uses its own login: %#v", request.Auth)
	}
	wantDir := filepath.Join(service.Store.ProviderAccountDir(work.ID), "claude")
	if request.Environment["CLAUDE_CONFIG_DIR"] != wantDir {
		t.Fatalf("CLAUDE_CONFIG_DIR = %q, want %q", request.Environment["CLAUDE_CONFIG_DIR"], wantDir)
	}
	for _, masked := range []string{"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"} {
		if value, ok := request.Environment[masked]; !ok || value != "" {
			t.Fatalf("host key %s is not masked: %q (present %v)", masked, value, ok)
		}
	}
	if request.Environment["DIETER_TURN_TOKEN"] == "" {
		t.Fatal("the account environment replaced the agent environment")
	}
	if got := storedAccount(t, service, claude.ID); got != work.ID {
		t.Fatalf("the card records account %q, want %s", got, work.ID)
	}

	codex := accountCard(t, service, project, board, "codex", "gpt-5.5", "")
	sendAndWait(t, service, codex.ID, model.HarnessSelection{}, "Fix it")
	request = runner.Request(1)
	if request.Adapter != "codex" || request.ProviderAccountID != personal.ID || storedAccount(t, service, codex.ID) != personal.ID {
		t.Fatalf("Codex turn adapter=%q account=%q", request.Adapter, request.ProviderAccountID)
	}
	if request.Auth["CODEX_API_KEY"] == "" || request.Auth["OPENAI_BASE_URL"] != "https://chatgpt.com/backend-api/codex" {
		t.Fatalf("Codex auth = %#v", request.Auth)
	}
	if request.Environment["CODEX_HOME"] != service.Store.CodexHome() {
		t.Fatalf("CODEX_HOME = %q, want %q", request.Environment["CODEX_HOME"], service.Store.CodexHome())
	}

	// Each reply's provider-reported tokens reach its account's ledger.
	testkit.Eventually(t, testkit.Budget(20*time.Second), func() bool {
		values, err := engineAccounts.List(context.Background(), "")
		if err != nil {
			return false
		}
		recorded := 0
		for _, value := range values {
			if value.DieterTokens != nil && value.DieterTokens.FiveHour.Total == 150 && value.DieterTokens.FiveHour.Input == 120 && value.DieterTokens.SevenDay.Total == 150 {
				recorded++
			}
		}
		return recorded == 2
	}, "both accounts to record the turns' tokens")
}

func TestProviderAccountSwitchesBetweenTurnsAndQueuedMessagesKeepTheirOwn(t *testing.T) {
	t.Parallel()
	runner := &testkit.FakeRunner{}
	var engineAccounts *accounts.Service
	service, project, board := accountTurnSetup(t, runner, func(data *store.Store) ProviderAccounts {
		engineAccounts = fixtureAccounts(t, data)
		return engineAccounts
	})
	work := createAccount(t, engineAccounts, accounts.ProviderClaude, "Work")
	side := createAccount(t, engineAccounts, accounts.ProviderClaude, "Side")
	signInAccount(t, engineAccounts, work)
	signInAccount(t, engineAccounts, side)

	card := accountCard(t, service, project, board, "claude-code", "sonnet", "")
	sendAndWait(t, service, card.ID, model.HarnessSelection{}, "First")
	sendAndWait(t, service, card.ID, model.HarnessSelection{AccountID: side.ID}, "Second")
	if first, second := runner.Request(0), runner.Request(1); first.ProviderAccountID != work.ID || second.ProviderAccountID != side.ID {
		t.Fatalf("turn accounts = %q, %q; want the default, then the switch", first.ProviderAccountID, second.ProviderAccountID)
	}
	if got := storedAccount(t, service, card.ID); got != side.ID {
		t.Fatalf("the switch is not stored: %q", got)
	}
	if runner.Request(1).Environment["CLAUDE_CONFIG_DIR"] != filepath.Join(service.Store.ProviderAccountDir(side.ID), "claude") {
		t.Fatalf("the switched turn uses %q", runner.Request(1).Environment["CLAUDE_CONFIG_DIR"])
	}
	// Without a choice the next turn keeps the conversation's account.
	sendAndWait(t, service, card.ID, model.HarnessSelection{}, "Third")
	if got := runner.Request(2).ProviderAccountID; got != side.ID {
		t.Fatalf("an unchanged turn moved to %q", got)
	}

	// A message queued behind a running turn keeps the account it was sent with.
	runner.Release = make(chan struct{})
	if queued, err := service.SubmitCardPartsWithSelection(card.ID, []model.UIMessagePart{{Type: "text", Text: "Hold"}}, model.HarnessSelection{}, ""); err != nil || queued {
		t.Fatalf("held turn queued=%v err=%v", queued, err)
	}
	waitFor(t, func() bool { return runner.Count() == 4 })
	queued, err := service.SubmitCardPartsWithSelection(card.ID, []model.UIMessagePart{{Type: "text", Text: "Queued"}}, model.HarnessSelection{AccountID: work.ID}, "")
	if err != nil || !queued {
		t.Fatalf("queued=%v err=%v", queued, err)
	}
	conversation, err := service.Store.Conversations.Get(card.ID)
	if err != nil || len(conversation.Queue) != 1 || conversation.Queue[0].Selection == nil || conversation.Queue[0].Selection.AccountID != work.ID {
		t.Fatalf("queue = %+v, %v", conversation.Queue, err)
	}
	if got := storedAccount(t, service, card.ID); got != side.ID {
		t.Fatalf("queueing changed the running turn's account: %q", got)
	}
	close(runner.Release)
	waitFor(t, func() bool { return runner.Count() == 5 })
	waitIdleWithRequests(t, service, card.ID)
	if held, next := runner.Request(3), runner.Request(4); held.ProviderAccountID != side.ID || next.ProviderAccountID != work.ID {
		t.Fatalf("held=%q queued=%q", held.ProviderAccountID, next.ProviderAccountID)
	}
	if got := storedAccount(t, service, card.ID); got != work.ID {
		t.Fatalf("after the queued turn the card records %q", got)
	}
}

func TestTurnAdmissionNeedsASignedInProviderAccount(t *testing.T) {
	t.Parallel()
	runner := &testkit.FakeRunner{}
	var engineAccounts *accounts.Service
	service, project, board := accountTurnSetup(t, runner, func(data *store.Store) ProviderAccounts {
		engineAccounts = fixtureAccounts(t, data)
		return engineAccounts
	})
	card := accountCard(t, service, project, board, "claude-code", "sonnet", "")
	_, err := service.StartCard(card.ID, "Go", "", "", "")
	if kind, _ := fault.KindOf(err); kind != fault.FailedPrecondition || !strings.Contains(err.Error(), "Add a Claude account") {
		t.Fatalf("a turn without accounts: %v", err)
	}
	work := createAccount(t, engineAccounts, accounts.ProviderClaude, "Work")
	_, err = service.StartCard(card.ID, "Go", "", "", "")
	if kind, _ := fault.KindOf(err); kind != fault.FailedPrecondition || !strings.Contains(err.Error(), "Work") || !strings.Contains(err.Error(), "desk") {
		t.Fatalf("a turn on an account that is not signed in here: %v", err)
	}
	// An account of the other provider is refused.
	personal := createAccount(t, engineAccounts, accounts.ProviderChatGPT, "Personal")
	_, err = service.StartCardWithSelection(card.ID, []model.UIMessagePart{{Type: "text", Text: "Go"}}, model.HarnessSelection{AccountID: personal.ID}, "")
	if kind, _ := fault.KindOf(err); kind != fault.Invalid {
		t.Fatalf("a Claude turn on a ChatGPT account: %v", err)
	}
	if runner.Count() != 0 {
		t.Fatalf("%d turns ran without an account", runner.Count())
	}
	if stored, err := service.Store.Kanban.ResolveCard(card.ID); err != nil || stored.InitialPromptSentAt != "" || stored.ProviderAccountID != "" {
		t.Fatalf("a refused admission changed the card: %+v, %v", stored, err)
	}
	signInAccount(t, engineAccounts, work)
	sendAndWait(t, service, card.ID, model.HarnessSelection{}, "Go")
	if runner.Count() != 1 || runner.Request(0).ProviderAccountID != work.ID {
		t.Fatalf("after signing in: %d turns, account %q", runner.Count(), runner.Request(0).ProviderAccountID)
	}
}

// recordingAccounts is a ProviderAccounts that records what turns report.
type recordingAccounts struct {
	mu        sync.Mutex
	auth      accounts.TurnAuth
	err       error
	quick     accounts.TurnAuth
	quickOK   bool
	resolved  []string
	quickAsks int
	usage     []string
	expired   []string
	tokens    [][3]int64
	// ompAdvisor is the advisor account ResolveOMPTurn reports.
	ompAdvisor string
}

func (r *recordingAccounts) ResolveTurn(_ context.Context, harness, accountID string) (accounts.TurnAuth, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.resolved = append(r.resolved, harness+":"+accountID)
	return r.auth, r.err
}

func (r *recordingAccounts) ResolveOMPTurn(_ context.Context, model, accountID, advisorModel, advisorAccountID string) (accounts.OMPTurn, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.resolved = append(r.resolved, "omp:"+model+":"+accountID+":"+advisorModel+":"+advisorAccountID)
	if r.err != nil {
		return accounts.OMPTurn{}, r.err
	}
	turn := accounts.OMPTurn{AccountID: r.auth.AccountID}
	if advisorModel != "" && advisorModel != "off" {
		turn.AdvisorAccountID = r.ompAdvisor
	}
	return turn, nil
}

func (r *recordingAccounts) QuickTitleAuth(context.Context) (accounts.TurnAuth, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.quickAsks++
	return r.quick, r.quickOK
}

func (r *recordingAccounts) ObserveUsage(accountID string, data json.RawMessage) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.usage = append(r.usage, accountID+" "+string(data))
}

func (r *recordingAccounts) MarkExpired(accountID, reason string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.expired = append(r.expired, accountID+" "+reason)
}

func (r *recordingAccounts) RecordTurnTokens(accountID string, _ time.Time, input, output, total int64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if accountID == fakeAccountID {
		r.tokens = append(r.tokens, [3]int64{input, output, total})
	}
}

// accountReports is what a recordingAccounts saw.
type accountReports struct {
	resolved       []string
	quickAsks      int
	usage, expired []string
	tokens         [][3]int64
}

func (r *recordingAccounts) snapshot() accountReports {
	r.mu.Lock()
	defer r.mu.Unlock()
	return accountReports{
		resolved: append([]string(nil), r.resolved...), quickAsks: r.quickAsks,
		usage: append([]string(nil), r.usage...), expired: append([]string(nil), r.expired...), tokens: append([][3]int64(nil), r.tokens...),
	}
}

const fakeAccountID = "pa_fakeaccountfakeaccount2222"

func TestTurnUsageAndAuthFailuresReachTheAccountsEngine(t *testing.T) {
	t.Parallel()
	const usage = `{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour","utilization":0.38}}`
	runner := &testkit.FakeRunner{Script: func(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
		for _, output := range []harness.Output{
			{Type: "provider-usage", Data: json.RawMessage(usage)},
			{Type: "auth-failure", Reason: "HTTP 401: authentication_failed"},
		} {
			if err := emit(output); err != nil {
				return err
			}
		}
		return emitAccountReply(ctx, request, emit)
	}}
	recorder := &recordingAccounts{auth: accounts.TurnAuth{AccountID: fakeAccountID, Env: map[string]string{"CLAUDE_CONFIG_DIR": "/accounts/claude"}, Auth: map[string]string{}}}
	service, project, board := accountTurnSetup(t, runner, func(*store.Store) ProviderAccounts { return recorder })

	claude := accountCard(t, service, project, board, "claude-code", "sonnet", "")
	sendAndWait(t, service, claude.ID, model.HarnessSelection{}, "Go")
	if request := runner.Request(0); request.ProviderAccountID != fakeAccountID || request.Environment["CLAUDE_CONFIG_DIR"] != "/accounts/claude" || request.Auth == nil {
		t.Fatalf("request = account %q env %q auth %#v", request.ProviderAccountID, request.Environment["CLAUDE_CONFIG_DIR"], request.Auth)
	}
	testkit.Eventually(t, testkit.Budget(10*time.Second), func() bool { return len(recorder.snapshot().tokens) == 1 }, "the turn's tokens")
	seen := recorder.snapshot()
	if len(seen.resolved) != 1 || seen.resolved[0] != "claude-code:" {
		t.Fatalf("resolutions = %v", seen.resolved)
	}
	if len(seen.usage) != 1 || seen.usage[0] != fakeAccountID+" "+usage {
		t.Fatalf("observed usage = %v", seen.usage)
	}
	if len(seen.expired) != 1 || seen.expired[0] != fakeAccountID+" HTTP 401: authentication_failed" {
		t.Fatalf("expired logins = %v", seen.expired)
	}
	if seen.tokens[0] != [3]int64{120, 30, 150} {
		t.Fatalf("recorded tokens = %v", seen.tokens)
	}
	// Usage frames of a turn on no account go nowhere; the mock adapter never
	// asks for an account.
	mock := accountCard(t, service, project, board, "mock", "mock", "")
	sendAndWait(t, service, mock.ID, model.HarnessSelection{}, "Go")
	after := recorder.snapshot()
	if len(after.resolved) != 1 || len(after.usage) != 1 || len(after.expired) != 1 || len(after.tokens) != 1 {
		t.Fatalf("a mock turn reached the accounts engine: %+v", after)
	}
	if request := runner.Request(1); request.ProviderAccountID != "" || request.Auth != nil || storedAccount(t, service, mock.ID) != "" {
		t.Fatalf("mock request account=%q auth=%#v", request.ProviderAccountID, request.Auth)
	}
}

func TestTurnAdmissionFailsWhenTheAccountsEngineRefuses(t *testing.T) {
	t.Parallel()
	runner := &testkit.FakeRunner{}
	recorder := &recordingAccounts{err: fault.New(fault.FailedPrecondition, "Work isn't signed in on desk")}
	service, project, board := accountTurnSetup(t, runner, func(*store.Store) ProviderAccounts { return recorder })
	card := accountCard(t, service, project, board, "codex", "gpt-5.5", fakeAccountID)
	if stored := storedAccount(t, service, card.ID); stored != fakeAccountID {
		t.Fatalf("the created card records %q", stored)
	}
	_, err := service.StartCard(card.ID, "Go", "", "", "")
	if kind, _ := fault.KindOf(err); kind != fault.FailedPrecondition {
		t.Fatalf("admission error = %v", err)
	}
	if seen := recorder.snapshot(); len(seen.resolved) != 1 || seen.resolved[0] != "codex:"+fakeAccountID {
		t.Fatalf("resolutions = %v", seen.resolved)
	}
	if runner.Count() != 0 {
		t.Fatal("a refused turn ran")
	}
}

func TestQuickTaskTitlesRunOnTheQuickTitleAccount(t *testing.T) {
	t.Parallel()
	runner := &testkit.FakeRunner{Reply: func(harness.Request) string { return "Repair the login form" }}
	recorder := &recordingAccounts{}
	service, _, _ := accountTurnSetup(t, runner, func(*store.Store) ProviderAccounts { return recorder })

	_, err := service.generateQuickTaskTitle(context.Background(), "The login form forgets the email")
	if !errors.Is(err, errQuickTitleSkipped) || runner.Count() != 0 {
		t.Fatalf("without a ChatGPT account: err=%v runs=%d", err, runner.Count())
	}

	recorder.mu.Lock()
	recorder.quickOK = true
	recorder.quick = accounts.TurnAuth{AccountID: fakeAccountID, Env: map[string]string{"CODEX_HOME": "/dieter/codex"}, Auth: map[string]string{"CODEX_API_KEY": "token"}}
	recorder.mu.Unlock()
	title, err := service.generateQuickTaskTitle(context.Background(), "The login form forgets the email")
	if err != nil || title != "Repair the login form" {
		t.Fatalf("title = %q, %v", title, err)
	}
	request := runner.Request(0)
	if request.Adapter != "codex" || request.ConfiguredModel != quickTaskTitleModel || request.ProviderAccountID != fakeAccountID ||
		request.Auth["CODEX_API_KEY"] != "token" || request.Environment["CODEX_HOME"] != "/dieter/codex" {
		t.Fatalf("title request adapter=%q model=%q account=%q auth=%#v env=%#v", request.Adapter, request.ConfiguredModel, request.ProviderAccountID, request.Auth, request.Environment)
	}
	if seen := recorder.snapshot(); seen.quickAsks != 2 || len(seen.resolved) != 0 {
		t.Fatalf("quick titles asked %d times and resolved %v", seen.quickAsks, seen.resolved)
	}
}
