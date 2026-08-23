package app

import (
	"context"
	"encoding/json"
	"errors"
	"os"
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

func TestEmptyHarnessCompletionBecomesDescriptiveFailure(t *testing.T) {
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
	if stored.Runtime != "failed" || conversation.Status != "failed" || len(last.Parts) != 1 || !strings.Contains(last.Parts[0].Text, "completed without a response") || !strings.Contains(last.Parts[0].Text, "authenticated") {
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
	waitFor(t, func() bool {
		conversation, _ = service.Store.Conversation(card.ID)
		service.mu.Lock()
		active := service.active[project.ID]
		service.mu.Unlock()
		return conversation.Status == "idle" && len(conversation.Queue) == 0 && active == nil
	})
	// Let the background update-channel drainer observe the close before the
	// temporary store is removed by testing.T cleanup.
	time.Sleep(100 * time.Millisecond)
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
