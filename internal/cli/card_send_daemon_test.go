package cli

import (
	"bytes"
	"context"
	"encoding/json"
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
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

type daemonOwnedRunner struct {
	started  chan struct{}
	release  chan struct{}
	finished chan struct{}
	requests chan harness.Request
}

func TestOperationalCLIWithoutDaemonDoesNotInitializeStore(t *testing.T) {
	t.Parallel()
	root := filepath.Join(t.TempDir(), "missing")
	client := New(root)
	client.Out, client.Err = io.Discard, io.Discard
	defer client.Close()
	if err := client.Run([]string{"storage"}); err == nil {
		t.Fatal("expected unavailable local daemon")
	}
	if _, err := os.Stat(root); !os.IsNotExist(err) {
		t.Fatalf("operational command initialized storage: %v", err)
	}
}

func (runner *daemonOwnedRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	runner.requests <- request
	close(runner.started)
	select {
	case <-ctx.Done():
		close(runner.finished)
		return ctx.Err()
	case <-runner.release:
	}
	for _, chunk := range []string{
		`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`,
		`{"type":"text-start","id":"text"}`,
		`{"type":"text-delta","id":"text","delta":"daemon owned"}`,
		`{"type":"text-end","id":"text"}`,
		`{"type":"finish","finishReason":"stop"}`,
	} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			close(runner.finished)
			return err
		}
	}
	close(runner.finished)
	return emit(harness.Output{Type: "session", State: json.RawMessage(`{"type":"resume-session","data":{"threadId":"daemon"}}`)})
}

func TestCardSendUsesRunningDaemonAndOutlivesClient(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	data := store.New(root)
	repository := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(repository, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Daemon ownership", Path: repository})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.Kanban.CreateCard(kanban.CreateCardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneTodo,
		Title: "Survive client exit", Prompt: "Start", Provider: "mock", Model: "mock",
	})
	if err != nil {
		t.Fatal(err)
	}
	runner := &daemonOwnedRunner{
		started: make(chan struct{}), release: make(chan struct{}), finished: make(chan struct{}),
		requests: make(chan harness.Request, 1),
	}
	application := api.NewWithOptions(data, slog.New(slog.NewTextHandler(io.Discard, nil)), api.Options{Runner: runner, Catalog: testkit.MockCatalog()})
	host := testkit.HTTPServer(application.Handler())
	t.Cleanup(host.Close)
	address := strings.TrimPrefix(host.URL, "http://")
	if _, err := link.NewStatusWriter(root, link.RuntimeStatus{
		PID: os.Getpid(), State: "running", ListenAddress: address,
		GatewayState: link.GatewayNotEnrolled,
	}); err != nil {
		t.Fatal(err)
	}

	directRunner := newFakeRunner()
	var output bytes.Buffer
	client := New(data.Root)
	t.Cleanup(client.Close)
	client.Out, client.Err = &output, &output
	attachment := filepath.Join(t.TempDir(), "resume.txt")
	if err := os.WriteFile(attachment, []byte("daemon attachment"), 0o600); err != nil {
		t.Fatal(err)
	}
	clientDone := make(chan error, 1)
	go func() {
		clientDone <- client.Run([]string{"card", "send", card.ID, "--message", "Continue", "--attach", attachment})
	}()
	select {
	case err := <-clientDone:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(testkit.Budget(30 * time.Second)):
		t.Fatal("daemon admission waited for the agent turn instead of returning to the client")
	}
	if strings.TrimSpace(output.String()) != "sent" || directRunner.Count() != 0 {
		t.Fatalf("output=%q direct requests=%d", output.String(), directRunner.Count())
	}
	select {
	case <-runner.started:
	case <-time.After(testkit.Budget(30 * time.Second)):
		t.Fatal("daemon-owned runner did not start")
	}
	request := <-runner.requests
	if len(request.Attachments) != 1 || request.Attachments[0].Filename != "resume.txt" {
		t.Fatalf("daemon-owned request attachments=%#v", request.Attachments)
	}
	// cardSend has returned and canceled its request context. The admitted turn
	// must remain active until the daemon-owned runner itself completes.
	select {
	case <-runner.finished:
		t.Fatal("client completion canceled the daemon-owned turn")
	case <-time.After(50 * time.Millisecond):
	}
	close(runner.release)
	select {
	case <-runner.finished:
	case <-time.After(testkit.Budget(30 * time.Second)):
		t.Fatal("daemon-owned runner did not finish")
	}
	deadline := time.Now().Add(testkit.Budget(30 * time.Second))
	for time.Now().Before(deadline) {
		stored, resolveErr := data.Kanban.ResolveCard(card.ID)
		leased, leaseErr := data.Leases.CardActive(card.ID)
		if resolveErr == nil && leaseErr == nil && !leased && stored.Runtime == "idle" {
			// The cache file precedes the final sync-journal commit. Wait for
			// that writer to finish before TempDir cleanup removes its root.
			if _, err := data.Kanban.GlobalStateContext(context.Background()); err != nil {
				t.Fatal(err)
			}
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	stored, _ := data.Kanban.ResolveCard(card.ID)
	t.Fatalf("card runtime=%q after daemon-owned turn", stored.Runtime)
}

func TestCardSendDoesNotFallbackAfterCurrentDaemonFailure(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	data := store.New(root)
	if _, err := link.NewStatusWriter(root, link.RuntimeStatus{
		PID: os.Getpid(), State: "running", ListenAddress: "127.0.0.1:1",
		GatewayState: link.GatewayNotEnrolled,
	}); err != nil {
		t.Fatal(err)
	}
	directRunner := newFakeRunner()
	client := New(data.Root)
	t.Cleanup(client.Close)
	err := client.Run([]string{"card", "send", "c_missing", "--message", "Do not duplicate"})
	if err == nil || !strings.Contains(err.Error(), "connect to local Dieter daemon") {
		t.Fatalf("error=%v", err)
	}
	if directRunner.Count() != 0 {
		t.Fatalf("direct fallback started %d turns", directRunner.Count())
	}
}
