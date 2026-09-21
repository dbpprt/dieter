package cli

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	dieterdaemon "github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/server"
	"github.com/dbpprt/dieter/internal/store"
)

type fakeRunner struct {
	mu       sync.Mutex
	requests []harness.Request
}

func (f *fakeRunner) snapshot() []harness.Request {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]harness.Request(nil), f.requests...)
}

func (f *fakeRunner) Run(_ context.Context, request harness.Request, emit func(harness.Output) error) error {
	f.mu.Lock()
	f.requests = append(f.requests, request)
	f.mu.Unlock()
	response := "done"
	if request.ConfiguredModel == "gpt-5.3-codex-spark" {
		response = "Add Keyboard Board Navigation"
	}
	for _, chunk := range []string{`{"type":"start","messageId":"assistant"}`, `{"type":"text-start","id":"text"}`, `{"type":"text-delta","id":"text","delta":"` + response + `"}`, `{"type":"text-end","id":"text"}`, `{"type":"finish","finishReason":"stop"}`} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return emit(harness.Output{Type: "session", State: json.RawMessage(`{"type":"resume-session","data":{"threadId":"cli"}}`)})
}

func TestMainDispatchesTheDetachedDaemonUpdateWorkerBeforeNormalCLISetup(t *testing.T) {
	directory := t.TempDir()
	brew := filepath.Join(directory, "brew")
	trace := filepath.Join(directory, "trace")
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >>\"$DIETER_UPDATE_TEST_TRACE\"\n"
	if err := os.WriteFile(brew, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIETER_UPDATE_TEST_TRACE", trace)
	if code := Main([]string{"__daemon-update-worker", "--brew", brew}); code != 0 {
		t.Fatalf("worker exit code=%d", code)
	}
	raw, err := os.ReadFile(trace)
	if err != nil {
		t.Fatal(err)
	}
	want := "update\nupgrade dbpprt/tap/dieter\nservices restart dbpprt/tap/dieter\n"
	if string(raw) != want {
		t.Fatalf("worker commands=%q want=%q", raw, want)
	}
}

func TestCLIConversationWorkflowAndHelp(t *testing.T) {
	repo := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(repo, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	data := store.New(t.TempDir())
	fake := &fakeRunner{}
	var out bytes.Buffer
	c := New(data)
	c.Out, c.Err, c.Runner = &out, &out, fake
	connectTestCLI(t, c)
	if err := c.Run([]string{"project", "open", repo, "--prompt", "Stay concise."}); err != nil {
		t.Fatal(err)
	}
	projects, _ := data.ListProjects()
	projectID := projects[0].ID
	out.Reset()
	if err := c.Run([]string{"board", "create", "--project", projectID, "--name", "Delivery", "--workflow", "review"}); err != nil {
		t.Fatal(err)
	}
	boards, _ := data.ListBoards(projectID)
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
	draft, err := data.Conversation(cardID)
	if err != nil || len(draft.DraftAttachments) != 1 || draft.DraftAttachments[0].Filename != "notes.txt" {
		t.Fatalf("draft attachments=%#v err=%v", draft.DraftAttachments, err)
	}
	out.Reset()
	if err := c.Run([]string{"card", "send", cardID, "--message", "Implement it"}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		current, err := data.ResolveCard(cardID)
		if err == nil && current.InitialPromptSentAt != "" && current.Runtime == "idle" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	requests := fake.snapshot()
	if len(requests) != 1 || !strings.Contains(requests[0].Instructions, "Stay concise") || len(requests[0].Attachments) != 1 || requests[0].Attachments[0].Filename != "notes.txt" {
		t.Fatalf("requests=%#v", requests)
	}
	out.Reset()
	if err := c.Run([]string{"card", "comment", cardID, "--message", "Progress"}); err != nil {
		t.Fatal(err)
	}
	if len(fake.snapshot()) != 1 {
		t.Fatal("comment unexpectedly sent an agent message")
	}
	out.Reset()
	if err := c.Run([]string{"card", "move", cardID, "--lane", "review"}); err != nil {
		t.Fatal(err)
	}
	card, _ := data.ResolveCard(cardID)
	if card.Lane != "review" {
		t.Fatalf("lane=%s", card.Lane)
	}
	out.Reset()
	if err := c.Run([]string{"board", "retention", "--archive-done", "after_30_days", boards[0].ID}); err != nil {
		t.Fatal(err)
	}
	board, _ := data.ResolveBoard("", boards[0].ID)
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
	if !strings.Contains(out.String(), "annotation") {
		t.Fatalf("help=%s", out.String())
	}
}

func TestConfigureHarnessCatalogUsesStoreOverride(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "harnesses.yaml")
	data := []byte("version: 1\nharnesses:\n  - id: local\n    name: Local\n    adapter: pi\n    defaultModel: one\n    models:\n      - id: one\n        name: One\n")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIETER_HARNESS_CONFIG", "")
	if err := configureHarnessCatalog(root, ""); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := harness.ConfigureCatalog(""); err != nil {
			t.Fatal(err)
		}
	})
	if source := harness.CatalogSource(); source != path {
		t.Fatalf("catalog source=%q want %q", source, path)
	}
}

func TestCLIProjectRemoveAndRestore(t *testing.T) {
	repo := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(repo, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	data := store.New(t.TempDir())
	var out bytes.Buffer
	c := New(data)
	c.Out, c.Err = &out, &out
	connectTestCLI(t, c)
	if err := c.Run([]string{"project", "open", repo, "--name", "Temporary"}); err != nil {
		t.Fatal(err)
	}
	projects, _ := data.ListProjects()
	projectID := projects[0].ID
	out.Reset()
	if err := c.Run([]string{"project", "remove", projectID}); err != nil {
		t.Fatal(err)
	}
	if projects, _ := data.ListProjects(); len(projects) != 0 {
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
	if projects, _ := data.ListProjects(); len(projects) != 1 || projects[0].ID != projectID {
		t.Fatalf("restored projects: %#v", projects)
	}
}

func TestNewDaemonDirectRouteAdvertisesEphemeralLoopback(t *testing.T) {
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	identity := &dieterdaemon.Identity{
		ID:             "d_local",
		GatewayURL:     "https://dieter.example.com",
		CertificatePEM: []byte("enrolled"),
		PrivateKey:     private,
	}
	route, err := newDaemonDirectRoute(identity, "127.0.0.1:4242", "loopback", "127.0.0.1:0", "127.0.0.1", "loopback", 1000)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		route.server.Stop()
		_ = route.listener.Close()
	})
	if route.candidate.GetId() != "loopback" || route.candidate.GetHost() != "127.0.0.1" || route.candidate.GetNetwork() != "loopback" {
		t.Fatalf("candidate=%#v", route.candidate)
	}
	if route.candidate.GetPort() == 0 || route.candidate.GetPriority() != 1000 {
		t.Fatalf("candidate=%#v", route.candidate)
	}
	if route.candidate.GetCertificateIdentity() != identity.ID {
		t.Fatalf("certificate identity=%q", route.candidate.GetCertificateIdentity())
	}
}

func TestDaemonStatusAndLogs(t *testing.T) {
	root := t.TempDir()
	data := store.New(root)
	if _, err := dieterdaemon.NewStatusWriter(root, dieterdaemon.RuntimeStatus{
		State: "stopped", ListenAddress: "127.0.0.1:1", GatewayState: dieterdaemon.GatewayNotEnrolled,
	}); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	c := New(data)
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

	logPath := dieterdaemon.LogPath(root)
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
	repo := filepath.Join(t.TempDir(), "repo")
	if output, err := exec.Command("git", "init", repo).CombinedOutput(); err != nil {
		t.Fatalf("git init: %s: %v", output, err)
	}
	data := store.New(t.TempDir())
	c := New(data)
	err := c.Run([]string{"setup", repo})
	if err == nil || !strings.Contains(err.Error(), "register a project explicitly with `dieter project open PATH`") {
		t.Fatalf("setup error=%v", err)
	}
	projects, listErr := data.ListProjects()
	if listErr != nil || len(projects) != 0 {
		t.Fatalf("projects=%#v err=%v", projects, listErr)
	}
	if _, identityErr := dieterdaemon.LoadIdentity(data.Root); !errors.Is(identityErr, os.ErrNotExist) {
		t.Fatalf("setup started onboarding before rejecting the project path: %v", identityErr)
	}
}

func TestSetupDoesNotRegisterCurrentGitProject(t *testing.T) {
	repo := filepath.Join(t.TempDir(), "repo")
	if output, err := exec.Command("git", "init", repo).CombinedOutput(); err != nil {
		t.Fatalf("git init: %s: %v", output, err)
	}
	t.Chdir(repo)

	data := store.New(t.TempDir())
	identity, err := dieterdaemon.LoadOrCreateEnrollmentIdentity(data.Root, "test", "https://gateway.example")
	if err != nil {
		t.Fatal(err)
	}
	if err := identity.SaveCredential("d_test", "test", []byte("certificate"), nil, nil, time.Now().Add(time.Hour).Format(time.RFC3339Nano), 1); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	c := New(data)
	c.Out, c.Err = &out, &out
	remoteDesktop := remotedesktop.New(remotedesktop.Options{
		Source: remotedesktop.SourceOptions{HelperPath: filepath.Join(t.TempDir(), "missing-capture-helper")},
	})
	application := server.NewWithRemoteDesktop(data, slog.New(slog.NewTextHandler(io.Discard, nil)), c.Runner, remoteDesktop)
	host := httptest.NewServer(application.Handler())
	t.Cleanup(host.Close)
	if _, err := dieterdaemon.NewStatusWriter(data.Root, dieterdaemon.RuntimeStatus{
		PID: os.Getpid(), State: "running", ListenAddress: strings.TrimPrefix(host.URL, "http://"),
	}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)

	if err := c.Run([]string{"setup", "--no-open", "--no-start"}); err != nil {
		t.Fatal(err)
	}
	projects, err := data.ListProjects()
	if err != nil || len(projects) != 0 {
		t.Fatalf("projects=%#v err=%v", projects, err)
	}
	if !strings.Contains(out.String(), "Projects are not registered by setup; add one explicitly with `dieter project open PATH`.") {
		t.Fatalf("setup output=%q", out.String())
	}
}

func TestServiceLoggerWritesCentralBoundedLog(t *testing.T) {
	root := t.TempDir()
	logger, path, closeLog, err := daemonLogger(root, true, false, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	logger.Info("service ready", "store", root)
	closeLog()
	if path != dieterdaemon.LogPath(root) {
		t.Fatalf("path=%q", path)
	}
	raw, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(raw), "service ready") {
		t.Fatalf("log=%q err=%v", raw, err)
	}
}

// All workflow tests use the same API path as the installed CLI.
func connectTestCLI(t *testing.T, c *CLI) {
	t.Helper()
	if err := c.Store.Ensure(); err != nil {
		t.Fatal(err)
	}
	application := server.NewWithRunner(c.Store, slog.New(slog.NewTextHandler(io.Discard, nil)), c.Runner)
	host := httptest.NewServer(application.Handler())
	t.Cleanup(host.Close)
	if _, err := dieterdaemon.NewStatusWriter(c.Store.Root, dieterdaemon.RuntimeStatus{PID: os.Getpid(), State: "running", ListenAddress: strings.TrimPrefix(host.URL, "http://")}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.Close)
}
