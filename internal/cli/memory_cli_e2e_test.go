//go:build e2e

package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/testkit/topology"
)

func TestMemoryCLIAcrossRoutes(t *testing.T) {
	for _, route := range []string{"local", "direct", "relay"} {
		t.Run(route, func(t *testing.T) {
			t.Parallel()
			runner := &testkit.FakeRunner{Reply: func(harness.Request) string {
				return "The release tag was missing, so the rollback job could not find the previous build."
			}}
			var client *CLI
			var output *bytes.Buffer
			var data *store.Store
			if route == "local" {
				client, output, data = daemonCLIWithRunner(t, runner)
				if _, err := data.Replica.BindPeerAccount("account", "subject", "dm_memory_cli", "https://gateway.test"); err != nil {
					t.Fatal(err)
				}
			} else {
				gateway := topology.StartGateway(t, topology.GatewayOptions{})
				identity, err := gateway.Enroll(t.Context(), t.TempDir(), "Memory host", topology.Account)
				if err != nil {
					t.Fatal(err)
				}
				data = testkit.Store(t)
				topology.StartDaemon(t, gateway, topology.DaemonOptions{Identity: identity, Store: data, Direct: route == "direct",
					API: api.Options{Runner: runner, Catalog: testkit.MockCatalog()}})
				if _, err := data.Replica.BindPeerAccount(crdt.Revision([]string{identity.Issuer(), "github:42"}), "github:42", identity.ID, identity.Issuer()); err != nil {
					t.Fatal(err)
				}
				client = New(identity.Root)
				client.Machine = identity.ID
				client.Timeout = 10 * time.Second
				output = &bytes.Buffer{}
				client.Out, client.Err = output, output
				t.Cleanup(client.Close)
			}
			client.env.TurnToken = ""
			assertMemoryCLI(t, client, output, data)
			if client.transport == nil || client.transport.route != route {
				t.Fatalf("route = %+v, want %s", client.transport, route)
			}
		})
	}
}

func assertMemoryCLI(t *testing.T, client *CLI, output *bytes.Buffer, data *store.Store) {
	t.Helper()
	t.Cleanup(func() {
		last, _ := data.ChangeCount()
		stable := time.Now()
		testkit.Eventually(t, 10*time.Second, func() bool {
			next, err := data.ChangeCount()
			if err != nil || next != last {
				last, stable = next, time.Now()
				return false
			}
			return time.Since(stable) >= 300*time.Millisecond
		}, "turn bookkeeping to settle")
	})
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Remembered", Path: testkit.GitRepo(t), InitialBoardName: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	if out := runDaemonCLI(t, client, output, "memory", "status"); !strings.Contains(out, "No project has memory on") {
		t.Fatalf("status before memory=%q", out)
	}
	runDaemonCLI(t, client, output, "project", "update", "--memory=true", project.ID)

	var settings struct {
		Dreaming   bool   `json:"dreaming"`
		Harness    string `json:"harness"`
		Apply      string `json:"apply"`
		MinHours   int    `json:"minHours"`
		Configured bool   `json:"configured"`
	}
	if err := json.Unmarshal([]byte(runDaemonCLI(t, client, output, "memory", "settings", "--format", "json")), &settings); err != nil || settings.Configured || settings.MinHours != 24 {
		t.Fatalf("default settings=%+v err=%v", settings, err)
	}
	if err := json.Unmarshal([]byte(runDaemonCLI(t, client, output, "memory", "settings", "update", "--harness", "mock", "--apply", "review", "--min-hours", "6", "--format", "json")), &settings); err != nil ||
		!settings.Configured || settings.Harness != "mock" || settings.Apply != "review" || settings.MinHours != 6 || settings.Dreaming {
		t.Fatalf("updated settings=%+v err=%v", settings, err)
	}

	chat := strings.TrimSpace(runDaemonCLI(t, client, output, "chat", "create", "--project", project.ID, "--title", "Rollback failed",
		"--prompt", "Why did the production rollback fail?", "--workspace", "project", "--provider", "mock", "--model", "mock", "--format", "id"))
	card, err := data.Kanban.ResolveCard(chat)
	if err != nil || !card.Memory {
		t.Fatalf("chat of a memory project=%+v err=%v", card, err)
	}
	testkit.Eventually(t, 30*time.Second, func() bool {
		active, err := data.Leases.CardActive(chat)
		return err == nil && !active
	}, "the first turn to finish")
	if out := runDaemonCLI(t, client, output, "memory", "reindex", "--project", project.ID); !strings.Contains(out, "1 conversations") {
		t.Fatalf("reindex=%q", out)
	}
	found := runDaemonCLI(t, client, output, "memory", "search", "--project", project.ID, "rollback", "release", "tag")
	for _, want := range []string{"Conversations:", "1. " + chat, "Rollback failed", "Answer: The release tag was missing"} {
		if !strings.Contains(found, want) {
			t.Fatalf("search lacks %q:\n%s", want, found)
		}
	}

	saved := runDaemonCLI(t, client, output, "memory", "save", "--project", project.ID, "--kind", "lesson", "--source", chat, "Tag every release before deploying so rollbacks can find the previous build.")
	if !strings.HasPrefix(saved, "Saved mem_") {
		t.Fatalf("save=%q", saved)
	}
	memoryID := strings.Fields(saved)[1]
	if again := runDaemonCLI(t, client, output, "memory", "save", "--project", project.ID, "--kind", "lesson", "Tag every release before deploying so rollbacks can find the previous build."); !strings.Contains(again, "Reinforced lesson "+memoryID) {
		t.Fatalf("second save=%q", again)
	}
	var result struct {
		Memories []struct {
			ID             string   `json:"id"`
			Kind           string   `json:"kind"`
			Sources        []string `json:"sources"`
			Reinforcements int      `json:"reinforcements"`
		} `json:"memories"`
	}
	if err := json.Unmarshal([]byte(runDaemonCLI(t, client, output, "memory", "search", "--project", project.ID, "--kind", "lesson", "--format", "json", "release", "rollback")), &result); err != nil ||
		len(result.Memories) != 1 || result.Memories[0].ID != memoryID || result.Memories[0].Reinforcements != 1 || len(result.Memories[0].Sources) != 1 {
		t.Fatalf("memory search=%+v err=%v", result, err)
	}
	if status := runDaemonCLI(t, client, output, "memory", "status", "--project", project.ID); !strings.Contains(status, "1 conversations") || !strings.Contains(status, "1 active") {
		t.Fatalf("status=%q", status)
	}

	if out := runDaemonCLI(t, client, output, "chat", "memory", chat, "off"); !strings.Contains(out, "Memory off for "+chat) {
		t.Fatalf("switch off=%q", out)
	}
	if card, _ = data.Kanban.ResolveCard(chat); card.Memory {
		t.Fatal("the switch did not reach the card")
	}

	started := runDaemonCLI(t, client, output, "memory", "dream", "start", project.ID)
	if !strings.HasPrefix(started, "Dream c_") {
		t.Fatalf("dream start=%q", started)
	}
	dream := strings.Fields(started)[1]
	testkit.Eventually(t, 30*time.Second, func() bool {
		output.Reset()
		return client.Run([]string{"memory", "dream", "list", project.ID}) == nil && strings.Contains(output.String(), dream+"\tempty")
	}, "the mock dream to end without changes")
	if out := runDaemonCLI(t, client, output, "memory", "dream", "discard", dream); !strings.Contains(out, "is discarded") {
		t.Fatalf("discard=%q", out)
	}
	output.Reset()
	if err := client.Run([]string{"memory", "dream", "undo", dream}); err == nil || !strings.Contains(err.Error(), "only an applied dream") {
		t.Fatalf("undo of a discarded dream: %v", err)
	}

	runDaemonCLI(t, client, output, "memory", "forget", "--project", project.ID, "--memory", memoryID)
	runDaemonCLI(t, client, output, "memory", "forget", "--project", project.ID, "--card", chat)
	if out := runDaemonCLI(t, client, output, "memory", "search", "--project", project.ID, "rollback"); !strings.Contains(out, "Nothing in memory matches") {
		t.Fatalf("search after forget=%q", out)
	}
}

// Inside an agent turn the CLI refuses a person's memory changes before it
// contacts any daemon.
func TestMemoryCLIRefusesAgentMutations(t *testing.T) {
	client, output, _ := daemonCLIWithRunner(t, &testkit.FakeRunner{})
	client.env.TurnToken = "dtt1:card:turn:mac"
	for _, args := range [][]string{
		{"memory", "forget", "--project", "p", "--all"},
		{"memory", "reindex", "--project", "p"},
		{"memory", "settings", "update", "--dreaming", "on"},
		{"memory", "dream", "start", "p"},
		{"memory", "dream", "undo", "c_1"},
		{"card", "memory", "c_1", "off"},
	} {
		output.Reset()
		if err := client.Run(args); err == nil || !strings.Contains(err.Error(), "agent turns cannot") {
			t.Errorf("dieter %s: %v", strings.Join(args, " "), err)
		}
	}
}
