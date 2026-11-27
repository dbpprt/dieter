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
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/testkit/topology"
)

const providerCLIDaemon = "dm_provider_cli"

// providerDaemonCLI is daemonCLIWithRunner with the daemon's accounts engine
// (over the in-process fixture backend) wired into its API and its turns, as
// `dieter serve` does.
func providerDaemonCLI(t *testing.T) (*CLI, *bytes.Buffer, *store.Store, *fakeRunner) {
	t.Helper()
	runner := newFakeRunner()
	client, output, data := providerDaemonCLIWithRunner(t, runner)
	return client, output, data, runner
}

func providerDaemonCLIWithRunner(t *testing.T, runner harness.Runner) (*CLI, *bytes.Buffer, *store.Store) {
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
	service, err := accounts.New(accounts.Options{Store: data, Backend: fixture, Logger: logger, HostHome: t.TempDir(), MachineName: func() string { return "desk" }})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(service.Shutdown)
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
	return client, output, data
}

// providerRouteCLI is a CLI reaching an accounts daemon over route: the
// local loopback, verified direct TLS or the gateway relay (global
// --machine).
func providerRouteCLI(t *testing.T, route string, runner harness.Runner) (*CLI, *bytes.Buffer, *store.Store) {
	t.Helper()
	if route == "local" {
		return providerDaemonCLIWithRunner(t, runner)
	}
	gateway := topology.StartGateway(t, topology.GatewayOptions{})
	identity := topology.Machine(t, gateway, "Provider host", topology.Account)
	data := store.New(identity.Root)
	fixture := accounts.NewFixtureBackend()
	fixture.DeviceApproval = 50 * time.Millisecond
	service, err := accounts.New(accounts.Options{
		Store: data, Backend: fixture, Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		HostHome: t.TempDir(), MachineName: func() string { return "Provider host" },
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(service.Shutdown)
	noReserve := uint64(0)
	app := engine.NewWithOptions(data, engine.Options{Runner: runner, Catalog: testkit.MockCatalog(), MinimumFreeBytes: &noReserve, Accounts: service})
	topology.StartDaemon(t, gateway, topology.DaemonOptions{
		Name: "Provider host", Identity: identity, Store: data, Direct: route == "direct",
		API: api.Options{App: app, Runner: runner, Catalog: testkit.MockCatalog(), MinimumFreeBytes: &noReserve, Accounts: service},
	})
	if _, err := data.Replica.BindPeerAccount(crdt.Revision([]string{identity.Issuer(), "github:42"}), "github:42", identity.ID, identity.Issuer()); err != nil {
		t.Fatal(err)
	}
	output := &bytes.Buffer{}
	client := New(identity.Root)
	client.env.TurnToken = ""
	client.Machine = identity.ID
	client.Timeout = 10 * time.Second
	client.Out, client.Err = output, &bytes.Buffer{}
	t.Cleanup(client.Close)
	return client, output, data
}

type cliProviderAccount struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Provider  string `json:"provider"`
	IsDefault bool   `json:"isDefault"`
	OMPAccess bool   `json:"ompAccess"`
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

// providerTableRow is the `provider list` row of label, whitespace-collapsed.
func providerTableRow(table, label string) string {
	for _, line := range strings.Split(table, "\n") {
		fields := strings.Fields(line)
		if len(fields) > 2 && fields[2] == label {
			return strings.Join(fields, " ")
		}
	}
	return ""
}

// The Oh My Pi opt-in works over every route; the token helper Oh My Pi runs
// never leaves the turn's own machine.
func TestProviderOMPAccessCLIAcrossRoutes(t *testing.T) {
	for _, route := range []string{"local", "direct", "relay"} {
		t.Run(route, func(t *testing.T) {
			t.Parallel()
			client, output, _ := providerRouteCLI(t, route, newFakeRunner())
			workID := strings.TrimSpace(runDaemonCLI(t, client, output, "provider", "add", "claude", "--label", "Work", "--format", "id"))
			runDaemonCLI(t, client, output, "provider", "add", "chatgpt", "--label", "Chat")
			table := runDaemonCLI(t, client, output, "provider", "list")
			if !strings.Contains(table, "OMP") || !strings.HasPrefix(providerTableRow(table, "Work"), workID+" claude Work claude-code yes off ") || !strings.HasPrefix(providerTableRow(table, "Chat"), "pa_") || !strings.Contains(providerTableRow(table, "Chat"), " yes - ") {
				t.Fatalf("provider list before the opt-in:\n%s", table)
			}

			if text := runDaemonCLI(t, client, output, "provider", "omp-access", "Work", "on"); !strings.Contains(text, `Oh My Pi turns may now use "Work"`) || !strings.Contains(text, "Anthropic does not permit") {
				t.Fatalf("omp-access on said %q", text)
			}
			if listed := providerListJSON(t, client, output, "provider", "list"); !listed["Work"].OMPAccess || listed["Chat"].OMPAccess {
				t.Fatalf("accounts after the opt-in = %+v", listed)
			}
			if row := providerTableRow(runDaemonCLI(t, client, output, "provider", "list"), "Work"); !strings.Contains(row, " yes on ") {
				t.Fatalf("Work row after the opt-in = %q", row)
			}
			output.Reset()
			if err := client.Run([]string{"provider", "omp-access", "Chat", "on"}); err == nil || !strings.Contains(err.Error(), "only Claude accounts") {
				t.Fatalf("omp-access on a ChatGPT account: %v", err)
			}
			raw := runDaemonCLI(t, client, output, "provider", "omp-access", workID, "off", "--format", "json")
			var turnedOff cliProviderAccount
			if err := json.Unmarshal([]byte(raw), &turnedOff); err != nil || turnedOff.ID != workID || turnedOff.OMPAccess {
				t.Fatalf("omp-access off = %s, %v", raw, err)
			}
			if listed := providerListJSON(t, client, output, "provider", "list"); listed["Work"].OMPAccess {
				t.Fatalf("Work after the opt-out = %+v", listed["Work"])
			}

			// Outside a turn, and from a turn over --machine, the token
			// helper refuses before reaching any daemon; agents never toggle
			// the opt-in.
			output.Reset()
			if err := client.Run([]string{"provider", "token", "--turn", "--provider", "claude"}); err == nil || !strings.Contains(err.Error(), "DIETER_TURN_TOKEN") {
				t.Fatalf("token outside a turn: %v", err)
			}
			client.env.TurnToken = "dtt1:c_agent:turn:any"
			if route != "local" {
				if err := client.Run([]string{"provider", "token", "--turn", "--provider", "chatgpt"}); err == nil || !strings.Contains(err.Error(), "omit --machine") {
					t.Fatalf("token over %s: %v", route, err)
				}
			}
			if err := client.Run([]string{"provider", "omp-access", "Work", "on"}); err == nil || !strings.Contains(err.Error(), "agents cannot manage provider accounts") {
				t.Fatalf("an agent toggled the opt-in: %v", err)
			}
			client.env.TurnToken = ""
			if listed := providerListJSON(t, client, output, "provider", "list"); listed["Work"].OMPAccess {
				t.Fatalf("Work after the refused agent toggle = %+v", listed["Work"])
			}
			if client.transport == nil || client.transport.route != route {
				t.Fatalf("route = %+v, want %s", client.transport, route)
			}
		})
	}
}

// Inside a live Oh My Pi turn, `dieter provider token --turn --provider P`
// prints the access token of the turn's account for P: the implementation
// model's Claude login and the advisor's ChatGPT login.
func TestProviderTokenCLIServesAnOMPTurnsAccounts(t *testing.T) {
	t.Parallel()
	runner := &fakeRunner{Release: make(chan struct{})}
	client, output, data := providerDaemonCLIWithRunner(t, runner)
	released := false
	release := func() {
		if !released {
			released = true
			close(runner.Release)
		}
	}
	t.Cleanup(release)
	runDaemonCLI(t, client, output, "provider", "add", "claude", "--label", "Work")
	chatID := strings.TrimSpace(runDaemonCLI(t, client, output, "provider", "add", "chatgpt", "--label", "Chat", "--format", "id"))
	runDaemonCLI(t, client, output, "provider", "login", "Work", "--code", accounts.FixtureCode)
	runDaemonCLI(t, client, output, "provider", "login", "Chat")
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Path: initTestRepository(t, "omp-tokens"), Name: "Oh My Pi"})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	create := []string{"card", "create", "--project", project.ID, "--board", board.ID, "--title", "Oh My Pi", "--prompt", "Go",
		"--provider", "omp", "--model", "anthropic/claude-sonnet-5-5", "--account", "Work", "--provider-option", "advisor_model=openai-codex/gpt-6-sol",
		"--workspace", "project", "--lane", "running", "--format", "id"}
	// Without the opt-in the turn does not start.
	output.Reset()
	if err := client.Run(create); err == nil || !strings.Contains(err.Error(), "Allow Oh My Pi to use Work") {
		t.Fatalf("an Oh My Pi turn on Work without the opt-in: %v\n%s", err, output.String())
	}
	runDaemonCLI(t, client, output, "provider", "omp-access", "Work", "on")
	cardID := strings.TrimSpace(runDaemonCLI(t, client, output, create...))
	testkit.Eventually(t, testkit.Budget(30*time.Second), func() bool { return runner.Count() == 1 }, "the Oh My Pi turn to start")
	request := runner.Request(0)
	if request.Adapter != "omp-acp" || request.Options["advisor_account"] != chatID {
		t.Fatalf("Oh My Pi turn: adapter=%q options=%v", request.Adapter, request.Options)
	}

	// Oh My Pi runs the helper as its own process with the turn's token.
	agent, agentOutput := New(data.Root), &bytes.Buffer{}
	agent.env.TurnToken = request.Environment["DIETER_TURN_TOKEN"]
	agent.Timeout = 10 * time.Second
	agent.Out, agent.Err = agentOutput, &bytes.Buffer{}
	t.Cleanup(agent.Close)
	if token := runDaemonCLI(t, agent, agentOutput, "provider", "token", "--turn", "--provider", "claude"); !strings.HasPrefix(token, "sk-ant-oat01-fixture-") || strings.Count(token, "\n") != 1 {
		t.Fatalf("Claude token output = %q", token)
	}
	if token := strings.TrimSpace(runDaemonCLI(t, agent, agentOutput, "provider", "token", "--turn", "--provider", "chatgpt")); strings.Count(token, ".") != 2 {
		t.Fatalf("ChatGPT token output = %q", token)
	}
	agentOutput.Reset()
	if err := agent.Run([]string{"provider", "token", "--turn"}); err == nil || !strings.Contains(err.Error(), "Sign in with ChatGPT") || agentOutput.Len() != 0 {
		t.Fatalf("token without --provider in an Oh My Pi turn: %v, %q", err, agentOutput.String())
	}
	// Turning the opt-in off refuses the turn's next Claude token.
	runDaemonCLI(t, client, output, "provider", "omp-access", "Work", "off")
	agentOutput.Reset()
	if err := agent.Run([]string{"provider", "token", "--turn", "--provider", "claude"}); err == nil || !strings.Contains(err.Error(), "Allow Oh My Pi to use Work") || agentOutput.Len() != 0 {
		t.Fatalf("Claude token after the opt-out: %v, %q", err, agentOutput.String())
	}
	release()
	waitProviderCardIdle(t, data, cardID, 0)
}
