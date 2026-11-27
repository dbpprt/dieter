//go:build e2e

package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
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

// reviewerReply answers reviewer turns with one finding on notes.txt and
// every other turn with "done".
func reviewerReply(request harness.Request) string {
	if !strings.HasPrefix(request.Instructions, "You are Dieter's code reviewer.") {
		return "done"
	}
	return "```json\n" + `{"summary":"Adds notes.","findings":[{"file":"notes.txt","start_line":1,"severity":"medium","confidence":7,"title":"Unclear note","body":"The note does not say what it is for.","suggestion":"Say why."}],"security_concerns":"No"}` + "\n```"
}

func TestReviewerCLIAcrossRoutes(t *testing.T) {
	codeReviewPollInterval = 50 * time.Millisecond
	for _, route := range []string{"local", "direct", "relay"} {
		t.Run(route, func(t *testing.T) {
			t.Parallel()
			runner := &testkit.FakeRunner{Reply: reviewerReply}
			var client *CLI
			var output *bytes.Buffer
			var data *store.Store
			if route == "local" {
				client, output, data = daemonCLIWithRunner(t, runner)
				if _, err := data.Replica.BindPeerAccount("account", "subject", "dm_review_cli", "https://gateway.test"); err != nil {
					t.Fatal(err)
				}
			} else {
				gateway := topology.StartGateway(t, topology.GatewayOptions{})
				identity, err := gateway.Enroll(t.Context(), t.TempDir(), "Review host", topology.Account)
				if err != nil {
					t.Fatal(err)
				}
				data = testkit.Store(t)
				topology.StartDaemon(t, gateway, topology.DaemonOptions{Identity: identity, Store: data, Direct: route == "direct",
					API: api.Options{Runner: runner, Catalog: testkit.MockCatalog()}})
				// The account's replica identity, as discovery binds it.
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
			assertReviewerCLI(t, client, output, data)
			if client.transport == nil || client.transport.route != route {
				t.Fatalf("route = %+v, want %s", client.transport, route)
			}
		})
	}
}

func assertReviewerCLI(t *testing.T, client *CLI, output *bytes.Buffer, data *store.Store) {
	t.Helper()
	t.Cleanup(func() {
		// Reviews and turns finish with bookkeeping writes; let them settle
		// before the home is removed.
		last, _ := data.ChangeCount()
		stable := time.Now()
		testkit.Eventually(t, 10*time.Second, func() bool {
			next, err := data.ChangeCount()
			if err != nil || next != last {
				last, stable = next, time.Now()
				return false
			}
			return time.Since(stable) >= 300*time.Millisecond
		}, "review bookkeeping to settle")
	})
	var settings struct {
		Harness     string `json:"harness"`
		Depth       string `json:"depth"`
		MaxFindings int    `json:"maxFindings"`
		Configured  bool   `json:"configured"`
	}
	if err := json.Unmarshal([]byte(runDaemonCLI(t, client, output, "reviewer", "show", "--format", "json")), &settings); err != nil || settings.Configured {
		t.Fatalf("defaults=%+v err=%v", settings, err)
	}
	if err := json.Unmarshal([]byte(runDaemonCLI(t, client, output, "reviewer", "update", "--harness", "mock", "--max-findings", "4", "--format", "json")), &settings); err != nil ||
		!settings.Configured || settings.Harness != "mock" || settings.MaxFindings != 4 || settings.Depth != "quick" {
		t.Fatalf("updated=%+v err=%v", settings, err)
	}

	repository := testkit.GitRepo(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Reviewed", Path: repository})
	if err != nil {
		t.Fatal(err)
	}
	chat := strings.TrimSpace(runDaemonCLI(t, client, output, "chat", "create", "--project", project.ID, "--title", "Notes",
		"--prompt", "Write notes", "--workspace", "project", "--provider", "mock", "--model", "mock", "--code-review", "--format", "id"))
	card, err := data.Kanban.ResolveCard(chat)
	if err != nil || !card.CodeReview {
		t.Fatalf("created chat=%+v err=%v", card, err)
	}
	testkit.Eventually(t, 30*time.Second, func() bool {
		active, err := data.Leases.CardActive(chat)
		return err == nil && !active
	}, "the first turn to finish")
	if out := runDaemonCLI(t, client, output, "chat", "reviewer", chat, "off"); !strings.Contains(out, "Code reviewer off") {
		t.Fatalf("switch off=%q", out)
	}
	if out := runDaemonCLI(t, client, output, "chat", "reviewer", chat, "on"); !strings.Contains(out, "Code reviewer on") {
		t.Fatalf("switch on=%q", out)
	}

	if err := os.WriteFile(filepath.Join(repository, "notes.txt"), []byte("remember the milk\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	review := runDaemonCLI(t, client, output, "chat", "review", "--wait", chat)
	for _, want := range []string{"(round 1, quick, mock", "of 1 files, +1 -0", "Summary: Adds notes.", "[f1] Unclear note (medium, confidence 7) notes.txt:1", "Suggestion: Say why."} {
		if !strings.Contains(review, want) {
			t.Fatalf("review output lacks %q:\n%s", want, review)
		}
	}
	if list := runDaemonCLI(t, client, output, "chat", "reviews", chat); !strings.Contains(list, "completed\tround 1\t1 finding\tuser") {
		t.Fatalf("reviews=%q", list)
	}
	if status := testkit.RunGit(t, repository, "status", "--porcelain"); status != "?? notes.txt" {
		t.Fatalf("the review changed the checkout: %q", status)
	}
}
