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

func TestFolderCLILocal(t *testing.T) {
	t.Parallel()
	client, out, _ := daemonCLIForTest(t)
	client.env.TurnToken = ""
	assertFolderCommands(t, client, out)
}

func TestFolderCLIRoutes(t *testing.T) {
	for _, route := range []string{"direct", "relay"} {
		t.Run(route, func(t *testing.T) {
			t.Parallel()
			g := topology.StartGateway(t, topology.GatewayOptions{Issuer: "https://folders.example.test"})
			identity := topology.Machine(t, g, "folders", topology.Account)
			data := testkit.Store(t)
			topology.StartDaemon(t, g, topology.DaemonOptions{Identity: identity, Store: data, Direct: route == "direct"})
			client := New(identity.Root)
			defer client.Close()
			client.env.TurnToken = ""
			client.Machine = identity.ID
			client.GatewayURL = g.URL
			client.Timeout = testkit.Budget(60 * time.Second)
			var out bytes.Buffer
			client.Out = &out
			client.Err = &out
			assertFolderCommands(t, client, &out)
			if client.transport.route != route {
				t.Fatalf("route %s, want %s", client.transport.route, route)
			}
		})
	}
}

// Agent turns cannot change folders even on another machine: the CLI refuses
// before it contacts any daemon.
func TestFolderCLIRefusesChangesInsideATurn(t *testing.T) {
	t.Parallel()
	client := New(t.TempDir())
	defer client.Close()
	client.env.TurnToken = "dtt1:c_card:turn_1:token"
	client.Machine = "some-other-machine"
	var out bytes.Buffer
	client.Out, client.Err = &out, &out
	for _, args := range [][]string{
		{"folder", "create", "Inbox"}, {"folder", "attach", "Inbox", "/tmp/x"}, {"folder", "detach", "Inbox"},
		{"folder", "pause", "Inbox"}, {"folder", "update", "Inbox", "--name", "Other"}, {"folder", "archive", "Inbox"},
		{"folder", "deletions", "Inbox", "--apply"}, {"folder", "trash", "purge", "Inbox"},
		{"folder", "client", "register", "Inbox", "--device", "dv_x"},
	} {
		err := client.Run(args)
		if err == nil || !strings.Contains(err.Error(), "agent turns cannot change synced folders") {
			t.Errorf("%v: %v", args, err)
		}
	}
}

func assertFolderCommands(t *testing.T, c *CLI, out *bytes.Buffer) {
	t.Helper()
	run := func(args ...string) string {
		t.Helper()
		out.Reset()
		if err := c.Run(append([]string{"folder"}, args...)); err != nil {
			t.Fatalf("folder %v: %v\n%s", args, err, out.String())
		}
		return out.String()
	}
	id := strings.TrimSpace(run("create", "Reports", "--rule", "-*.log", "--trash-days", "7", "--format", "id"))
	if !strings.HasPrefix(id, "fo_") {
		t.Fatalf("create id %q", id)
	}
	if listed := run("list"); !strings.Contains(listed, "Reports") || !strings.Contains(listed, id) {
		t.Fatal(listed)
	}
	var shown struct {
		Name      string   `json:"name"`
		Rules     []string `json:"rules"`
		TrashDays int      `json:"trashDays"`
	}
	if err := json.Unmarshal([]byte(run("show", "Reports", "--format", "json")), &shown); err != nil || shown.TrashDays != 7 || shown.Rules[len(shown.Rules)-1] != "-*.log" {
		t.Fatalf("show = %+v, %v", shown, err)
	}
	dir := filepath.Join(t.TempDir(), "reports")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "existing.md"), []byte("# existing"), 0o644); err != nil {
		t.Fatal(err)
	}
	if plan := run("attach", "Reports", dir, "--dryrun"); !strings.Contains(plan, "new      existing.md") {
		t.Fatalf("plan:\n%s", plan)
	}
	if attached := run("attach", "Reports", dir, "--mode", "two-way"); !strings.Contains(attached, "Attached") {
		t.Fatal(attached)
	}
	if member := run("member", "Reports"); !strings.Contains(member, dir) && !strings.Contains(member, filepath.Base(dir)) {
		t.Fatalf("member:\n%s", member)
	}
	run("member", "Reports", "--concurrency", "2", "--rescan", "600")
	run("pause", "Reports")
	if status := run("status", "Reports"); !strings.Contains(status, "paused") {
		t.Fatalf("status after pause:\n%s", status)
	}
	run("resume", "Reports")
	run("rescan", "Reports")
	if page := run("index", id); !strings.Contains(page, "indexId") {
		t.Fatalf("index page:\n%s", page)
	}
	// File transfers reach the machine's copy of the folder.
	local := filepath.Join(t.TempDir(), "note.txt")
	if err := os.WriteFile(local, []byte("from the CLI"), 0o644); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := c.Run([]string{"file", "cp", "--folder", "Reports", "--no-progress", local, "remote:inbox/note.txt"}); err != nil {
		t.Fatalf("file cp --folder: %v\n%s", err, out.String())
	}
	if b, err := os.ReadFile(filepath.Join(dir, "inbox", "note.txt")); err != nil || string(b) != "from the CLI" {
		t.Fatalf("uploaded %q, %v", b, err)
	}
	out.Reset()
	if err := c.Run([]string{"file", "list", "--folder", "Reports", "inbox"}); err != nil || !strings.Contains(out.String(), "note.txt") {
		t.Fatalf("file list --folder: %v\n%s", err, out.String())
	}
	if trash := run("trash", "list", "Reports"); !strings.Contains(trash, "ID") {
		t.Fatal(trash)
	}
	out.Reset()
	if err := c.Run([]string{"folder", "deletions", "Reports", "--apply"}); err == nil {
		t.Fatal("resolved deletions that nobody held")
	}
	run("update", "Reports", "--name", "Reports 2", "--delete-guard", "strict")
	run("detach", "Reports 2")
	if _, err := os.Stat(filepath.Join(dir, "existing.md")); err != nil {
		t.Fatal("detach removed files")
	}
	if archived := run("archive", id); !strings.Contains(archived, "Archived") {
		t.Fatal(archived)
	}
	if listed := run("list", "--archived"); !strings.Contains(listed, "archived") {
		t.Fatal(listed)
	}
}
