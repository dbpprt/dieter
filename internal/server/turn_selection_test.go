package server

import (
	"context"
	"io"
	"log/slog"
	"net/http/httptest"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/gen/dieter/v1/dieterv1connect"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

func TestQueuedSelectionSurvivesCommandReplayAndRemoval(t *testing.T) {
	data := store.New(t.TempDir())
	t.Cleanup(func() {
		if err := data.Close(); err != nil {
			t.Errorf("close isolated store: %v", err)
		}
	})
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Selections", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Selections", Workflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateCard(store.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Selections", Provider: "codex", Model: "gpt-5.5", Effort: "low"})
	if err != nil {
		t.Fatal(err)
	}
	release := make(chan struct{})
	stopped := make(chan struct{})
	application := NewWithRunner(data, slog.New(slog.NewTextHandler(io.Discard, nil)), gatedRunner{release: release, stopped: stopped})
	httpServer := httptest.NewServer(application.Handler())
	t.Cleanup(httpServer.Close)
	client := dieterv1connect.NewDieterServiceClient(httpServer.Client(), httpServer.URL)
	updates, err := application.app.StartCardWithMessageParts(card.ID, []model.UIMessagePart{{Type: "text", Text: "First"}}, card.Provider, card.Model, card.Effort, card.ProviderOptions, "")
	if err != nil {
		t.Fatal(err)
	}
	turnDone := make(chan struct{})
	go func() {
		for range updates {
		}
		close(turnDone)
	}()
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, err := client.CancelCard(ctx, connect.NewRequest(&dieterv1.GetCardRequest{CardId: card.ID}))
		close(release)
		if err != nil {
			t.Errorf("stop isolated active turn: %v", err)
		}
		select {
		case <-stopped:
		case <-ctx.Done():
			t.Errorf("isolated runner did not stop: %v", ctx.Err())
		}
		// Runner return and lease release precede final service writes and queued
		// admission. Join the owning turn before closing or deleting its store.
		select {
		case <-turnDone:
		case <-ctx.Done():
			t.Errorf("isolated turn did not finish: %v", ctx.Err())
		}
		waitForCanceledCard(t, data, card.ID)
	}()
	request := &dieterv1.SendMessageRequest{CardId: card.ID, ClientId: "selection-test", CommandId: "one-queued-intent", Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Next"}}, Model: "gpt-5.6-sol", Effort: "high", ProviderOptions: map[string]string{"fast_mode": "true"}}
	first, err := client.SendMessage(t.Context(), connect.NewRequest(request))
	if err != nil || !first.Msg.GetQueued() {
		t.Fatalf("queue=%v err=%v", first, err)
	}
	// A command ID identifies the first admitted intent. A replay cannot
	// overwrite its settings or append another queued message.
	request.Model, request.Effort, request.ProviderOptions = "gpt-5.5", "low", map[string]string{"fast_mode": "false"}
	again, err := client.SendMessage(t.Context(), connect.NewRequest(request))
	if err != nil || again.Msg.GetMessageId() != first.Msg.GetMessageId() {
		t.Fatalf("replay=%v err=%v", again, err)
	}
	conversation, err := data.Conversation(card.ID)
	if err != nil || len(conversation.Queue) != 1 {
		t.Fatalf("queue=%#v err=%v", conversation.Queue, err)
	}
	removed, err := client.RemoveQueuedMessage(t.Context(), connect.NewRequest(&dieterv1.RemoveQueuedMessageRequest{CardId: card.ID, MessageId: first.Msg.GetMessageId()}))
	if err != nil {
		t.Fatal(err)
	}
	selection := removed.Msg.GetSelection()
	if selection.GetProvider() != "codex" || selection.GetModel() != "gpt-5.6-sol" || selection.GetEffort() != "high" || selection.GetProviderOptions()["fast_mode"] != "true" {
		t.Fatalf("removed selection=%v", selection)
	}
}
