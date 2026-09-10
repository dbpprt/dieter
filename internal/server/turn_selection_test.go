package server

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
)

func TestQueuedSelectionSurvivesCommandReplayAndRemoval(t *testing.T) {
	data := store.New(t.TempDir())
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
	client, _ := newConnectTestClient(t, data, gatedRunner{release: release})
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, err := client.CancelCard(ctx, connect.NewRequest(&dieterv1.GetCardRequest{CardId: card.ID}))
		close(release)
		if err != nil {
			t.Errorf("stop isolated active turn: %v", err)
		}
	}()
	if _, err := client.SendMessage(t.Context(), connect.NewRequest(&dieterv1.SendMessageRequest{CardId: card.ID, Parts: []*dieterv1.MessagePart{{Type: "text", Text: "First"}}})); err != nil {
		t.Fatal(err)
	}
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
