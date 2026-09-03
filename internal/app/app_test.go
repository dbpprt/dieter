package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

type fakeRunner struct {
	mu       sync.Mutex
	requests []harness.Request
	err      error
}

type streamErrorRunner struct{}

type diagnosticErrorRunner struct{}

type capabilityStormRunner struct{}

type stalledHeartbeatRunner struct {
	started chan string
}

type failOnceRunner struct {
	mu       sync.Mutex
	requests []harness.Request
}

func (runner *stalledHeartbeatRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	if err := os.WriteFile(filepath.Join(request.ProjectPath, "stalled-worker-sentinel"), []byte("preserved\n"), 0o600); err != nil {
		return err
	}
	if err := emit(harness.Output{Type: "heartbeat"}); err != nil {
		return err
	}
	runner.started <- request.ProjectPath
	<-ctx.Done()
	return ctx.Err()
}

func (streamErrorRunner) Run(_ context.Context, _ harness.Request, emit func(harness.Output) error) error {
	for _, chunk := range []string{
		`{"type":"start","messageId":"assistant"}`,
		`{"type":"error","errorText":"ACP session initialization failed: bun was not found"}`,
	} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return emit(harness.Output{Type: "session", State: json.RawMessage(`{"type":"resume-session","data":{}}`)})
}

func (diagnosticErrorRunner) Run(_ context.Context, _ harness.Request, emit func(harness.Output) error) error {
	if err := emit(harness.Output{Type: "error", Message: "codex exited 1"}); err != nil {
		return err
	}
	return errors.New("codex exited 1: provider stderr\ncontext window exceeded at 120000 tokens")
}

func (capabilityStormRunner) Run(_ context.Context, request harness.Request, emit func(harness.Output) error) error {
	for index := 1; index <= 12_000; index++ {
		capability := fmt.Sprintf(`{"id":"subagents","operation":"upsert","subagent":{"id":"worker","provider":"omp","messageId":%q,"status":"running","toolCount":1,"tokens":500,"contextTokens":400,"contextWindow":1000,"durationMs":%d,"updatedAt":%q,"recentOutput":[%q]}}`, request.ResponseMessageID, index*150, fmt.Sprintf("tick-%d", index), fmt.Sprintf("output-%d", index))
		if err := emit(harness.Output{Type: "capability", Capability: json.RawMessage(capability)}); err != nil {
			return err
		}
	}
	terminal := fmt.Sprintf(`{"id":"subagents","operation":"upsert","subagent":{"id":"worker","provider":"omp","messageId":%q,"status":"completed","toolCount":1,"tokens":500,"contextTokens":400,"contextWindow":1000,"durationMs":1800000}}`, request.ResponseMessageID)
	if err := emit(harness.Output{Type: "capability", Capability: json.RawMessage(terminal)}); err != nil {
		return err
	}
	for _, chunk := range []string{
		`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`,
		`{"type":"message-metadata","messageMetadata":{"usage":{"totalTokens":400},"contextWindowTokens":1000}}`,
		`{"type":"text-start","id":"text"}`,
		`{"type":"text-delta","id":"text","delta":"done"}`,
		`{"type":"text-end","id":"text"}`,
		`{"type":"finish","finishReason":"stop","messageMetadata":{"usage":{"totalTokens":450},"totalUsage":{"totalTokens":5000},"contextWindowTokens":1000}}`,
	} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return nil
}

func (runner *failOnceRunner) Run(_ context.Context, request harness.Request, emit func(harness.Output) error) error {
	runner.mu.Lock()
	runner.requests = append(runner.requests, request)
	attempt := len(runner.requests)
	runner.mu.Unlock()
	if attempt == 1 {
		if err := emit(harness.Output{Type: "error", Message: "provider failed"}); err != nil {
			return err
		}
		return errors.New("provider failed: complete diagnostic")
	}
	for _, chunk := range []string{
		`{"type":"start","messageId":"assistant-retry"}`,
		`{"type":"text-start","id":"text"}`,
		`{"type":"text-delta","id":"text","delta":"retry completed"}`,
		`{"type":"text-end","id":"text"}`,
		`{"type":"finish","finishReason":"stop"}`,
	} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return nil
}

func (runner *failOnceRunner) count() int {
	runner.mu.Lock()
	defer runner.mu.Unlock()
	return len(runner.requests)
}

type emptyResponseRunner struct{}

type parallelRunner struct {
	started chan string
	release chan struct{}
}

type interruptQueueRunner struct {
	mu       sync.Mutex
	requests []harness.Request
	started  chan int
}

type restartRunner struct {
	mu          sync.Mutex
	requests    []harness.Request
	started     chan struct{}
	resumed     chan struct{}
	suspend     chan struct{}
	suspendOnce sync.Once
}

func (runner *restartRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	runner.mu.Lock()
	runner.requests = append(runner.requests, request)
	runner.mu.Unlock()
	if request.Continue {
		for _, chunk := range []string{
			`{"type":"text-delta","id":"text","delta":" after restart"}`,
			`{"type":"text-end","id":"text"}`,
			`{"type":"finish","finishReason":"stop"}`,
		} {
			if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
				return err
			}
		}
		if err := emit(harness.Output{Type: "session", State: json.RawMessage(`{"type":"resume-session","data":{"session":"resumed"}}`)}); err != nil {
			return err
		}
		close(runner.resumed)
		return nil
	}
	for _, chunk := range []string{
		`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`,
		`{"type":"text-start","id":"text"}`,
		`{"type":"text-delta","id":"text","delta":"before restart"}`,
	} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	close(runner.started)
	select {
	case <-ctx.Done():
	case <-runner.suspend:
	}
	if err := emit(harness.Output{Type: "session", State: json.RawMessage(`{"type":"resume-session","data":{"session":"parked"},"continueFrom":{"type":"continue-turn","data":{"cursor":7}}}`)}); err != nil {
		return err
	}
	return ctx.Err()
}

func (runner *restartRunner) Suspend(_, _ string) error {
	runner.suspendOnce.Do(func() { close(runner.suspend) })
	return nil
}

func (runner *restartRunner) snapshotRequests() []harness.Request {
	runner.mu.Lock()
	defer runner.mu.Unlock()
	return append([]harness.Request(nil), runner.requests...)
}

func (runner *interruptQueueRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	runner.mu.Lock()
	runner.requests = append(runner.requests, request)
	turn := len(runner.requests)
	runner.mu.Unlock()
	runner.started <- turn
	if turn == 1 {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(`{"type":"start","messageId":"first-assistant"}`)}); err != nil {
			return err
		}
		if err := emit(harness.Output{Type: "session", State: json.RawMessage(`{"type":"resume-session","data":{"acpSessionId":"interrupted"},"continueFrom":{"type":"continue-turn"}}`)}); err != nil {
			return err
		}
		<-ctx.Done()
		return ctx.Err()
	}
	for _, chunk := range []string{
		`{"type":"start","messageId":"second-assistant"}`,
		`{"type":"text-start","id":"text"}`,
		`{"type":"text-delta","id":"text","delta":"follow-up complete"}`,
		`{"type":"text-end","id":"text"}`,
		`{"type":"finish","finishReason":"stop"}`,
	} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return nil
}

func (runner *interruptQueueRunner) prompts() []string {
	runner.mu.Lock()
	defer runner.mu.Unlock()
	prompts := make([]string, len(runner.requests))
	for index, request := range runner.requests {
		prompts[index] = request.Prompt
	}
	return prompts
}

func TestForkedConversationPromptContainsOnlyVisibleConversationText(t *testing.T) {
	prompt := forkedConversationPrompt([]model.UIMessage{
		{Role: "user", Parts: []model.UIMessagePart{{Type: "text", Text: "Original question"}, {Type: "file", Filename: "secret.txt"}}},
		{Role: "assistant", Parts: []model.UIMessagePart{{Type: "reasoning", Text: "private reasoning"}, {Type: "text", Text: "Original answer"}}},
	}, "Try another direction")
	for _, expected := range []string{"<forked_transcript>", "Original question", "Original answer", "Try another direction"} {
		if !strings.Contains(prompt, expected) {
			t.Fatalf("prompt missing %q: %s", expected, prompt)
		}
	}
	for _, excluded := range []string{"private reasoning", "secret.txt"} {
		if strings.Contains(prompt, excluded) {
			t.Fatalf("prompt leaked %q: %s", excluded, prompt)
		}
	}
}

func (emptyResponseRunner) Run(_ context.Context, _ harness.Request, emit func(harness.Output) error) error {
	for _, chunk := range []string{
		`{"type":"start","messageId":"assistant"}`,
		`{"type":"finish","finishReason":"stop","messageMetadata":{"usage":{"totalTokens":0}}}`,
	} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return nil
}

func (runner *parallelRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	runner.started <- request.SessionID
	select {
	case <-runner.release:
	case <-ctx.Done():
		return ctx.Err()
	}
	for _, chunk := range []string{
		`{"type":"start","messageId":"assistant"}`,
		`{"type":"text-start","id":"text"}`,
		`{"type":"text-delta","id":"text","delta":"done"}`,
		`{"type":"text-end","id":"text"}`,
		`{"type":"finish","finishReason":"stop"}`,
	} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return nil
}

func (f *fakeRunner) Run(_ context.Context, request harness.Request, emit func(harness.Output) error) error {
	f.mu.Lock()
	f.requests = append(f.requests, request)
	f.mu.Unlock()
	if f.err != nil {
		return f.err
	}
	chunks := []string{
		`{"type":"start","messageId":"assistant"}`,
		`{"type":"text-start","id":"text"}`,
		`{"type":"text-delta","id":"text","delta":"done"}`,
		`{"type":"text-end","id":"text"}`,
		`{"type":"finish","finishReason":"stop","messageMetadata":{"createdAt":"2026-08-12T12:00:00Z","usage":{"inputTokens":120,"outputTokens":30,"totalTokens":150},"contextWindowTokens":1000}}`,
	}
	for _, chunk := range chunks {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return emit(harness.Output{Type: "session", State: json.RawMessage(`{"type":"resume-session","data":{"threadId":"thread_1"}}`)})
}

func (f *fakeRunner) count() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.requests)
}

func (f *fakeRunner) request(index int) harness.Request {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.requests[index]
}

func appSetup(t *testing.T) (*Service, *fakeRunner, model.Project, model.Board) {
	t.Helper()
	repo := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(repo, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Atlas", Path: repo, Prompt: "Run tests."})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Delivery", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	fake := &fakeRunner{}
	return New(data, fake), fake, project, board
}

func TestHarnessTurnRunsInsideConversationWorktree(t *testing.T) {
	repository := filepath.Join(t.TempDir(), "repository")
	command := exec.Command("git", "init", "-b", "main", repository)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("git init: %s: %v", output, err)
	}
	for _, args := range [][]string{{"config", "user.name", "Dieter Test"}, {"config", "user.email", "dieter@example.test"}} {
		command = exec.Command("git", args...)
		command.Dir = repository
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s: %v", args, output, err)
		}
	}
	if err := os.WriteFile(filepath.Join(repository, "README.md"), []byte("base\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"add", "README.md"}, {"commit", "-m", "base"}} {
		command = exec.Command("git", args...)
		command.Dir = repository
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s: %v", args, output, err)
		}
	}
	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Workspace", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	runner := &fakeRunner{}
	service := New(data, runner)
	card, err := service.CreateChat(context.Background(), CardInput{
		Project: project.ID, Title: "Worktree turn", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree,
	})
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool {
		stored, resolveErr := data.ResolveCard(card.ID)
		return resolveErr == nil && runner.count() == 1 && stored.Runtime == "idle" && !hasActiveTurn(service, project.ID)
	})
	request := runner.request(0)
	value, err := data.Workspace(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if request.ProjectPath != value.Path || request.ProjectPath == repository {
		t.Fatalf("turn path=%q workspace=%q repository=%q", request.ProjectPath, value.Path, repository)
	}
	if !strings.Contains(request.Instructions, "Working tree: "+value.Path) ||
		!strings.Contains(request.Instructions, "Authoritative working tree: "+value.Path) ||
		strings.Contains(request.Instructions, "Working tree: "+repository+"\n") {
		t.Fatalf("worktree instructions=%q", request.Instructions)
	}
}

func TestConcurrentProjectDirectoryAndWorktreeHarnessTurnsStayIsolatedEndToEnd(t *testing.T) {
	cwd, _ := os.Getwd()
	runtimeDir := filepath.Join(filepath.Dir(cwd), "harness", "runtime")
	if _, err := os.Stat(filepath.Join(runtimeDir, "node_modules")); err != nil {
		t.Skip("local harness dependencies are not installed")
	}
	t.Setenv("DIETER_HARNESS_RUNTIME_DIR", runtimeDir)
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")

	repository := filepath.Join(t.TempDir(), "repository")
	command := exec.Command("git", "init", "-b", "main", repository)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("git init: %s: %v", output, err)
	}
	for _, args := range [][]string{{"config", "user.name", "Dieter Test"}, {"config", "user.email", "dieter@example.test"}} {
		command = exec.Command("git", args...)
		command.Dir = repository
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s: %v", args, output, err)
		}
	}
	if err := os.WriteFile(filepath.Join(repository, "README.md"), []byte("base\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"add", "README.md"}, {"commit", "-m", "base"}} {
		command = exec.Command("git", args...)
		command.Dir = repository
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s: %v", args, output, err)
		}
	}

	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Concurrent", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	service := New(data, nil)
	worktreeCard, err := service.CreateChat(context.Background(), CardInput{
		Project: project.ID, Title: "Worktree", Prompt: "mock-concurrent-workspace-write",
		Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeWorktree, DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	projectCard, err := service.CreateChat(context.Background(), CardInput{
		Project: project.ID, Title: "Project directory", Prompt: "mock-concurrent-workspace-write",
		Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject, DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}

	worktreeUpdates, err := service.StartCard(worktreeCard.ID, "", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	projectUpdates, err := service.StartCard(projectCard.ID, "", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	for _, updates := range []<-chan TurnUpdate{worktreeUpdates, projectUpdates} {
		for update := range updates {
			if update.Err != nil {
				t.Fatal(update.Err)
			}
		}
	}

	worktree, err := data.Workspace(worktreeCard.ID)
	if err != nil {
		t.Fatal(err)
	}
	projectMarker := filepath.Join(repository, ".dieter-mock-"+projectCard.ID)
	worktreeMarker := filepath.Join(worktree.Path, ".dieter-mock-"+worktreeCard.ID)
	for _, marker := range []string{projectMarker, worktreeMarker} {
		if _, err := os.Stat(marker); err != nil {
			t.Fatalf("expected isolated marker %s: %v", marker, err)
		}
	}
	for _, marker := range []string{
		filepath.Join(repository, ".dieter-mock-"+worktreeCard.ID),
		filepath.Join(worktree.Path, ".dieter-mock-"+projectCard.ID),
	} {
		if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("marker leaked into another workspace: %s err=%v", marker, err)
		}
	}
}

func TestWorkspaceProvisioningFailureDoesNotConsumeInitialTurn(t *testing.T) {
	service, _, project, _ := appSetup(t)
	card, err := service.CreateChat(context.Background(), CardInput{
		Project: project.ID, Title: "Invalid worktree base", Prompt: "work",
		WorkspaceMode: model.WorkspaceModeWorktree, WorkspaceBaseBranch: "missing-base", DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := service.SendCard(context.Background(), card.ID, "", "", "", ""); err == nil {
		t.Fatal("expected workspace provisioning failure")
	}
	stored, err := service.Store.ResolveCard(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	conversation, err := service.Store.Conversation(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.InitialPromptSentAt != "" || conversation.ActiveTurn != nil || len(conversation.Messages) != 0 {
		t.Fatalf("failed provisioning consumed the initial turn: card=%#v conversation=%#v", stored, conversation)
	}
}

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("timed out")
		}
		time.Sleep(time.Millisecond)
	}
}

func hasActiveTurn(service *Service, projectID string) bool {
	service.mu.Lock()
	defer service.mu.Unlock()
	for _, turn := range service.active {
		if turn.lease.ProjectID == projectID {
			return true
		}
	}
	return false
}

func TestRegisterProjectCreatesNewGitWorkingTree(t *testing.T) {
	target := filepath.Join(t.TempDir(), "new-project")
	service := New(store.New(t.TempDir()), &fakeRunner{})
	project, err := service.RegisterProject(context.Background(), ProjectInput{
		Path: target, Name: "New project", Create: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	canonicalTarget, err := filepath.EvalSymlinks(target)
	if err != nil {
		t.Fatal(err)
	}
	if project.Path != canonicalTarget || project.Name != "New project" {
		t.Fatalf("created project=%#v", project)
	}
	info, err := os.Stat(filepath.Join(target, ".git"))
	if err != nil || !info.IsDir() {
		t.Fatalf("git working tree was not initialized: info=%#v err=%v", info, err)
	}
}

func TestCreateRunningCardStartsHarnessWithBoardInstructions(t *testing.T) {
	service, fake, project, board := appSetup(t)
	card, err := service.CreateCard(context.Background(), CardInput{Project: project.ID, Board: board.ID, Lane: model.LaneRunning, Title: "Implement", Prompt: "Ship it", Provider: "codex", Model: "gpt-5.5"})
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool {
		stored, _ := service.Store.ResolveCard(card.ID)
		conversation, _ := service.Store.Conversation(card.ID)
		return fake.count() == 1 && stored.Runtime == "idle" && len(conversation.Session) > 0 && !hasActiveTurn(service, project.ID)
	})
	request := fake.request(0)
	if !strings.HasPrefix(card.ID, "c_") || request.Prompt != "Ship it" || request.ResponseMessageID == "" || !strings.Contains(request.Instructions, "Run tests.") || !strings.Contains(request.Instructions, "dieter card comment "+card.ID) {
		t.Fatalf("card=%#v request=%#v", card, request)
	}
}

func TestCreateRunningCardUsesTitleAsInitialTaskWhenPromptIsEmpty(t *testing.T) {
	service, fake, project, board := appSetup(t)
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
		Title: "  Inspect the sync queue  ", Provider: "codex", Model: "gpt-5.5",
	})
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return fake.count() == 1 && !hasActiveTurn(service, project.ID) })
	if card.Title != "Inspect the sync queue" || card.InitialPrompt != "Inspect the sync queue" {
		t.Fatalf("card=%#v", card)
	}
	if request := fake.request(0); request.Prompt != "Inspect the sync queue" {
		t.Fatalf("request=%#v", request)
	}
}

func TestCreateRunningCardCanDeferStartToStreamingClient(t *testing.T) {
	service, fake, project, board := appSetup(t)
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
		Title: "Implement", Prompt: "Ship it", Provider: "codex", Model: "gpt-5.6-sol",
		DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if fake.count() != 0 || card.InitialPromptSentAt != "" {
		t.Fatalf("deferred card started early: card=%#v requests=%d", card, fake.count())
	}
	conversation, err := service.Store.Conversation(card.ID)
	if err != nil || len(conversation.Messages) != 0 {
		t.Fatalf("deferred conversation=%#v err=%v", conversation, err)
	}

	updates, err := service.StartCard(card.ID, "", card.Provider, card.Model, "")
	if err != nil {
		t.Fatal(err)
	}
	for range updates {
	}
	if fake.count() != 1 {
		t.Fatalf("requests=%d", fake.count())
	}
	if request := fake.request(0); request.Prompt != "Ship it" {
		t.Fatalf("request=%#v", request)
	}
	stored, _ := service.Store.ResolveCard(card.ID)
	if stored.InitialPromptSentAt == "" || stored.Runtime != "idle" {
		t.Fatalf("started card=%#v", stored)
	}
	conversation, err = service.Store.Conversation(card.ID)
	if err != nil || len(conversation.Messages) != 2 || !strings.Contains(string(conversation.Messages[1].Metadata), `"totalTokens"`) || !strings.Contains(string(conversation.Messages[1].Metadata), `"contextWindowTokens"`) {
		t.Fatalf("conversation metadata=%#v err=%v", conversation.Messages, err)
	}
}

func TestStalledWorkerHeartbeatFailsDurablyAndCanResume(t *testing.T) {
	service, _, project, board := appSetup(t)
	stalled := &stalledHeartbeatRunner{started: make(chan string, 1)}
	service.Runner = stalled
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
		Title: "Stall", Prompt: "write then stall", Provider: "codex", Model: "gpt-5.5", DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	updates, err := service.StartCard(card.ID, "", card.Provider, card.Model, card.Effort)
	if err != nil {
		t.Fatal(err)
	}
	workspacePath := <-stalled.started
	service.mu.Lock()
	active := service.active[card.ID]
	if active == nil || !active.workerObserved {
		service.mu.Unlock()
		t.Fatalf("worker heartbeat was not observed: %#v", active)
	}
	active.lastProgress = time.Now().Add(-workerHeartbeatTimeout - time.Second)
	service.mu.Unlock()
	if reconciled := service.ReconcileStalledTurns(time.Now()); len(reconciled) != 1 || reconciled[0] != card.ID {
		t.Fatalf("reconciled=%v", reconciled)
	}
	var terminal TurnUpdate
	for update := range updates {
		if update.Done {
			terminal = update
		}
	}
	if terminal.Err == nil || !strings.Contains(terminal.Err.Error(), "stopped reporting progress") {
		t.Fatalf("terminal update=%#v", terminal)
	}
	conversation, err := service.Store.Conversation(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	stored, err := service.Store.ResolveCard(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	leased, err := service.Store.CardHasRuntimeLease(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if conversation.Status != "failed" || conversation.ActiveTurn != nil || stored.Runtime != "failed" || leased {
		t.Fatalf("conversation=%#v card=%#v leased=%v", conversation, stored, leased)
	}
	if contents, err := os.ReadFile(filepath.Join(workspacePath, "stalled-worker-sentinel")); err != nil || string(contents) != "preserved\n" {
		t.Fatalf("workspace changes were not preserved: contents=%q err=%v", contents, err)
	}

	resumed := &fakeRunner{}
	service.Runner = resumed
	updates, err = service.StartCard(card.ID, "continue safely", card.Provider, card.Model, card.Effort)
	if err != nil {
		t.Fatal(err)
	}
	for range updates {
	}
	conversation, err = service.Store.Conversation(card.ID)
	if err != nil || conversation.Status != "idle" || resumed.count() != 1 {
		t.Fatalf("resumed conversation=%#v requests=%d err=%v", conversation, resumed.count(), err)
	}
}

func TestStartCardRejectsLowDiskBeforeMutatingConversation(t *testing.T) {
	service, _, project, board := appSetup(t)
	service.minimumFreeBytes = 1024
	service.diskAvailable = func(string) (uint64, error) { return 1023, nil }
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
		Title: "Low disk", Prompt: "do work", Provider: "codex", Model: "gpt-5.5", DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = service.StartCard(card.ID, "", card.Provider, card.Model, card.Effort); !errors.Is(err, ErrInsufficientStorage) {
		t.Fatalf("StartCard error=%v", err)
	}
	conversation, err := service.Store.Conversation(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	stored, err := service.Store.ResolveCard(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	leased, err := service.Store.CardHasRuntimeLease(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(conversation.Messages) != 0 || stored.InitialPromptSentAt != "" || leased {
		t.Fatalf("conversation=%#v card=%#v leased=%v", conversation, stored, leased)
	}
}

func TestSeparateChatsRunConcurrentlyInSameProjectFolder(t *testing.T) {
	service, _, project, board := appSetup(t)
	runner := &parallelRunner{started: make(chan string, 2), release: make(chan struct{})}
	service.Runner = runner
	defer func() {
		select {
		case <-runner.release:
		default:
			close(runner.release)
		}
	}()

	cards := make([]model.Card, 0, 2)
	for _, title := range []string{"First", "Second"} {
		card, err := service.CreateCard(context.Background(), CardInput{
			Project: project.ID, Board: board.ID, Lane: model.LaneTodo,
			Title: title, Prompt: "Wait until released", Provider: "codex", Model: "gpt-5.6-sol",
		})
		if err != nil {
			t.Fatal(err)
		}
		cards = append(cards, card)
	}

	streams := make([]<-chan TurnUpdate, 0, 2)
	for _, card := range cards {
		updates, err := service.StartCard(card.ID, "", card.Provider, card.Model, "")
		if err != nil {
			t.Fatalf("start %s: %v", card.ID, err)
		}
		streams = append(streams, updates)
	}
	started := map[string]bool{}
	for range cards {
		select {
		case cardID := <-runner.started:
			started[cardID] = true
		case <-time.After(2 * time.Second):
			t.Fatal("timed out waiting for concurrent turns")
		}
	}
	if !started[cards[0].ID] || !started[cards[1].ID] {
		t.Fatalf("started=%v, want both cards", started)
	}
	close(runner.release)
	for _, stream := range streams {
		for range stream {
		}
	}
}

func TestOMPSelectionUsesConfiguredACPAdapterAndContextWindow(t *testing.T) {
	service, fake, project, board := appSetup(t)
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
		Title: "OMP", Prompt: "Run it", Provider: "omp", Model: "box/qwen3_6_27b",
	})
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool {
		stored, _ := service.Store.ResolveCard(card.ID)
		conversation, _ := service.Store.Conversation(card.ID)
		return fake.count() == 1 && stored.Runtime == "idle" && len(conversation.Session) > 0 && !hasActiveTurn(service, project.ID)
	})
	request := fake.request(0)
	if card.Provider != "omp" || card.Model != "box/qwen3_6_27b" || request.Adapter != "omp-acp" || request.ContextWindow != 262144 {
		t.Fatalf("card=%#v request=%#v", card, request)
	}
}

func TestClaudeThinkingEffortReachesHarness(t *testing.T) {
	service, fake, project, board := appSetup(t)
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
		Title: "Think", Prompt: "Work carefully", Provider: "claude-code", Model: "claude-sonnet-4-5", Effort: "max",
	})
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return fake.count() == 1 && !hasActiveTurn(service, project.ID) })
	stored, _ := service.Store.ResolveCard(card.ID)
	if stored.Effort != "max" || fake.request(0).Effort != "max" || fake.request(0).Adapter != "claude-code" {
		t.Fatalf("card=%#v request=%#v", stored, fake.request(0))
	}
}

func TestPiDefaultModelAndThinkingEffortReachHarness(t *testing.T) {
	service, fake, project, board := appSetup(t)
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
		Title: "Think", Prompt: "Use Pi", Provider: "pi", Effort: "minimal",
	})
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return fake.count() == 1 && !hasActiveTurn(service, project.ID) })
	request := fake.request(0)
	stored, _ := service.Store.ResolveCard(card.ID)
	if stored.Model != "default" || request.ConfiguredModel != "default" || request.Model != "" || request.Effort != "minimal" || request.Adapter != "pi" {
		t.Fatalf("card=%#v request=%#v", stored, request)
	}
}

func TestStreamProtocolErrorRemainsFailed(t *testing.T) {
	service, _, project, board := appSetup(t)
	service.Runner = streamErrorRunner{}
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
		Title: "Failure", Prompt: "Run it", Provider: "omp", Model: "box/qwen3_6_27b",
		DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	updates, err := service.StartCard(card.ID, "", card.Provider, card.Model, "")
	if err != nil {
		t.Fatal(err)
	}
	for range updates {
	}
	stored, _ := service.Store.ResolveCard(card.ID)
	conversation, _ := service.Store.Conversation(card.ID)
	if stored.Runtime != "failed" || conversation.Status != "failed" || conversation.Messages[1].Parts[0].Text != "ACP session initialization failed: bun was not found" {
		t.Fatalf("card=%#v conversation=%#v", stored, conversation)
	}
}

func TestEmptyClaudeCompletionPreservesSessionInFailureMessage(t *testing.T) {
	service, _, project, board := appSetup(t)
	service.Runner = emptyResponseRunner{}
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
		Title: "Empty", Prompt: "Run it", Provider: "claude-code", Model: "claude-sonnet-4-5",
		DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	updates, err := service.StartCard(card.ID, "", card.Provider, card.Model, "")
	if err != nil {
		t.Fatal(err)
	}
	for range updates {
	}
	stored, _ := service.Store.ResolveCard(card.ID)
	conversation, _ := service.Store.Conversation(card.ID)
	last := conversation.Messages[len(conversation.Messages)-1]
	if stored.Runtime != "failed" || conversation.Status != "failed" || len(last.Parts) != 1 || !strings.Contains(last.Parts[0].Text, "without producing output") || !strings.Contains(last.Parts[0].Text, "durable session is preserved") || strings.Contains(last.Parts[0].Text, "authenticated") {
		t.Fatalf("card=%#v conversation=%#v", stored, conversation)
	}
}

func TestRunnerFailureIsPersisted(t *testing.T) {
	service, fake, project, board := appSetup(t)
	fake.err = errors.New("offline")
	card, err := service.CreateCard(context.Background(), CardInput{Project: project.ID, Board: board.ID, Lane: model.LaneRunning, Title: "Implement", Prompt: "Ship it", Provider: "codex"})
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool {
		stored, _ := service.Store.ResolveCard(card.ID)
		return stored.Runtime == "failed"
	})
	conversation, _ := service.Store.Conversation(card.ID)
	if conversation.Status != "failed" {
		t.Fatalf("conversation=%#v", conversation)
	}
}

func TestRunnerFailurePersistsCompleteDiagnostics(t *testing.T) {
	service, _, project, board := appSetup(t)
	service.Runner = diagnosticErrorRunner{}
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
		Title: "Diagnostics", Prompt: "Ship it", Provider: "codex", DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	updates, err := service.StartCard(card.ID, "", card.Provider, card.Model, card.Effort)
	if err != nil {
		t.Fatal(err)
	}
	for range updates {
	}
	conversation, err := service.Store.Conversation(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	last := conversation.Messages[len(conversation.Messages)-1]
	if conversation.Status != "failed" || len(last.Parts) != 1 ||
		!strings.Contains(last.Parts[0].Text, "provider stderr") ||
		!strings.Contains(last.Parts[0].Text, "context window exceeded") {
		t.Fatalf("conversation=%#v", conversation)
	}
}

func TestFailedTurnCanRetryExactUserMessage(t *testing.T) {
	service, _, project, board := appSetup(t)
	runner := &failOnceRunner{}
	service.Runner = runner
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
		Title: "Retry", Prompt: "Run the flaky verification", Provider: "codex", DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	updates, err := service.StartCard(card.ID, "", card.Provider, card.Model, card.Effort)
	if err != nil {
		t.Fatal(err)
	}
	for range updates {
	}
	failed, err := service.Store.Conversation(card.ID)
	if err != nil || failed.Status != "failed" || len(failed.Messages) < 2 {
		t.Fatalf("failed conversation=%#v err=%v", failed, err)
	}
	retryParts := append([]model.UIMessagePart(nil), failed.Messages[0].Parts...)
	queued, err := service.SubmitCardParts(card.ID, retryParts, card.Provider, card.Model, card.Effort, nil)
	if err != nil || queued {
		t.Fatalf("queued=%v err=%v", queued, err)
	}
	waitFor(t, func() bool {
		conversation, _ := service.Store.Conversation(card.ID)
		return runner.count() == 2 && conversation.Status == "idle" && !hasActiveTurn(service, project.ID)
	})
	retried, err := service.Store.Conversation(card.ID)
	if err != nil || len(retried.Messages) != 4 || retried.Messages[2].Role != "user" ||
		retried.Messages[2].Parts[0].Text != "Run the flaky verification" ||
		!strings.Contains(retried.Messages[3].Parts[0].Text, "retry completed") {
		t.Fatalf("retried conversation=%#v err=%v", retried, err)
	}
}

func TestMessageReopensDoneCardAndResumesSession(t *testing.T) {
	service, fake, project, board := appSetup(t)
	card, err := service.CreateCard(context.Background(), CardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Implement", Prompt: "Ship it", Provider: "codex"})
	if err != nil {
		t.Fatal(err)
	}
	if err = service.SendCard(context.Background(), card.ID, "", "", "", ""); err != nil {
		t.Fatal(err)
	}
	if _, err = service.Store.MoveCard(card.ID, model.LaneDone, nil); err != nil {
		t.Fatal(err)
	}
	if err = service.SendCard(context.Background(), card.ID, "Change it", "", "", ""); err != nil {
		t.Fatal(err)
	}
	stored, _ := service.Store.ResolveCard(card.ID)
	request := fake.request(1)
	if stored.Lane != model.LaneRunning || request.Prompt != "Change it" || len(request.Session) == 0 {
		t.Fatalf("stored=%#v request=%#v", stored, request)
	}
}

func TestConversationHarnessAndModelAreLockedAfterFirstTurn(t *testing.T) {
	service, fake, project, board := appSetup(t)
	card, err := service.CreateCard(context.Background(), CardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Implement", Prompt: "Ship it", Provider: "codex", Model: "gpt-5.5", Effort: "high"})
	if err != nil {
		t.Fatal(err)
	}
	if card.Effort != "high" {
		t.Fatalf("created card effort=%q", card.Effort)
	}
	if err = service.SendCard(context.Background(), card.ID, "", "codex", "gpt-5.5", "high"); err != nil {
		t.Fatal(err)
	}
	if request := fake.request(0); request.Effort != "high" {
		t.Fatalf("request effort=%q", request.Effort)
	}
	if err = service.SendCard(context.Background(), card.ID, "switch", "claude-code", "claude-sonnet-4-5", ""); err == nil || !strings.Contains(err.Error(), "locked") {
		t.Fatalf("harness switch err=%v", err)
	}
	if err = service.SendCard(context.Background(), card.ID, "switch", "codex", "gpt-5.6-sol", ""); err == nil || !strings.Contains(err.Error(), "locked") {
		t.Fatalf("model switch err=%v", err)
	}
	if err = service.SendCard(context.Background(), card.ID, "switch", "codex", "gpt-5.5", "medium"); err == nil || !strings.Contains(err.Error(), "effort is locked") {
		t.Fatalf("effort switch err=%v", err)
	}
}

func TestProviderOptionsPersistReachRuntimeAndLockAfterFirstTurn(t *testing.T) {
	service, fake, project, board := appSetup(t)
	options := map[string]string{"advisor": "true"}
	card, err := service.CreateCard(context.Background(), CardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Review", Prompt: "Review it", Provider: "omp", ProviderOptions: options})
	if err != nil {
		t.Fatal(err)
	}
	if card.ProviderOptions["advisor"] != "true" {
		t.Fatalf("stored options=%#v", card.ProviderOptions)
	}
	if _, err = service.SubmitCardParts(card.ID, []model.UIMessagePart{{Type: "text", Text: "Review it"}}, "omp", card.Model, "", options); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return fake.count() == 1 })
	if request := fake.request(0); request.Options["advisor"] != "true" {
		t.Fatalf("runtime options=%#v", request.Options)
	}
	waitFor(t, func() bool {
		stored, resolveErr := service.Store.ResolveCard(card.ID)
		return resolveErr == nil && stored.Runtime == "idle"
	})
	waitFor(t, func() bool {
		service.mu.Lock()
		defer service.mu.Unlock()
		return len(service.active) == 0
	})
	if _, err = service.SubmitCardParts(card.ID, []model.UIMessagePart{{Type: "text", Text: "Change"}}, "omp", card.Model, "", map[string]string{"advisor": "false"}); err == nil || !strings.Contains(err.Error(), "options are locked") {
		t.Fatalf("provider option switch err=%v", err)
	}
}

func TestProviderOptionDefaultsDoNotLockLegacyConversation(t *testing.T) {
	service, fake, project, board := appSetup(t)
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneTodo,
		Title: "Legacy review", Prompt: "Review it", Provider: "omp",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = service.SubmitCardParts(card.ID, []model.UIMessagePart{{Type: "text", Text: "Review it"}}, "omp", card.Model, "", map[string]string{"advisor": "false"}); err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool {
		stored, resolveErr := service.Store.ResolveCard(card.ID)
		return resolveErr == nil && stored.Runtime == "idle"
	})
	waitFor(t, func() bool {
		service.mu.Lock()
		defer service.mu.Unlock()
		return len(service.active) == 0
	})

	// Simulate a conversation created before the adapter advertised its first
	// provider option. An omitted value and the advertised default are the same
	// locked configuration.
	if _, err = service.Store.UpdateCardCache(card.ID, store.CardCacheInput{ProviderOptions: map[string]string{}}); err != nil {
		t.Fatal(err)
	}
	if _, err = service.SubmitCardParts(card.ID, []model.UIMessagePart{{Type: "text", Text: "Continue"}}, "omp", card.Model, "", map[string]string{"advisor": "false"}); err != nil {
		t.Fatalf("default option rejected for legacy conversation: %v", err)
	}
	waitFor(t, func() bool { return fake.count() == 2 })
	waitFor(t, func() bool {
		stored, resolveErr := service.Store.ResolveCard(card.ID)
		return resolveErr == nil && stored.Runtime == "idle"
	})
	waitFor(t, func() bool {
		service.mu.Lock()
		defer service.mu.Unlock()
		return len(service.active) == 0
	})
}

func TestFirstTurnCanExplicitlyRestoreAdapterDefaultEffort(t *testing.T) {
	service, fake, project, board := appSetup(t)
	card, err := service.CreateCard(context.Background(), CardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Implement", Prompt: "Ship it", Provider: "codex", Model: "gpt-5.6-sol", Effort: "high"})
	if err != nil {
		t.Fatal(err)
	}
	if err = service.SendCard(context.Background(), card.ID, "", "codex", "gpt-5.6-sol", "default"); err != nil {
		t.Fatal(err)
	}
	stored, _ := service.Store.ResolveCard(card.ID)
	if stored.Effort != "" || fake.request(0).Effort != "" {
		t.Fatalf("stored effort=%q request effort=%q", stored.Effort, fake.request(0).Effort)
	}
}

func TestQueuedMessageStartsAfterInterruptWithoutRecordingFailure(t *testing.T) {
	service, _, project, board := appSetup(t)
	runner := &interruptQueueRunner{started: make(chan int, 2)}
	service.Runner = runner
	card, err := service.CreateCard(context.Background(), CardInput{Project: project.ID, Board: board.ID, Lane: model.LaneRunning, Title: "Queue", Prompt: "Keep working", Provider: "omp", Model: "box/qwen3_6_27b", DeferStart: true})
	if err != nil {
		t.Fatal(err)
	}
	updates, err := service.StartCard(card.ID, "", card.Provider, card.Model, "")
	if err != nil {
		t.Fatal(err)
	}
	go drainTurnUpdates(updates)
	if turn := <-runner.started; turn != 1 {
		t.Fatalf("first turn=%d", turn)
	}
	queuedParts := []model.UIMessagePart{
		{Type: "text", Text: "Use this instead"},
		{Type: "file", MediaType: "image/png", Filename: "queued.png", URL: "data:image/png;base64,iVBORw0KGgo="},
	}
	queued, err := service.SubmitCardParts(card.ID, queuedParts, card.Provider, card.Model, "", nil)
	if err != nil || !queued {
		t.Fatalf("queued=%v err=%v", queued, err)
	}
	conversation, _ := service.Store.Conversation(card.ID)
	if len(conversation.Queue) != 1 || conversation.Queue[0].Text != "Use this instead" || len(conversation.Queue[0].Parts) != 2 {
		t.Fatalf("queue=%#v", conversation.Queue)
	}
	if err := service.CancelCard(card.ID); err != nil {
		t.Fatal(err)
	}
	select {
	case turn := <-runner.started:
		if turn != 2 {
			t.Fatalf("second turn=%d", turn)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("queued turn did not start after interrupt")
	}
	service.mu.Lock()
	secondTurn := service.active[card.ID]
	service.mu.Unlock()
	if secondTurn == nil {
		t.Fatal("queued turn was not registered as active")
	}
	select {
	case <-secondTurn.done:
	case <-time.After(10 * time.Second):
		t.Fatal("queued turn did not finish")
	}
	conversation, _ = service.Store.Conversation(card.ID)
	stored, _ := service.Store.ResolveCard(card.ID)
	service.mu.Lock()
	active := service.active[card.ID]
	service.mu.Unlock()
	if conversation.Status != "idle" || len(conversation.Queue) != 0 || stored.Runtime != "idle" || active != nil {
		t.Fatalf("queued turn did not settle: status=%q queue=%d runtime=%q active=%v", conversation.Status, len(conversation.Queue), stored.Runtime, active != nil)
	}
	prompts := runner.prompts()
	if len(prompts) != 2 || prompts[0] != "Keep working" || prompts[1] != "Use this instead" {
		t.Fatalf("prompts=%#v", prompts)
	}
	runner.mu.Lock()
	secondSession := append(json.RawMessage(nil), runner.requests[1].Session...)
	secondAttachments := append([]harness.Attachment(nil), runner.requests[1].Attachments...)
	runner.mu.Unlock()
	if len(secondAttachments) != 1 || secondAttachments[0].Filename != "queued.png" {
		t.Fatalf("queued attachment was not delivered: %#v", secondAttachments)
	}
	if len(secondSession) != 0 && string(secondSession) != "null" {
		t.Fatalf("OMP queued turn retained interrupted session: %s", secondSession)
	}
	for _, message := range conversation.Messages {
		for _, part := range message.Parts {
			if strings.Contains(part.Text, "harness worker") || part.State == "error" {
				t.Fatalf("interrupt was recorded as failure: %#v", conversation.Messages)
			}
		}
	}
}

func TestReconcileOrphanedTurnAndRepeatedCancelAreIdempotent(t *testing.T) {
	service, _, project, _ := appSetup(t)
	chat, err := service.Store.CreateChat(store.CreateCardInput{Project: project.ID, ID: "chat_orphan", Title: "Orphaned", Prompt: "Work"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.Store.StartConversationTurn(chat.ID, "turn_orphan", "user_orphan", "Continue"); err != nil {
		t.Fatal(err)
	}
	if _, err := service.Store.UpdateCardCache(chat.ID, store.CardCacheInput{Runtime: "running"}); err != nil {
		t.Fatal(err)
	}
	recovered, err := service.ReconcileOrphanedTurns()
	if err != nil || len(recovered) != 1 || recovered[0] != chat.ID {
		t.Fatalf("recovered=%#v err=%v", recovered, err)
	}
	conversation, err := service.Store.Conversation(chat.ID)
	if err != nil || conversation.Status != "interrupted" {
		t.Fatalf("conversation=%#v err=%v", conversation, err)
	}
	if err := service.CancelCard(chat.ID); err != nil {
		t.Fatalf("first repeated cancel: %v", err)
	}
	if err := service.CancelCard(chat.ID); err != nil {
		t.Fatalf("second repeated cancel: %v", err)
	}
}

func TestGracefulRestartContinuesActiveTurnForEveryProvider(t *testing.T) {
	providers := []struct {
		provider string
		model    string
		effort   string
		options  map[string]string
	}{
		{provider: "codex", model: "gpt-5.6-sol", effort: "low"},
		{provider: "claude-code", model: "sonnet", effort: "low"},
		{provider: "pi", model: "default", effort: "minimal"},
		{provider: "omp", model: "default", effort: "low", options: map[string]string{"advisor": "true"}},
	}
	for _, provider := range providers {
		t.Run(provider.provider, func(t *testing.T) {
			service, _, project, board := appSetup(t)
			runner := &restartRunner{started: make(chan struct{}), resumed: make(chan struct{}), suspend: make(chan struct{})}
			service.Runner = runner
			card, err := service.CreateCard(context.Background(), CardInput{
				Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
				Title: "Restart", Prompt: "Continue once", Provider: provider.provider, Model: provider.model, Effort: provider.effort,
				ProviderOptions: provider.options, DeferStart: true,
			})
			if err != nil {
				t.Fatal(err)
			}
			updates, err := service.StartCard(card.ID, "", card.Provider, card.Model, card.Effort)
			if err != nil {
				t.Fatal(err)
			}
			go drainTurnUpdates(updates)
			select {
			case <-runner.started:
			case <-time.After(2 * time.Second):
				t.Fatal("initial turn did not start")
			}
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			if err := service.SuspendActiveTurns(shutdownCtx); err != nil {
				t.Fatal(err)
			}
			parked, err := service.Store.Conversation(card.ID)
			if err != nil || parked.Status != "running" || parked.ActiveTurn == nil || !hasTurnContinuation(parked.Session) {
				t.Fatalf("parked conversation=%#v err=%v", parked, err)
			}
			responseMessageID := parked.ActiveTurn.ResponseMessageID
			settings, settingsErr := service.Store.Settings()
			if settingsErr != nil {
				t.Fatal(settingsErr)
			}
			if _, settingsErr = service.Store.UpdatePromptSettings("Changed after suspension\n{{project.instructions_block}}\n{{labels.instructions_block}}", settings.BoardSkillTemplate, settings.ChatSkillTemplate); settingsErr != nil {
				t.Fatal(settingsErr)
			}
			restarted := New(service.Store, runner)
			recovered, err := restarted.ReconcileOrphanedTurns()
			if err != nil || len(recovered) != 1 || recovered[0] != card.ID {
				t.Fatalf("recovered=%#v err=%v", recovered, err)
			}
			select {
			case <-runner.resumed:
			case <-time.After(2 * time.Second):
				t.Fatal("continued turn did not finish")
			}
			waitFor(t, func() bool { return !hasActiveTurn(restarted, project.ID) })
			conversation, err := service.Store.Conversation(card.ID)
			if err != nil || conversation.Status != "idle" || conversation.ActiveTurn != nil || len(conversation.Messages) != 2 || conversation.Messages[1].ID != responseMessageID || conversation.Messages[1].Parts[0].Text != "before restart after restart" {
				t.Fatalf("continued conversation=%#v err=%v", conversation, err)
			}
			requests := runner.snapshotRequests()
			if len(requests) != 2 || requests[0].Continue || !requests[1].Continue || requests[1].Prompt != "" || requests[1].ResponseMessageID != responseMessageID || !hasTurnContinuation(requests[1].Session) {
				t.Fatalf("requests=%#v", requests)
			}
			if provider.options != nil && (requests[0].Options["advisor"] != "true" || requests[1].Options["advisor"] != "true") {
				t.Fatalf("provider options were not retained across restart: %#v", requests)
			}
			if requests[0].Instructions == "" || requests[1].Instructions != requests[0].Instructions {
				t.Fatalf("instruction snapshot changed across restart: first=%q resumed=%q", requests[0].Instructions, requests[1].Instructions)
			}
		})
	}
}

func TestPersistedSelectionSurvivesBeforeLiveDiscovery(t *testing.T) {
	adapter, configuredModel, err := resolvePersistedSelection("codex", "gpt-future-discovered", false)
	if err != nil {
		t.Fatal(err)
	}
	if adapter.ID != "codex" || configuredModel.ID != "gpt-future-discovered" || configuredModel.RuntimeID() != "gpt-future-discovered" {
		t.Fatalf("adapter=%#v model=%#v", adapter, configuredModel)
	}
}

func TestCapabilityProgressFilterDropsCosmeticHeartbeats(t *testing.T) {
	filter := newCapabilityProgressFilter()
	first := json.RawMessage(`{"id":"subagents","operation":"upsert","subagent":{"id":"worker","provider":"omp","messageId":"assistant","status":"running","toolCount":4,"durationMs":1000,"updatedAt":"one","recentOutput":["one"]}}`)
	heartbeat := json.RawMessage(`{"id":"subagents","operation":"upsert","subagent":{"id":"worker","provider":"omp","messageId":"assistant","status":"running","toolCount":4,"durationMs":59000,"updatedAt":"two","recentOutput":["two"]}}`)
	minute := json.RawMessage(`{"id":"subagents","operation":"upsert","subagent":{"id":"worker","provider":"omp","messageId":"assistant","status":"running","toolCount":4,"durationMs":60000,"updatedAt":"three","recentOutput":["three"]}}`)
	progress := json.RawMessage(`{"id":"subagents","operation":"upsert","subagent":{"id":"worker","provider":"omp","messageId":"assistant","status":"running","toolCount":5,"durationMs":2100,"updatedAt":"three"}}`)
	terminal := json.RawMessage(`{"id":"subagents","operation":"upsert","subagent":{"id":"worker","provider":"omp","messageId":"assistant","status":"completed","toolCount":5,"durationMs":2200,"updatedAt":"four"}}`)

	if !filter.shouldPersist(first) {
		t.Fatal("first progress update was dropped")
	}
	if filter.shouldPersist(heartbeat) {
		t.Fatal("duration/output-only heartbeat was persisted")
	}
	if !filter.shouldPersist(minute) {
		t.Fatal("minute heartbeat was dropped")
	}
	if !filter.shouldPersist(progress) {
		t.Fatal("material tool progress was dropped")
	}
	if !filter.shouldPersist(terminal) {
		t.Fatal("terminal status was dropped")
	}
}

func TestCapabilityStormCompletesWithBoundedDurableEvents(t *testing.T) {
	service, _, project, board := appSetup(t)
	service.Runner = capabilityStormRunner{}
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
		Title: "Telemetry storm", Prompt: "Finish despite noisy progress", Provider: "omp", DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	updates, err := service.StartCard(card.ID, "", card.Provider, card.Model, card.Effort)
	if err != nil {
		t.Fatal(err)
	}
	for range updates {
	}
	conversation, err := service.Store.Conversation(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if conversation.Status != "idle" || len(conversation.Subagents) != 1 || conversation.Subagents[0].Status != "completed" {
		t.Fatalf("conversation did not finish cleanly: %#v", conversation)
	}
	var metadata struct {
		Usage      struct{ TotalTokens int64 } `json:"usage"`
		TotalUsage struct{ TotalTokens int64 } `json:"totalUsage"`
	}
	if len(conversation.Messages) < 2 || json.Unmarshal(conversation.Messages[len(conversation.Messages)-1].Metadata, &metadata) != nil || metadata.Usage.TotalTokens != 450 || metadata.TotalUsage.TotalTokens != 5000 {
		t.Fatalf("current and cumulative usage were not preserved separately: %#v", conversation.Messages)
	}
	if conversation.LastSeq > 50 {
		t.Fatalf("12,000 cosmetic progress records expanded to %d durable events", conversation.LastSeq)
	}
}
