package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/testkit"
)

// fakeRunner replies like a provider, titles quick tasks like the spark
// model would, and streams the batching regression fixture on request.
type fakeRunner = testkit.FakeRunner

func newFakeRunner() *fakeRunner { return &fakeRunner{Script: cliTurn} }

func cliTurn(_ context.Context, request harness.Request, emit func(harness.Output) error) error {
	if strings.Contains(request.Prompt, cliBatchPrompt) {
		return emitCLIBatch(request, emit)
	}
	response := "done"
	if request.ConfiguredModel == "gpt-5.3-codex-spark" {
		response = "Add Keyboard Board Navigation"
	}
	return testkit.EmitText(emit, response, "cli")
}

func TestCLIConversationWorkflowAndHelp(t *testing.T) {
	t.Parallel()
	repo := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(repo, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	data := testkit.Store(t)
	fake := newFakeRunner()
	var out bytes.Buffer
	c := New(data.Root)
	c.Out, c.Err = &out, &out
	connectTestCLI(t, c, data, fake)
	if err := c.Run([]string{"project", "open", repo, "--prompt", "Stay concise."}); err != nil {
		t.Fatal(err)
	}
	projects, _ := data.Kanban.ListProjects()
	projectID := projects[0].ID
	out.Reset()
	if err := c.Run([]string{"board", "create", "--project", projectID, "--name", "Delivery", "--workflow", "review"}); err != nil {
		t.Fatal(err)
	}
	boards, _ := data.Kanban.ListBoards(projectID)
	attachmentPath := filepath.Join(t.TempDir(), "notes.txt")
	if err := os.WriteFile(attachmentPath, []byte("CLI attachment"), 0o600); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := c.Run([]string{"card", "create", "--project", projectID, "--board", boards[0].ID, "--lane", "todo", "--title", "Ship", "--prompt", "Implement it", "--attach", attachmentPath, "--provider", "codex", "--workspace", "project", "--format", "id"}); err != nil {
		t.Fatal(err)
	}
	cardID := strings.TrimSpace(out.String())
	if !strings.HasPrefix(cardID, "c_") {
		t.Fatalf("card id=%q", cardID)
	}
	draft, err := data.Conversations.Get(cardID)
	if err != nil || len(draft.DraftAttachments) != 1 || draft.DraftAttachments[0].Filename != "notes.txt" {
		t.Fatalf("draft attachments=%#v err=%v", draft.DraftAttachments, err)
	}
	out.Reset()
	if err := c.Run([]string{"card", "send", cardID, "--message", "Implement it"}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(testkit.Budget(30 * time.Second))
	for time.Now().Before(deadline) {
		current, err := data.Kanban.ResolveCard(cardID)
		if err == nil && current.InitialPromptSentAt != "" && current.Runtime == "idle" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	requests := fake.Requests()
	if len(requests) != 1 || !strings.Contains(requests[0].Instructions, "Stay concise") || len(requests[0].Attachments) != 1 || requests[0].Attachments[0].Filename != "notes.txt" {
		t.Fatalf("requests=%#v", requests)
	}
	out.Reset()
	if err := c.Run([]string{"card", "move", cardID, "--lane", "review"}); err != nil {
		t.Fatal(err)
	}
	card, _ := data.Kanban.ResolveCard(cardID)
	if card.Lane != "review" {
		t.Fatalf("lane=%s", card.Lane)
	}
	out.Reset()
	if err := c.Run([]string{"board", "retention", "--archive-done", "after_30_days", boards[0].ID}); err != nil {
		t.Fatal(err)
	}
	board, _ := data.Kanban.ResolveBoard("", boards[0].ID)
	if board.DoneArchivePolicy != "after_30_days" {
		t.Fatalf("Done archive policy=%q", board.DoneArchivePolicy)
	}
	if err := c.Run([]string{"card", "archive", cardID}); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := c.Run([]string{"card", "list", "--board", boards[0].ID, "--archived", "--format", "ids"}); err != nil || strings.TrimSpace(out.String()) != cardID {
		t.Fatalf("archived cards=%q err=%v", out.String(), err)
	}
	if err := c.Run([]string{"card", "unarchive", cardID}); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := c.Run([]string{"card", "--help"}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "Mark a displayed model response as seen") {
		t.Fatalf("help=%s", out.String())
	}
}

func TestCLIProjectRemoveAndRestore(t *testing.T) {
	t.Parallel()
	repo := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(repo, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	data := testkit.Store(t)
	var out bytes.Buffer
	c := New(data.Root)
	c.Out, c.Err = &out, &out
	connectTestCLI(t, c, data, newFakeRunner())
	if err := c.Run([]string{"project", "open", repo, "--name", "Temporary"}); err != nil {
		t.Fatal(err)
	}
	projects, _ := data.Kanban.ListProjects()
	projectID := projects[0].ID
	out.Reset()
	if err := c.Run([]string{"project", "remove", projectID}); err != nil {
		t.Fatal(err)
	}
	if projects, _ := data.Kanban.ListProjects(); len(projects) != 0 {
		t.Fatalf("project still active: %#v", projects)
	}
	out.Reset()
	if err := c.Run([]string{"project", "list", "--removed"}); err != nil || !strings.Contains(out.String(), "Temporary") {
		t.Fatalf("removed list: %q %v", out.String(), err)
	}
	out.Reset()
	if err := c.Run([]string{"project", "restore", projectID}); err != nil {
		t.Fatal(err)
	}
	if projects, _ := data.Kanban.ListProjects(); len(projects) != 1 || projects[0].ID != projectID {
		t.Fatalf("restored projects: %#v", projects)
	}
}

func TestDaemonStatusAndLogs(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	data := store.New(root)
	if _, err := link.NewStatusWriter(root, link.RuntimeStatus{
		State: "stopped", ListenAddress: "127.0.0.1:1", GatewayState: link.GatewayNotEnrolled,
	}); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	c := New(data.Root)
	c.Out, c.Err = &out, &out
	if err := c.Run([]string{"daemon", "status", "--format", "json"}); err != nil {
		t.Fatal(err)
	}
	var status map[string]any
	if err := json.Unmarshal(out.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if status["status"] != "stopped" || status["running"] != false || status["store"] != root {
		t.Fatalf("status=%#v", status)
	}

	logPath := link.LogPath(root)
	if err := os.MkdirAll(filepath.Dir(logPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(logPath, []byte("one\ntwo\nthree\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err := c.Run([]string{"daemon", "logs", "--lines", "2"}); err != nil {
		t.Fatal(err)
	}
	if out.String() != "two\nthree\n" {
		t.Fatalf("logs=%q", out.String())
	}

	out.Reset()
	if err := c.Run([]string{"daemon", "--help"}); err != nil || !strings.Contains(out.String(), "unenroll") {
		t.Fatalf("daemon help=%q err=%v", out.String(), err)
	}
	if err := c.Run([]string{"daemon", "unenroll"}); err == nil || !strings.Contains(err.Error(), "not enrolled") {
		t.Fatalf("unenroll without identity err=%v", err)
	}
}

func TestDaemonStatusRecognizesHealthyCurrentAPI(t *testing.T) {
	t.Parallel()
	client, output, _ := daemonCLIForTest(t)
	if err := client.Run([]string{"daemon", "status", "--format", "json"}); err != nil {
		t.Fatal(err)
	}
	var status daemonStatusView
	if err := json.Unmarshal(output.Bytes(), &status); err != nil {
		t.Fatal(err)
	}
	if !status.APIHealthy || !status.Running || status.Status != "local-only" {
		t.Fatalf("status=%#v", status)
	}
}

func TestSetupRejectsProjectPathsBeforeOnboarding(t *testing.T) {
	t.Parallel()
	repo := filepath.Join(t.TempDir(), "repo")
	testkit.InitGitRepo(t, repo)
	data := testkit.Store(t)
	c := New(data.Root)
	err := c.Run([]string{"setup", repo})
	if err == nil || !strings.Contains(err.Error(), "register a project explicitly with `dieter project open PATH`") {
		t.Fatalf("setup error=%v", err)
	}
	projects, listErr := data.Kanban.ListProjects()
	if listErr != nil || len(projects) != 0 {
		t.Fatalf("projects=%#v err=%v", projects, listErr)
	}
	if _, identityErr := link.LoadIdentity(data.Root); !errors.Is(identityErr, os.ErrNotExist) {
		t.Fatalf("setup started onboarding before rejecting the project path: %v", identityErr)
	}
}

func TestSetupDoesNotRegisterCurrentGitProject(t *testing.T) {
	repo := filepath.Join(t.TempDir(), "repo")
	testkit.InitGitRepo(t, repo)
	t.Chdir(repo)

	data := testkit.Store(t)
	identity, err := link.LoadOrCreateEnrollmentIdentity(data.Root, "test", "https://gateway.example")
	if err != nil {
		t.Fatal(err)
	}
	if err := identity.SaveCredential("d_test", "test", []byte("certificate"), nil, nil, time.Now().Add(time.Hour).Format(time.RFC3339Nano), 1); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	c := New(data.Root)
	c.Out, c.Err = &out, &out
	remoteDesktop := remotedesktop.New(remotedesktop.Options{
		Source: remotedesktop.SourceOptions{HelperPath: filepath.Join(t.TempDir(), "missing-capture-helper")},
	})
	application := api.NewWithRemoteDesktop(data, slog.New(slog.NewTextHandler(io.Discard, nil)), newFakeRunner(), remoteDesktop)
	host := testkit.HTTPServer(application.Handler())
	t.Cleanup(host.Close)
	if _, err := link.NewStatusWriter(data.Root, link.RuntimeStatus{
		PID: os.Getpid(), State: "running", ListenAddress: strings.TrimPrefix(host.URL, "http://"),
	}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)

	if err := c.Run([]string{"setup", "--no-open", "--no-start"}); err != nil {
		t.Fatal(err)
	}
	projects, err := data.Kanban.ListProjects()
	if err != nil || len(projects) != 0 {
		t.Fatalf("projects=%#v err=%v", projects, err)
	}
	if !strings.Contains(out.String(), "Projects are not registered by setup; add one explicitly with `dieter project open PATH`.") {
		t.Fatalf("setup output=%q", out.String())
	}
}

// All workflow tests use the same API path as the installed CLI.
func connectTestCLI(t *testing.T, c *CLI, data *store.Store, runner harness.Runner) {
	t.Helper()
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	application := api.NewWithRunner(data, slog.New(slog.NewTextHandler(io.Discard, nil)), runner)
	host := testkit.HTTPServer(application.Handler())
	t.Cleanup(host.Close)
	if _, err := link.NewStatusWriter(c.Root, link.RuntimeStatus{PID: os.Getpid(), State: "running", ListenAddress: strings.TrimPrefix(host.URL, "http://")}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
}
