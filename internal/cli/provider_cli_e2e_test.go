//go:build e2e

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	"github.com/dbpprt/dieter/internal/engine"
	"github.com/dbpprt/dieter/internal/engine/accounts"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

const providerCLIDaemon = "dm_provider_cli"

// providerDaemonCLI is daemonCLIWithRunner with the daemon's accounts engine
// (over the in-process fixture backend) wired into its API and its turns, as
// `dieter serve` does.
func providerDaemonCLI(t *testing.T) (*CLI, *bytes.Buffer, *store.Store, *fakeRunner) {
	t.Helper()
	root := t.TempDir()
	data := store.New(root)
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	if _, err := data.Replica.BindPeerAccount("account", "subject", providerCLIDaemon, "https://gateway.test"); err != nil {
		t.Fatal(err)
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	fixture := accounts.NewFixtureBackend()
	fixture.DeviceApproval = 50 * time.Millisecond
	service, err := accounts.New(accounts.Options{Store: data, Backend: fixture, Logger: logger, MachineName: func() string { return "desk" }})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(service.Shutdown)
	runner := newFakeRunner()
	noReserve := uint64(0)
	app := engine.NewWithOptions(data, engine.Options{Runner: runner, Catalog: testkit.MockCatalog(), MinimumFreeBytes: &noReserve, Accounts: service})
	application := api.NewWithOptions(data, logger, api.Options{
		Runner: runner, Catalog: testkit.MockCatalog(), MinimumFreeBytes: &noReserve, App: app, Accounts: service,
		PrivacyDriver: &cliPrivacyFixture{}, PrivacyBootID: func(context.Context) (string, error) { return "cli-boot", nil },
	})
	host := testkit.HTTPServer(application.Handler())
	t.Cleanup(host.Close)
	if _, err := link.NewStatusWriter(root, link.RuntimeStatus{
		PID: os.Getpid(), Version: "test", State: "running", ListenAddress: strings.TrimPrefix(host.URL, "http://"), GatewayState: link.GatewayNotEnrolled,
	}); err != nil {
		t.Fatal(err)
	}
	output := &bytes.Buffer{}
	client := New(data.Root)
	client.env.TurnToken = ""
	client.Timeout = 10 * time.Second
	// Notes on stderr (an account that cannot refresh on this unenrolled
	// daemon) stay out of the JSON the test parses.
	client.Out, client.Err = output, &bytes.Buffer{}
	t.Cleanup(client.Close)
	return client, output, data, runner
}

type cliProviderAccount struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Provider  string `json:"provider"`
	IsDefault bool   `json:"isDefault"`
	Logins    []struct {
		DaemonID string `json:"daemonId"`
		State    string `json:"state"`
	} `json:"logins"`
	Usage *struct {
		Windows []struct {
			Kind        string  `json:"kind"`
			UsedPercent float64 `json:"usedPercent"`
		} `json:"windows"`
		ResetCreditsAvailable int `json:"resetCreditsAvailable"`
	} `json:"usage"`
}

func (a cliProviderAccount) state(daemonID string) string {
	for _, login := range a.Logins {
		if login.DaemonID == daemonID {
			return login.State
		}
	}
	return ""
}

func providerListJSON(t *testing.T, client *CLI, output *bytes.Buffer, args ...string) map[string]cliProviderAccount {
	t.Helper()
	var listed struct {
		Accounts []cliProviderAccount `json:"accounts"`
	}
	raw := runDaemonCLI(t, client, output, append(args, "--format", "json")...)
	if err := json.Unmarshal([]byte(raw), &listed); err != nil {
		t.Fatalf("%s: %v\n%s", strings.Join(args, " "), err, raw)
	}
	byLabel := map[string]cliProviderAccount{}
	for _, account := range listed.Accounts {
		byLabel[account.Label] = account
	}
	return byLabel
}

func TestProviderCLIManagesAccountsAndCardsUseThem(t *testing.T) {
	t.Parallel()
	client, output, data, runner := providerDaemonCLI(t)

	workID := strings.TrimSpace(runDaemonCLI(t, client, output, "provider", "add", "claude", "--label", "Work", "--format", "id"))
	if !strings.HasPrefix(workID, "pa_") {
		t.Fatalf("provider add printed %q", workID)
	}
	if text := runDaemonCLI(t, client, output, "provider", "add", "chatgpt", "--label", "Personal"); !strings.Contains(text, `"Personal"`) || !strings.Contains(text, "provider login") {
		t.Fatalf("provider add said %q", text)
	}
	runDaemonCLI(t, client, output, "provider", "add", "claude", "--label", "Side")
	if table := runDaemonCLI(t, client, output, "provider", "list"); !strings.Contains(table, "Work") || !strings.Contains(table, "Personal") || !strings.Contains(table, "Side") {
		t.Fatalf("provider list:\n%s", table)
	}
	accountsByLabel := providerListJSON(t, client, output, "provider", "list")
	if len(accountsByLabel) != 3 || accountsByLabel["Work"].ID != workID || !accountsByLabel["Work"].IsDefault || accountsByLabel["Side"].IsDefault || !accountsByLabel["Personal"].IsDefault {
		t.Fatalf("provider list = %+v", accountsByLabel)
	}
	if ids := runDaemonCLI(t, client, output, "provider", "list", "--provider", "claude", "--format", "ids"); strings.Count(ids, "pa_") != 2 {
		t.Fatalf("Claude IDs:\n%s", ids)
	}

	// Sign-ins by label: a pasted code for Claude, a device code for ChatGPT.
	if text := runDaemonCLI(t, client, output, "provider", "login", "Work", "--code", accounts.FixtureCode); !strings.Contains(text, `Signed in: "Work"`) || !strings.Contains(text, "fixture@example.com") {
		t.Fatalf("provider login Work:\n%s", text)
	}
	if text := runDaemonCLI(t, client, output, "provider", "login", "Personal"); !strings.Contains(text, "FIXT-12345") || !strings.Contains(text, `Signed in: "Personal"`) {
		t.Fatalf("provider login Personal:\n%s", text)
	}
	output.Reset()
	if err := client.Run([]string{"provider", "login", "Side", "--code", "WRONG-CODE"}); err == nil || !strings.Contains(err.Error(), "sign-in failed") {
		t.Fatalf("a wrong code: %v\n%s", err, output.String())
	}
	accountsByLabel = providerListJSON(t, client, output, "provider", "list")
	if accountsByLabel["Work"].state(providerCLIDaemon) != "PROVIDER_LOGIN_STATE_SIGNED_IN" || accountsByLabel["Personal"].state(providerCLIDaemon) != "PROVIDER_LOGIN_STATE_SIGNED_IN" || accountsByLabel["Side"].state(providerCLIDaemon) != "" {
		t.Fatalf("logins after signing in = %+v", accountsByLabel)
	}

	usage := providerListJSON(t, client, output, "provider", "usage", "--refresh")
	if work := usage["Work"]; work.Usage == nil || len(work.Usage.Windows) != 2 || work.Usage.Windows[0].Kind != "five_hour" || work.Usage.Windows[0].UsedPercent <= 0 {
		t.Fatalf("Work usage = %+v", usage["Work"])
	}
	if personal := usage["Personal"]; personal.Usage == nil || personal.Usage.ResetCreditsAvailable != 1 {
		t.Fatalf("Personal usage = %+v", usage["Personal"])
	}
	if table := runDaemonCLI(t, client, output, "provider", "usage", "Work"); !strings.Contains(table, "Work") {
		t.Fatalf("provider usage Work:\n%s", table)
	}

	// --account reaches the conversation by label: a running card's first
	// turn runs on it, a draft keeps it, and a send switches it.
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Path: initTestRepository(t, "provider-cards"), Name: "Accounts"})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	sideID := accountsByLabel["Side"].ID
	draftID := strings.TrimSpace(runDaemonCLI(t, client, output, "card", "create", "--project", project.ID, "--board", board.ID, "--title", "Draft on Side",
		"--prompt", "Wait", "--provider", "claude-code", "--model", "sonnet", "--account", "Side", "--workspace", "project", "--format", "id"))
	if draft, err := data.Kanban.ResolveCard(draftID); err != nil || draft.ProviderAccountID != sideID || draft.InitialPromptSentAt != "" {
		t.Fatalf("draft = %+v, %v", draft, err)
	}
	runningID := strings.TrimSpace(runDaemonCLI(t, client, output, "card", "create", "--project", project.ID, "--board", board.ID, "--title", "Running on Work",
		"--prompt", "Go", "--provider", "claude-code", "--model", "sonnet", "--account", workID, "--workspace", "project", "--lane", "running", "--format", "id"))
	waitProviderCardIdle(t, data, runningID, 0)
	if count := runner.Count(); count != 1 {
		t.Fatalf("%d turns ran, want the running card's first", count)
	}
	if request := runner.Request(0); request.ProviderAccountID != workID || request.Auth == nil || !strings.HasSuffix(request.Environment["CLAUDE_CONFIG_DIR"], "/claude") {
		t.Fatalf("first turn account=%q auth=%#v env=%q", request.ProviderAccountID, request.Auth, request.Environment["CLAUDE_CONFIG_DIR"])
	}
	output.Reset()
	if err := client.Run([]string{"card", "send", "--message", "Next", "--account", "Side", runningID}); err == nil {
		t.Fatal("a send on an account that is not signed in here succeeded")
	}
	runDaemonCLI(t, client, output, "provider", "login", "Side", "--code", accounts.FixtureCode)
	before, err := data.Conversations.Get(runningID)
	if err != nil {
		t.Fatal(err)
	}
	runDaemonCLI(t, client, output, "card", "send", "--message", "Next", "--account", "Side", runningID)
	waitProviderCardIdle(t, data, runningID, before.LastSeq)
	if request := runner.Request(1); request.ProviderAccountID != sideID {
		t.Fatalf("switched turn runs on %q, want %s", request.ProviderAccountID, sideID)
	}
	if card, err := data.Kanban.ResolveCard(runningID); err != nil || card.ProviderAccountID != sideID {
		t.Fatalf("card account after the switch = %q, %v", card.ProviderAccountID, err)
	}
	output.Reset()
	if err := client.Run([]string{"card", "create", "--project", project.ID, "--board", board.ID, "--title", "Unknown", "--provider", "claude-code", "--account", "Nobody", "--workspace", "project"}); err == nil {
		t.Fatal("an unknown --account was accepted")
	}

	// Defaults, sign-out and removal.
	if text := runDaemonCLI(t, client, output, "provider", "default", "Side"); !strings.Contains(text, "default Claude account") {
		t.Fatalf("provider default:\n%s", text)
	}
	accountsByLabel = providerListJSON(t, client, output, "provider", "list")
	if !accountsByLabel["Side"].IsDefault || accountsByLabel["Work"].IsDefault {
		t.Fatalf("defaults = %+v", accountsByLabel)
	}
	runDaemonCLI(t, client, output, "provider", "logout", "Work")
	if state := providerListJSON(t, client, output, "provider", "list")["Work"].state(providerCLIDaemon); state != "PROVIDER_LOGIN_STATE_SIGNED_OUT" {
		t.Fatalf("Work after logout: %s", state)
	}
	output.Reset()
	if err := client.Run([]string{"provider", "remove", "Work"}); err == nil || !strings.Contains(err.Error(), "--confirm REMOVE") {
		t.Fatalf("remove without confirmation: %v", err)
	}
	if text := runDaemonCLI(t, client, output, "provider", "remove", "Work", "--confirm", "REMOVE"); !strings.Contains(text, workID) {
		t.Fatalf("provider remove:\n%s", text)
	}
	if remaining := providerListJSON(t, client, output, "provider", "list"); len(remaining) != 2 || remaining["Work"].ID != "" {
		t.Fatalf("after removal = %+v", remaining)
	}

	// Agent turns may read accounts but never change them.
	client.env.TurnToken = "dtt1:c_agent:turn:any"
	output.Reset()
	if err := client.Run([]string{"provider", "add", "claude", "--label", "Agent"}); err == nil || !strings.Contains(err.Error(), "agents cannot manage provider accounts") {
		t.Fatalf("an agent added an account: %v", err)
	}
}

// waitProviderCardIdle waits until the card's turn after afterSequence ended.
func waitProviderCardIdle(t *testing.T, data *store.Store, cardID string, afterSequence int64) {
	t.Helper()
	testkit.Eventually(t, testkit.Budget(30*time.Second), func() bool {
		card, err := data.Kanban.ResolveCard(cardID)
		leased, leaseErr := data.Leases.CardActive(cardID)
		conversation, conversationErr := data.Conversations.Get(cardID)
		return err == nil && leaseErr == nil && conversationErr == nil && card.Runtime == model.RuntimeIdle && !leased &&
			conversation.LastSeq > afterSequence && conversation.ActiveTurn == nil && len(conversation.Queue) == 0
	}, "the turn of %s to finish", cardID)
	if err := data.WaitForWriter(t.Context()); err != nil {
		t.Fatal(err)
	}
}
