//go:build e2e

package cli

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/security/vault"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/vaults"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/testkit/topology"
)

func TestAgentCLICanLaunchStrixAcrossRoutes(t *testing.T) {
	for _, route := range []string{"local", "direct", "relay"} {
		t.Run(route, func(t *testing.T) {
			t.Parallel()
			runner := &testkit.FakeRunner{Release: make(chan struct{})}
			var client *CLI
			var output *bytes.Buffer
			var data *store.Store
			if route == "local" {
				client, output, data = daemonCLIWithRunner(t, runner)
			} else {
				gateway := topology.StartGateway(t, topology.GatewayOptions{})
				identity, err := gateway.Enroll(t.Context(), t.TempDir(), "Scan host", topology.Account)
				if err != nil {
					t.Fatal(err)
				}
				data = testkit.Store(t)
				topology.StartDaemon(t, gateway, topology.DaemonOptions{Identity: identity, Store: data, Direct: route == "direct",
					API: api.Options{Runner: runner, Catalog: testkit.MockCatalog()}})
				client = New(identity.Root)
				client.Machine = identity.ID
				client.Timeout = 10 * time.Second
				output = &bytes.Buffer{}
				client.Out, client.Err = output, output
				t.Cleanup(client.Close)
			}
			client.env.TurnToken = ""
			assertStrixAutomationCLI(t, client, output, data, runner)
			want := route
			if client.transport == nil || client.transport.route != want {
				t.Fatalf("route = %+v, want %s", client.transport, want)
			}
		})
	}
}

func assertStrixAutomationCLI(t *testing.T, client *CLI, output *bytes.Buffer, data *store.Store, runner *testkit.FakeRunner) {
	t.Helper()
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Scans", Path: testkit.GitRepo(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	secrets := vaults.New(data)
	if _, err := secrets.Init("test", "d_test"); err != nil {
		t.Fatal(err)
	}
	if _, err := secrets.CreateItem(vault.Item{Name: "strix", Password: "fixture-model-key", Notes: "STRIX_LLM=openai/test"}, "operator"); err != nil {
		t.Fatal(err)
	}
	var cards []string
	t.Cleanup(func() {
		close(runner.Release)
		for _, id := range cards {
			testkit.Eventually(t, 30*time.Second, func() bool {
				conversation, err := data.Conversations.Get(id)
				active, leaseErr := data.Leases.CardActive(id)
				return err == nil && leaseErr == nil && !active && conversation.ActiveTurn == nil && len(conversation.Queue) == 0
			}, "scan and queued follow-up to finish")
		}
		// Scan completion publishes Review and channel bookkeeping after the
		// active lease clears. Wait for those writes before removing the home.
		last, _ := data.ChangeCount()
		stable := time.Now()
		testkit.Eventually(t, 10*time.Second, func() bool {
			next, err := data.ChangeCount()
			if err != nil || next != last {
				last, stable = next, time.Now()
				return false
			}
			return time.Since(stable) >= 300*time.Millisecond
		}, "post-turn bookkeeping to settle")
	})
	parent := strings.TrimSpace(runDaemonCLI(t, client, output, "card", "create", "--project", project.ID, "--board", board.ID,
		"--title", "Coder", "--prompt", "Work", "--workspace", "project", "--provider", "mock", "--model", "mock", "--lane", "running", "--format", "id"))
	cards = append(cards, parent)
	testkit.Eventually(t, 30*time.Second, func() bool { return runner.Count() == 1 }, "parent turn")
	client.Close()
	client.env.TurnToken = runner.Request(0).Environment["DIETER_TURN_TOKEN"]
	if client.env.TurnToken == "" {
		t.Fatal("parent turn supplied no token")
	}
	for _, operation := range []string{"create", "chat", "start", "move", "send"} {
		group := "card"
		if operation == "chat" {
			group = "chat"
		}
		args := []string{group, "create", "--project", project.ID, "--title", operation, "--prompt", "Scan for injection",
			"--workspace", "worktree", "--provider", "strix", "--format", "id"}
		if group == "card" {
			lane := model.LaneTodo
			if operation == "create" {
				lane = model.LaneRunning
			}
			args = append(args, "--board", board.ID, "--lane", lane)
		}
		before := runner.Count()
		id := strings.TrimSpace(runDaemonCLI(t, client, output, args...))
		cards = append(cards, id)
		switch operation {
		case "start":
			runDaemonCLI(t, client, output, "card", "start", id)
		case "move":
			runDaemonCLI(t, client, output, "card", "move", id, "--lane", "running")
		case "send":
			runDaemonCLI(t, client, output, "card", "send", id, "--message", "Scan for injection")
		}
		testkit.Eventually(t, 30*time.Second, func() bool { return runner.Count() == before+1 }, "automated scan")
		request := runner.Request(before)
		if request.Adapter != "strix" || request.Prompt != "Scan for injection" || request.SteerEnabled || request.Environment["LLM_API_KEY"] != "fixture-model-key" {
			t.Fatalf("scan request = %+v", request)
		}
		runDaemonCLI(t, client, output, group, "send", id, "--message", "Validate the finding")
		conversation, err := data.Conversations.Get(id)
		if err != nil || len(conversation.Queue) != 1 || runner.Count() != before+1 {
			t.Fatalf("follow-up not queued: %+v, %v", conversation, err)
		}
	}
}
