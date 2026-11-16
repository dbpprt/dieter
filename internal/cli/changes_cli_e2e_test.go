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

	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/testkit/topology"
)

// A project-directory conversation's changes are its checkout's, over every
// route: read, diff, watch, stage and commit through the conversation.
func TestConversationChangesCLILocal(t *testing.T) {
	t.Parallel()
	client, out, _ := daemonCLIForTest(t)
	client.env.TurnToken = ""
	assertConversationChanges(t, client, out)
}

func TestConversationChangesCLIRoutes(t *testing.T) {
	for _, route := range []string{"direct", "relay"} {
		t.Run(route, func(t *testing.T) {
			t.Parallel()
			g := topology.StartGateway(t, topology.GatewayOptions{Issuer: "https://changes.example.test"})
			identity := topology.Machine(t, g, "changes", topology.Account)
			data := testkit.Store(t)
			topology.StartDaemon(t, g, topology.DaemonOptions{Identity: identity, Store: data, Direct: route == "direct"})
			client := New(identity.Root)
			defer client.Close()
			client.env.TurnToken = ""
			client.Machine = identity.ID
			client.GatewayURL = g.URL
			client.Timeout = testkit.Budget(60 * time.Second)
			var out bytes.Buffer
			client.Out, client.Err = &out, &out
			assertConversationChanges(t, client, &out)
			if client.transport.route != route {
				t.Fatalf("route %s, want %s", client.transport.route, route)
			}
		})
	}
}

type changedFileJSON struct {
	Path              string `json:"path"`
	Revision          string `json:"revision"`
	Staged            bool   `json:"staged"`
	Unstaged          bool   `json:"unstaged"`
	UnstagedAdditions int    `json:"unstagedAdditions"`
}

type changesetJSON struct {
	CardID           string            `json:"cardId"`
	Scope            string            `json:"scope"`
	IndexFingerprint string            `json:"indexFingerprint"`
	Files            []changedFileJSON `json:"files"`
}

func assertConversationChanges(t *testing.T, c *CLI, out *bytes.Buffer) {
	t.Helper()
	repository := testkit.GitRepo(t)
	projectJSON := runDaemonCLI(t, c, out, "project", "open", "--name", "Changes", "--base-branch", "main", "--format", "json", repository)
	var created struct {
		Project struct {
			ID string `json:"id"`
		} `json:"project"`
	}
	if err := json.Unmarshal([]byte(projectJSON), &created); err != nil || created.Project.ID == "" {
		t.Fatalf("project JSON=%q err=%v", projectJSON, err)
	}
	chatJSON := runDaemonCLI(t, c, out, "chat", "create", "--project", created.Project.ID, "--title", "In place", "--prompt", "work", "--workspace", "project", "--provider", "mock", "--model", "mock")
	var chat struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(chatJSON), &chat); err != nil || chat.ID == "" {
		t.Fatalf("chat JSON=%q err=%v", chatJSON, err)
	}
	if err := os.WriteFile(filepath.Join(repository, "README.md"), []byte("edited in place\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repository, "agent.txt"), []byte("agent\nwork\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	read := func() changesetJSON {
		t.Helper()
		raw := runDaemonCLI(t, c, out, "workspace", "changes", chat.ID)
		var value changesetJSON
		if err := json.Unmarshal([]byte(raw), &value); err != nil {
			t.Fatalf("changes JSON=%q err=%v", raw, err)
		}
		return value
	}
	changes := read()
	if changes.Scope != "checkout" || changes.CardID != chat.ID || len(changes.Files) != 2 {
		t.Fatalf("conversation changes=%#v", changes)
	}
	if diff := runDaemonCLI(t, c, out, "workspace", "diff", "--path", "agent.txt", "--section", "unstaged", chat.ID); !strings.Contains(diff, "+work") {
		t.Fatalf("conversation diff=%q", diff)
	}
	watched := runDaemonCLI(t, c, out, "workspace", "watch-changes", "--count", "1", chat.ID)
	if !strings.Contains(watched, `"scope":"checkout"`) || !strings.Contains(watched, "agent.txt") {
		t.Fatalf("watched=%q", watched)
	}
	// The CLI pins the files it stages; agent.txt changing does not affect README.md.
	readme := ""
	for _, file := range changes.Files {
		if file.Path == "README.md" {
			readme = file.Revision
		}
	}
	if err := os.WriteFile(filepath.Join(repository, "agent.txt"), []byte("agent\nwork\nmore\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	staged := runDaemonCLI(t, c, out, "workspace", "run", "--kind", "stage", "--expect", "README.md="+readme, "--param", "path=README.md", "--wait", chat.ID)
	if !strings.Contains(staged, `"succeeded"`) {
		t.Fatalf("stage through the conversation: %s", staged)
	}
	committed := runDaemonCLI(t, c, out, "workspace", "run", "--kind", "commit", "--param", "subject=In place", "--param", "validate=false", "--wait", chat.ID)
	if !strings.Contains(committed, `"succeeded"`) {
		t.Fatalf("commit through the conversation: %s", committed)
	}
	after := read()
	if len(after.Files) != 1 || after.Files[0].Path != "agent.txt" || after.Files[0].UnstagedAdditions != 3 {
		t.Fatalf("after the commit=%#v", after)
	}
}
