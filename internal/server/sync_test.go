package server

import (
	"context"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

func TestGlobalSyncAndOutboxCommandsEndToEnd(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
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

	stream, err := client.WatchSync(ctx, connect.NewRequest(&dieterv1.SyncRequest{ConversationLimit: 20, HeartbeatMs: 1_000}))
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

	request := &dieterv1.CreateConversationRequest{
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

	chatRequest := &dieterv1.CreateConversationRequest{
		ProjectId: project.ID, Title: "Outbox chat", Prompt: "Wait", Provider: "mock", Model: "mock", DeferStart: true,
		ClientId: "android-installation", CommandId: "chat-1",
	}
	chat, err := client.CreateChat(ctx, connect.NewRequest(chatRequest))
	if err != nil {
		t.Fatal(err)
	}
	message := &dieterv1.SendMessageRequest{
		CardId: chat.Msg.GetId(), ClientId: "android-installation", CommandId: "message-1", MessageId: "msg_local_visible",
		Provider: "mock", Model: "mock", Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Send once"}},
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

func TestMetadataDeltaAndIdempotentStartAdmission(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Delta", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateCard(store.CreateCardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Admit me", Prompt: "Read only",
		Provider: "mock", Model: "mock",
	})
	if err != nil {
		t.Fatal(err)
	}
	release := make(chan struct{})
	var releaseOnce sync.Once
	stopRunner := func() {
		releaseOnce.Do(func() { close(release) })
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			resolved, resolveErr := data.ResolveCard(card.ID)
			if resolveErr == nil && resolved.Runtime == "idle" {
				_ = data.WaitForWriter(context.Background())
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
	t.Cleanup(stopRunner)
	client, _ := newConnectTestClient(t, data, gatedRunner{release: release})

	stream, err := client.WatchSync(ctx, connect.NewRequest(&dieterv1.SyncRequest{ConversationLimit: 0, HeartbeatMs: 1_000}))
	if err != nil {
		t.Fatal(err)
	}
	if !stream.Receive() {
		t.Fatalf("initial metadata sync: %v", stream.Err())
	}
	initial := stream.Msg()
	if initial.GetSnapshot() == nil || len(initial.GetSnapshot().GetConversations()) != 0 {
		t.Fatalf("metadata bootstrap unexpectedly contained conversation tails: %#v", initial)
	}

	request := &dieterv1.StartCardRequest{CardId: card.ID, ClientId: "android-test", CommandId: "start-once"}
	started, err := client.StartCard(ctx, connect.NewRequest(request))
	if err != nil {
		t.Fatal(err)
	}
	if !started.Msg.GetAccepted() || started.Msg.GetCard().GetLane() != model.LaneRunning || started.Msg.GetCard().GetInitialPromptSentAt() == "" {
		t.Fatalf("start admission response=%#v", started.Msg)
	}
	replayed, err := client.StartCard(ctx, connect.NewRequest(request))
	if err != nil || !replayed.Msg.GetReplayed() || replayed.Msg.GetCard().GetId() != card.ID {
		t.Fatalf("replayed start=%#v err=%v", replayed.Msg, err)
	}

	found := false
	for stream.Receive() {
		frame := stream.Msg()
		if frame.GetSnapshot() != nil {
			t.Fatalf("live metadata frame duplicated the bootstrap snapshot: %#v", frame)
		}
		for _, changed := range frame.GetDelta().GetCards() {
			if changed.GetId() == card.ID && changed.GetLane() == model.LaneRunning {
				found = true
			}
		}
		if found {
			break
		}
	}
	if !found {
		t.Fatalf("started card was not delivered as a metadata delta: %v", stream.Err())
	}
	stopRunner()
}

func TestBoundedConversationSyncStreamsTranscriptDeltas(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Transcripts", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	client, _ := newConnectTestClient(t, data, &fakeRunner{})

	chat, err := client.CreateChat(ctx, connect.NewRequest(&dieterv1.CreateConversationRequest{
		ProjectId: project.ID, Title: "Warm cache", Prompt: "Hold", Provider: "mock", Model: "mock", DeferStart: true,
		ClientId: "android-installation", CommandId: "bounded-chat-1",
	}))
	if err != nil {
		t.Fatal(err)
	}

	stream, err := client.WatchSync(ctx, connect.NewRequest(&dieterv1.SyncRequest{
		ConversationLimit: 20, RecentConversationLimit: 5, HeartbeatMs: 1_000,
	}))
	if err != nil {
		t.Fatal(err)
	}
	if !stream.Receive() {
		t.Fatalf("bounded bootstrap: %v", stream.Err())
	}
	initial := stream.Msg()
	if initial.GetSnapshot() == nil {
		t.Fatalf("bounded subscribers must bootstrap from a snapshot: %#v", initial)
	}
	bootstrapped := false
	for _, conversation := range initial.GetSnapshot().GetConversations() {
		if conversation.GetDetail().GetCard().GetId() == chat.Msg.GetId() {
			bootstrapped = true
		}
	}
	if !bootstrapped {
		t.Fatalf("bootstrap snapshot missed the recent conversation: %#v", initial.GetSnapshot().GetConversations())
	}

	if _, err = client.SendMessage(ctx, connect.NewRequest(&dieterv1.SendMessageRequest{
		CardId: chat.Msg.GetId(), ClientId: "android-installation", CommandId: "bounded-message-1", MessageId: "msg_bounded_delta",
		Provider: "mock", Model: "mock", Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Reach the tail"}},
	})); err != nil {
		t.Fatal(err)
	}

	found := false
	for stream.Receive() {
		frame := stream.Msg()
		if frame.GetSnapshot() != nil {
			t.Fatalf("bounded live frame duplicated the bootstrap snapshot: %#v", frame)
		}
		for _, conversation := range frame.GetDelta().GetConversations() {
			if conversation.GetDetail().GetCard().GetId() != chat.Msg.GetId() {
				continue
			}
			for _, message := range conversation.GetConversation().GetMessages() {
				if message.GetId() == "msg_bounded_delta" {
					found = true
				}
			}
		}
		if found {
			break
		}
	}
	if !found {
		t.Fatalf("sent message never arrived as a conversation delta: %v", stream.Err())
	}

	deadline := time.Now().Add(5 * time.Second)
	for {
		conversation, conversationErr := data.Conversation(chat.Msg.GetId())
		if conversationErr != nil {
			t.Fatal(conversationErr)
		}
		resolved, _ := data.ResolveCard(chat.Msg.GetId())
		if conversation.Status == "idle" && resolved.Runtime == "idle" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("turn did not settle: %#v", conversation)
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

func TestSyncConversationCardsBoundsSelection(t *testing.T) {
	cards := []*dieterv1.Card{
		{Id: "c_idle_old", Runtime: "idle", LastActivityAt: "2026-01-01T00:00:00Z"},
		{Id: "c_running_old", Runtime: "running", LastActivityAt: "2026-01-02T00:00:00Z"},
		{Id: "c_idle_recent", Runtime: "idle", LastActivityAt: "2026-03-01T00:00:00Z"},
		{Id: "c_idle_middle", Runtime: "idle", UpdatedAt: "2026-02-01T00:00:00Z"},
	}
	selected := syncConversationCards(cards, 1)
	ids := make([]string, 0, len(selected))
	for _, card := range selected {
		ids = append(ids, card.GetId())
	}
	if len(ids) != 2 || ids[0] != "c_idle_recent" || ids[1] != "c_running_old" {
		t.Fatalf("bounded selection=%v", ids)
	}
}
