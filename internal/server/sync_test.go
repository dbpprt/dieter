package server

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"
	naucliov1 "github.com/dbpprt/nauclio/internal/gen/nauclio/v1"
	"github.com/dbpprt/nauclio/internal/model"
	"github.com/dbpprt/nauclio/internal/store"
)

func TestGlobalSyncAndOutboxCommandsEndToEnd(t *testing.T) {
	t.Setenv("NAUCLIO_ENABLE_MOCK_HARNESS", "1")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Sync", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	client, _ := newConnectTestClient(t, data, &fakeRunner{})

	stream, err := client.WatchSync(ctx, connect.NewRequest(&naucliov1.SyncRequest{ConversationLimit: 20, HeartbeatMs: 1_000}))
	if err != nil {
		t.Fatal(err)
	}
	if !stream.Receive() {
		t.Fatalf("initial sync: %v", stream.Err())
	}
	initial := stream.Msg()
	if initial.GetSnapshot() == nil || initial.GetCursor().GetEpoch() == "" || len(initial.GetSnapshot().GetState().GetProjects()) != 1 {
		t.Fatalf("initial frame=%#v", initial)
	}

	request := &naucliov1.CreateConversationRequest{
		ProjectId: project.ID, BoardId: board.ID, Lane: model.LaneTodo,
		Title: "Optimistic card", Prompt: "Queue me", Provider: "mock", Model: "mock", DeferStart: true,
		ClientId: "mac-installation", CommandId: "create-1",
	}
	created, err := client.CreateCard(ctx, connect.NewRequest(request))
	if err != nil {
		t.Fatal(err)
	}
	repeated, err := client.CreateCard(ctx, connect.NewRequest(request))
	if err != nil || repeated.Msg.GetId() != created.Msg.GetId() {
		t.Fatalf("idempotent create first=%q repeated=%#v err=%v", created.Msg.GetId(), repeated.Msg, err)
	}
	cards, err := data.ListCards(store.CardFilter{Project: project.ID, Scope: model.ConversationScopeBoard})
	if err != nil || len(cards) != 1 {
		t.Fatalf("cards=%#v err=%v", cards, err)
	}

	found := false
	for stream.Receive() {
		frame := stream.Msg()
		for _, card := range frame.GetSnapshot().GetState().GetCards() {
			if card.GetId() == created.Msg.GetId() {
				found = true
			}
		}
		if found {
			break
		}
	}
	if !found {
		t.Fatalf("created card was not globally streamed: %v", stream.Err())
	}

	chatRequest := &naucliov1.CreateConversationRequest{
		ProjectId: project.ID, Title: "Outbox chat", Prompt: "Wait", Provider: "mock", Model: "mock", DeferStart: true,
		ClientId: "android-installation", CommandId: "chat-1",
	}
	chat, err := client.CreateChat(ctx, connect.NewRequest(chatRequest))
	if err != nil {
		t.Fatal(err)
	}
	message := &naucliov1.SendMessageRequest{
		CardId: chat.Msg.GetId(), ClientId: "android-installation", CommandId: "message-1", MessageId: "msg_local_visible",
		Provider: "mock", Model: "mock", Parts: []*naucliov1.MessagePart{{Type: "text", Text: "Send once"}},
	}
	firstSend, err := client.SendMessage(ctx, connect.NewRequest(message))
	if err != nil {
		t.Fatal(err)
	}
	secondSend, err := client.SendMessage(ctx, connect.NewRequest(message))
	if err != nil || secondSend.Msg.GetMessageId() != firstSend.Msg.GetMessageId() {
		t.Fatalf("idempotent send first=%#v second=%#v err=%v", firstSend.Msg, secondSend.Msg, err)
	}

	deadline := time.Now().Add(5 * time.Second)
	for {
		conversation, conversationErr := data.Conversation(chat.Msg.GetId())
		if conversationErr != nil {
			t.Fatal(conversationErr)
		}
		count := 0
		for _, item := range conversation.Messages {
			if item.ID == "msg_local_visible" {
				count++
			}
		}
		resolved, _ := data.ResolveCard(chat.Msg.GetId())
		if count == 1 && conversation.Status == "idle" && resolved.Runtime == "idle" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("stable message count=%d conversation=%#v", count, conversation)
		}
		time.Sleep(10 * time.Millisecond)
	}
	// runTurn closes its update channel after publishing the idle projections;
	// allow the draining goroutine to observe that close before TempDir cleanup.
	time.Sleep(100 * time.Millisecond)
	if err := data.WaitForWriter(ctx); err != nil {
		t.Fatal(err)
	}

}
