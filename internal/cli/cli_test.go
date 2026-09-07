package cli

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	dieterdaemon "github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/store"
)

type fakeRunner struct{ requests []harness.Request }

func (f *fakeRunner) Run(_ context.Context, request harness.Request, emit func(harness.Output) error) error {
	f.requests = append(f.requests, request)
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
	if len(fake.requests) != 1 || !strings.Contains(fake.requests[0].Instructions, "Stay concise") || len(fake.requests[0].Attachments) != 1 || fake.requests[0].Attachments[0].Filename != "notes.txt" {
		t.Fatalf("requests=%#v", fake.requests)
	}
	out.Reset()
	if err := c.Run([]string{"card", "comment", cardID, "--message", "Progress"}); err != nil {
		t.Fatal(err)
	}
	if len(fake.requests) != 1 {
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
	if !strings.Contains(out.String(), "non-triggering Dieter annotation") {
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

func TestSetupProjectIsIdempotent(t *testing.T) {
	repo := filepath.Join(t.TempDir(), "repo")
	if output, err := exec.Command("git", "init", repo).CombinedOutput(); err != nil {
		t.Fatalf("git init: %s: %v", output, err)
	}
	subdirectory := filepath.Join(repo, "nested")
	if err := os.MkdirAll(subdirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	c := New(store.New(t.TempDir()))
	first, existing, err := c.setupProject(subdirectory)
	if err != nil || existing {
		t.Fatalf("first=%#v existing=%v err=%v", first, existing, err)
	}
	canonicalRepo, err := filepath.EvalSymlinks(repo)
	if err != nil {
		t.Fatal(err)
	}
	if first.Path != canonicalRepo {
		t.Fatalf("registered path=%q want=%q", first.Path, canonicalRepo)
	}
	second, existing, err := c.setupProject(repo)
	if err != nil || !existing || second.ID != first.ID {
		t.Fatalf("second=%#v existing=%v err=%v", second, existing, err)
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
