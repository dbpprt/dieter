package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

type activationRecoveryRunner struct {
	heartbeat chan struct{}
	park      chan struct{}
	request   chan harness.Request
	parkOnce  sync.Once
}

func (runner *activationRecoveryRunner) PrepareRuntime(_ context.Context, digest string) (harness.RuntimeReference, error) {
	if digest != "runtime-a" {
		return harness.RuntimeReference{}, errors.New("unexpected runtime digest " + digest)
	}
	return harness.RuntimeReference{Digest: digest, ProtocolVersion: harness.RuntimeProtocolVersion, Directory: "/runtime/" + digest}, nil
}

func (runner *activationRecoveryRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	runner.request <- request
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-runner.heartbeat:
	}
	if err := emit(harness.Output{Type: "heartbeat"}); err != nil {
		return err
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-runner.park:
	}
	return emit(harness.Output{Type: "session", State: json.RawMessage(`{"type":"resume-session","data":{"thread":"fixture"},"continueFrom":{"type":"continue-turn","data":{"cursor":2}}}`)})
}

func (runner *activationRecoveryRunner) Suspend(_, _ string) error {
	runner.parkOnce.Do(func() { close(runner.park) })
	return nil
}

func TestCandidateActivationWaitsForRecoveredWorkerHeartbeat(t *testing.T) {
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Activation", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.CreateChat(store.CreateCardInput{
		Project: project.ID, ID: "chat_activation", Title: "Activation recovery", Prompt: "Keep working",
		Provider: "codex", Model: "gpt-5.6-sol", Effort: "low", WorkspaceMode: model.WorkspaceModeProject,
	})
	if err != nil {
		t.Fatal(err)
	}
	const turnID = "turn_activation"
	if _, err := data.StartConversationTurn(chat.ID, turnID, "user_activation", chat.InitialPrompt); err != nil {
		t.Fatal(err)
	}
	if _, err := data.SetConversationActiveTurn(chat.ID, model.ConversationTurn{
		ID: turnID, UserMessageID: "user_activation", ResponseMessageID: "assistant_activation",
		HarnessRuntimeDigest: "runtime-a", HarnessRuntimeProtocol: harness.RuntimeProtocolVersion,
		Selection: &model.HarnessSelection{Provider: "codex", Model: "gpt-5.6-sol", Effort: "low"},
	}); err != nil {
		t.Fatal(err)
	}
	continuation := json.RawMessage(`{"type":"resume-session","data":{"thread":"fixture"},"continueFrom":{"type":"continue-turn","data":{"cursor":1}}}`)
	if _, err := data.SetConversationSession(chat.ID, turnID, continuation); err != nil {
		t.Fatal(err)
	}
	if _, err := data.UpdateCardCache(chat.ID, store.CardCacheInput{Provider: "codex", Model: "gpt-5.6-sol", Runtime: "running"}); err != nil {
		t.Fatal(err)
	}

	runner := &activationRecoveryRunner{
		heartbeat: make(chan struct{}), park: make(chan struct{}), request: make(chan harness.Request, 1),
	}
	ready := make(chan struct{})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- ListenDaemonReady(ctx, "127.0.0.1:0", data, runner, slog.New(slog.NewTextHandler(io.Discard, nil)), nil, true, func() error {
			close(ready)
			return nil
		}, nil, nil)
	}()
	select {
	case request := <-runner.request:
		if !request.Continue || request.RuntimeDigest != "runtime-a" {
			t.Fatalf("recovery request=%#v", request)
		}
	case <-time.After(5 * time.Second):
		cancel()
		t.Fatal("candidate did not start the recovered turn")
	}
	select {
	case <-ready:
		cancel()
		t.Fatal("candidate committed before the recovered worker heartbeat")
	case <-time.After(100 * time.Millisecond):
	}
	close(runner.heartbeat)
	select {
	case <-ready:
	case <-time.After(5 * time.Second):
		cancel()
		t.Fatal("candidate did not commit after the recovered worker heartbeat")
	}
	cancel()
	select {
	case err := <-done:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("candidate daemon did not shut down cleanly")
	}
	conversation, err := data.Conversation(chat.ID)
	if err != nil || conversation.Status != "running" || conversation.ActiveTurn == nil || conversation.ActiveTurn.HarnessRuntimeDigest != "runtime-a" {
		t.Fatalf("parked conversation=%#v err=%v", conversation, err)
	}
}
