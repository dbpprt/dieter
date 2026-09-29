package app

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
)

// These run the daemon's real turn pipeline: SubprocessRunner, runner.mjs, the
// patched Codex bridge, the bundled Codex CLI, capability persistence, and the
// conversation projection. Only the model provider is a loopback fixture whose
// Responses stream drops mid-flight, like a transient network failure.

type flakyResponsesFixture struct {
	requests atomic.Int32
	// Holds the recovery request until the test has observed the reconnect.
	release chan struct{}
	dropAll bool
}

func (fixture *flakyResponsesFixture) ServeHTTP(response http.ResponseWriter, request *http.Request) {
	_, _ = io.Copy(io.Discard, request.Body)
	if request.URL.Path != "/v1/responses" {
		http.NotFound(response, request)
		return
	}
	index := fixture.requests.Add(1)
	response.Header().Set("Content-Type", "text/event-stream")
	flusher := response.(http.Flusher)
	writeEvent := func(event map[string]any) {
		raw, _ := json.Marshal(event)
		fmt.Fprintf(response, "event: %s\ndata: %s\n\n", event["type"], raw)
		flusher.Flush()
	}
	responseID := fmt.Sprintf("response_%d", index)
	writeEvent(map[string]any{"type": "response.created", "response": map[string]any{"id": responseID, "status": "in_progress", "output": []any{}}})
	if index == 1 || fixture.dropAll {
		// Drop the connection after the stream started.
		time.Sleep(20 * time.Millisecond)
		connection, _, err := response.(http.Hijacker).Hijack()
		if err == nil {
			_ = connection.Close()
		}
		return
	}
	select {
	case <-fixture.release:
	case <-request.Context().Done():
		return
	}
	item := map[string]any{
		"id": "message_1", "type": "message", "role": "assistant", "phase": "final_answer", "status": "completed",
		"content": []any{map[string]any{"type": "output_text", "text": "Recovered answer.", "annotations": []any{}}},
	}
	writeEvent(map[string]any{"type": "response.output_item.added", "output_index": 0, "item": map[string]any{
		"id": "message_1", "type": "message", "role": "assistant", "phase": "final_answer", "status": "in_progress", "content": []any{},
	}})
	writeEvent(map[string]any{"type": "response.output_text.delta", "item_id": "message_1", "output_index": 0, "content_index": 0, "delta": "Recovered answer."})
	writeEvent(map[string]any{"type": "response.output_item.done", "output_index": 0, "item": item})
	writeEvent(map[string]any{"type": "response.completed", "response": map[string]any{
		"id": responseID, "status": "completed", "output": []any{item},
		"usage": map[string]any{"input_tokens": 10, "output_tokens": 5, "total_tokens": 15,
			"input_tokens_details": map[string]any{"cached_tokens": 0}, "output_tokens_details": map[string]any{"reasoning_tokens": 0}},
	}})
}

func startCodexReconnectTurn(t *testing.T, fixture *flakyResponsesFixture) (*Service, model.Card, <-chan TurnUpdate) {
	t.Helper()
	if testing.Short() {
		t.Skip("runs the bundled Codex CLI")
	}
	runtimeDir, err := filepath.Abs(filepath.Join("..", "harness", "runtime"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(runtimeDir, "node_modules", "@openai", "codex")); err != nil {
		t.Skip("local harness dependencies are not installed")
	}
	if _, err := exec.LookPath("node"); err != nil {
		t.Skip("node is not installed")
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: fixture, ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Close() })
	// Only disposable credentials and provider state reach the worker.
	home := t.TempDir()
	t.Setenv("DIETER_HARNESS_RUNTIME_DIR", runtimeDir)
	t.Setenv("HOME", home)
	t.Setenv("CODEX_HOME", filepath.Join(home, "codex"))
	t.Setenv("OPENAI_BASE_URL", "http://"+listener.Addr().String()+"/v1")
	t.Setenv("CODEX_API_KEY", "dieter-loopback-fixture")
	t.Setenv("OPENAI_API_KEY", "")
	if err := os.MkdirAll(filepath.Join(home, "codex"), 0o700); err != nil {
		t.Fatal(err)
	}
	service, _, project, board := appSetup(t)
	service.Runner = harness.NewSubprocessRunner(service.Store.Root)
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
		Title: "Flaky provider", Prompt: "Answer once the provider is reachable.", Provider: "codex", Model: "gpt-6-astra", DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	updates, err := service.StartCard(card.ID, "", card.Provider, card.Model, card.Effort)
	if err != nil {
		t.Fatal(err)
	}
	return service, card, updates
}

func awaitTurn(t *testing.T, updates <-chan TurnUpdate) TurnUpdate {
	t.Helper()
	timeout := time.After(2 * time.Minute)
	for {
		select {
		case update, ok := <-updates:
			if !ok {
				t.Fatal("turn ended without a terminal update")
			}
			if update.Done {
				for range updates {
				}
				return update
			}
		case <-timeout:
			t.Fatal("turn did not finish")
		}
	}
}

func TestCodexTurnSurvivesTransientProviderDropEndToEnd(t *testing.T) {
	fixture := &flakyResponsesFixture{release: make(chan struct{})}
	service, card, updates := startCodexReconnectTurn(t, fixture)

	// The reconnect is visible in the durable projection while Codex retries.
	var reconnecting *model.ProviderStatus
	deadline := time.Now().Add(90 * time.Second)
	for reconnecting == nil && time.Now().Before(deadline) {
		conversation, err := service.Store.Conversation(card.ID)
		if err != nil {
			t.Fatal(err)
		}
		if conversation.Status == "failed" {
			t.Fatalf("retry notice failed the turn: %+v", conversation.Messages)
		}
		reconnecting = conversation.ProviderStatus
		time.Sleep(50 * time.Millisecond)
	}
	if reconnecting == nil || reconnecting.State != "reconnecting" || reconnecting.Attempt != 1 || reconnecting.MaxAttempts != 5 ||
		reconnecting.Provider != "codex" || !strings.HasPrefix(reconnecting.Message, "Reconnecting... 1/5") {
		t.Fatalf("provider status while retrying=%+v", reconnecting)
	}
	close(fixture.release)

	if terminal := awaitTurn(t, updates); terminal.Err != nil {
		t.Fatalf("turn failed after the provider recovered: %v", terminal.Err)
	}
	conversation, err := service.Store.Conversation(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if conversation.Status != "idle" || conversation.ProviderStatus != nil {
		t.Fatalf("status=%q provider=%+v", conversation.Status, conversation.ProviderStatus)
	}
	transcript, _ := json.Marshal(conversation.Messages)
	if !strings.Contains(string(transcript), "Recovered answer.") || strings.Contains(string(transcript), `"state":"error"`) {
		t.Fatalf("transcript=%s", transcript)
	}
	if requests := fixture.requests.Load(); requests != 2 {
		t.Fatalf("provider requests=%d, want the drop and one retry", requests)
	}
}

func TestCodexTurnFailsWithFinalProviderErrorEndToEnd(t *testing.T) {
	fixture := &flakyResponsesFixture{dropAll: true}
	service, card, updates := startCodexReconnectTurn(t, fixture)
	terminal := awaitTurn(t, updates)
	if terminal.Err == nil {
		t.Fatal("turn succeeded without a provider response")
	}
	conversation, err := service.Store.Conversation(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if conversation.Status != "failed" || conversation.ProviderStatus != nil {
		t.Fatalf("status=%q provider=%+v", conversation.Status, conversation.ProviderStatus)
	}
	var failure string
	for _, part := range conversation.Messages[len(conversation.Messages)-1].Parts {
		if part.State == "error" {
			failure = part.Text
		}
	}
	summary, _, _ := strings.Cut(failure, "\n")
	// Clients summarize by the first line: the provider's final error, never a
	// retry notice or an unrelated bootstrap warning.
	if !strings.Contains(summary, "stream disconnected before completion") || strings.HasPrefix(summary, "Reconnecting") ||
		strings.Contains(failure, "request transformations") {
		t.Fatalf("failure text=%q", failure)
	}
	if requests := fixture.requests.Load(); requests != 6 {
		t.Fatalf("provider requests=%d, want the drop and five retries", requests)
	}
}
