package server

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/gen/dieter/v1/dieterv1connect"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
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
		WorkspaceMode: model.WorkspaceModeWorktree,
		ClientId:      "mac-installation", CommandId: "create-1",
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
		WorkspaceMode: model.WorkspaceModeProject,
		ClientId:      "android-installation", CommandId: "chat-1",
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

func TestMetadataSyncSuppressesSemanticallyEmptyDelta(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	data := store.New(t.TempDir())
	if _, err := data.CreateProject(store.CreateProjectInput{Name: "Empty delta", Path: testRepository(t)}); err != nil {
		t.Fatal(err)
	}
	client, _ := newConnectTestClient(t, data, &fakeRunner{})
	stream, err := client.WatchSync(ctx, connect.NewRequest(&dieterv1.SyncRequest{ConversationLimit: 0, HeartbeatMs: 1_000}))
	if err != nil {
		t.Fatal(err)
	}
	if !stream.Receive() {
		t.Fatalf("initial metadata sync: %v", stream.Err())
	}
	initial := stream.Msg()
	if initial.GetSnapshot() == nil {
		t.Fatalf("initial frame=%#v", initial)
	}
	if err := data.SaveCommandResult("sync-test", "projection-neutral", store.CommandResult{Kind: "test"}); err != nil {
		t.Fatal(err)
	}
	for stream.Receive() {
		frame := stream.Msg()
		if frame.GetHeartbeat() || frame.GetCursor().GetSequence() <= initial.GetCursor().GetSequence() {
			continue
		}
		if frame.GetDelta() != nil || frame.GetSnapshot() != nil || len(frame.GetEvents()) == 0 {
			t.Fatalf("projection-neutral event was not cursor-only: delta=%v frame=%#v", frame.GetDelta(), frame)
		}
		return
	}
	t.Fatalf("projection-neutral event was not streamed: %v", stream.Err())
}

func TestIdleDaemonReconciliationDoesNotPublishSyncEvents(t *testing.T) {
	data := store.New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}

	daemonCtx, stopDaemon := context.WithCancel(context.Background())
	daemonDone := make(chan error, 1)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	go func() {
		daemonDone <- ListenDaemon(daemonCtx, address, data, &fakeRunner{}, logger)
	}()
	defer func() {
		stopDaemon()
		select {
		case <-daemonDone:
		case <-time.After(5 * time.Second):
			t.Error("idle daemon did not stop")
		}
	}()

	client := dieterv1connect.NewDieterServiceClient(&http.Client{}, "http://"+address)
	readyDeadline := time.Now().Add(5 * time.Second)
	for {
		readyCtx, cancelReady := context.WithTimeout(context.Background(), 250*time.Millisecond)
		_, healthErr := client.Health(readyCtx, connect.NewRequest(&emptypb.Empty{}))
		cancelReady()
		if healthErr == nil {
			break
		}
		if time.Now().After(readyDeadline) {
			t.Fatalf("idle daemon did not become ready: %v", healthErr)
		}
		time.Sleep(20 * time.Millisecond)
	}

	before, existing, err := data.SyncEvents(0, 256)
	if err != nil {
		t.Fatal(err)
	}
	if len(existing) != 0 {
		t.Fatalf("empty daemon started with sync events: %#v", existing)
	}

	watchCtx, stopWatch := context.WithCancel(context.Background())
	stream, err := client.WatchSync(watchCtx, connect.NewRequest(&dieterv1.SyncRequest{
		ConversationLimit: 0,
		HeartbeatMs:       1_000,
	}))
	if err != nil {
		stopWatch()
		t.Fatal(err)
	}
	if !stream.Receive() {
		stopWatch()
		t.Fatalf("initial idle sync: %v", stream.Err())
	}
	initial := stream.Msg()
	if initial.GetSnapshot() == nil || initial.GetCursor().GetSequence() != before.Sequence {
		stopWatch()
		t.Fatalf("initial idle frame=%#v, high-water=%#v", initial, before)
	}

	started := time.Now()
	timer := time.AfterFunc(25*time.Second, stopWatch)
	heartbeats := 0
	violations := make([]string, 0)
	for stream.Receive() {
		frame := stream.Msg()
		if !frame.GetHeartbeat() || frame.GetEvent() != nil || len(frame.GetEvents()) != 0 || frame.GetDelta() != nil || frame.GetSnapshot() != nil {
			violations = append(violations, fmt.Sprintf("non-heartbeat frame: %#v", frame))
			continue
		}
		if frame.GetCursor().GetSequence() != before.Sequence {
			violations = append(violations, fmt.Sprintf("heartbeat cursor advanced to %d", frame.GetCursor().GetSequence()))
		}
		heartbeats++
	}
	timer.Stop()
	if elapsed := time.Since(started); elapsed < 25*time.Second {
		t.Fatalf("idle reconciliation observation ended early after %s: %v", elapsed, stream.Err())
	}
	if heartbeats < 20 {
		t.Errorf("idle WatchSync heartbeats=%d, want at least 20", heartbeats)
	}

	after, events, err := data.SyncEvents(before.Sequence, 256)
	if err != nil {
		t.Fatal(err)
	}
	if after != before || len(events) != 0 {
		violations = append(violations, fmt.Sprintf("sync advanced from %#v to %#v with events=%#v", before, after, events))
	}
	if len(violations) != 0 {
		t.Fatalf("idle reconciliation published sync changes: %v", violations)
	}
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
		WorkspaceMode: model.WorkspaceModeProject,
		ClientId:      "android-installation", CommandId: "bounded-chat-1",
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

func TestGlobalSyncCoalescesJournalBurstToHighwater(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	data := store.New(t.TempDir())
	if _, err := data.CreateProject(store.CreateProjectInput{Name: "Burst", Path: testRepository(t)}); err != nil {
		t.Fatal(err)
	}
	application := NewWithRunner(data, nil, &fakeRunner{})
	api := &grpcAPI{server: application}
	initial := make(chan *dieterv1.SyncFrame, 1)
	releaseInitial := make(chan struct{})
	frames := make(chan *dieterv1.SyncFrame, 2)
	done := make(chan error, 1)
	go func() {
		done <- api.watchSync(ctx, &dieterv1.SyncRequest{ConversationLimit: 0, HeartbeatMs: 10_000}, func(frame *dieterv1.SyncFrame) error {
			if frame.GetSnapshot() != nil {
				initial <- frame
				select {
				case <-releaseInitial:
					return nil
				case <-ctx.Done():
					return ctx.Err()
				}
			}
			frames <- frame
			return nil
		})
	}()
	bootstrap := <-initial
	for index := 0; index < 300; index++ {
		if err := data.SaveCommandResult("burst-test", fmt.Sprintf("command-%03d", index), store.CommandResult{Kind: "test"}); err != nil {
			t.Fatal(err)
		}
	}
	highwater, _, err := data.SyncEvents(bootstrap.GetCursor().GetSequence(), 1)
	if err != nil {
		t.Fatal(err)
	}
	close(releaseInitial)
	select {
	case frame := <-frames:
		if frame.GetCursor().GetSequence() != highwater.Sequence {
			t.Fatalf("burst cursor=%d want highwater=%d", frame.GetCursor().GetSequence(), highwater.Sequence)
		}
		if len(frame.GetEvents()) != 256 {
			t.Fatalf("coalesced diagnostic events=%d want bounded 256", len(frame.GetEvents()))
		}
		if frame.GetSnapshot() != nil || frame.GetDelta() != nil {
			t.Fatalf("projection-neutral burst carried projection data: %#v", frame)
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for coalesced sync frame")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("WatchSync did not stop")
	}
}

func TestBoundedGlobalSyncReusesUnchangedConversationProjection(t *testing.T) {
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Reuse", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Cached tail"}); err != nil {
		t.Fatal(err)
	}
	application := NewWithRunner(data, nil, &fakeRunner{})
	api := &grpcAPI{server: application}
	first, err := api.globalSnapshot(30, 8, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(first.snapshot.GetConversations()) != 1 {
		t.Fatalf("initial conversations=%d", len(first.snapshot.GetConversations()))
	}
	if err := data.SaveCommandResult("reuse-test", "projection-neutral", store.CommandResult{Kind: "test"}); err != nil {
		t.Fatal(err)
	}
	second, err := api.globalSnapshot(30, 8, first)
	if err != nil {
		t.Fatal(err)
	}
	if second.snapshot.GetConversations()[0] != first.snapshot.GetConversations()[0] {
		t.Fatal("unchanged conversation snapshot was rebuilt")
	}
	if delta := globalDelta(first.snapshot, second.snapshot); !globalDeltaEmpty(delta) {
		t.Fatalf("projection-neutral refresh produced delta: %#v", delta)
	}
}

func TestConversationChunkSyncReusesMetadataProjection(t *testing.T) {
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Streaming", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Long stream"})
	if err != nil {
		t.Fatal(err)
	}
	api := &grpcAPI{server: NewWithRunner(data, nil, &fakeRunner{})}
	first, err := api.globalSnapshot(30, 8, nil)
	if err != nil {
		t.Fatal(err)
	}
	cursor, _, err := data.SyncEvents(0, 1)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := data.AppendUIChunk(chat.ID, "turn", json.RawMessage(`{"type":"text","text":"chunk"}`)); err != nil {
		t.Fatal(err)
	}
	_, events, err := data.SyncEvents(cursor.Sequence, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 1 || events[0].Kind != "conversation_changed" {
		t.Fatalf("chunk events = %#v", events)
	}
	second, err := api.globalSnapshotReusingMetadata(30, 8, first, true)
	if err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(first.snapshot.GetState(), second.snapshot.GetState()) {
		t.Fatal("conversation-only refresh rebuilt metadata")
	}
	if second.snapshot.GetConversations()[0].GetConversation().GetLastSeq() <= first.snapshot.GetConversations()[0].GetConversation().GetLastSeq() {
		t.Fatal("conversation-only refresh did not advance the transcript")
	}
}

func TestOnePassGlobalStateMatchesPerProjectProjection(t *testing.T) {
	data := store.New(t.TempDir())
	for _, name := range []string{"Alpha", "Beta"} {
		project, err := data.CreateProject(store.CreateProjectInput{Name: name, Path: testRepository(t)})
		if err != nil {
			t.Fatal(err)
		}
		board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := data.CreateCard(store.CreateCardInput{Project: project.ID, Board: board.ID, Title: name + " card"}); err != nil {
			t.Fatal(err)
		}
		if _, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: name + " chat"}); err != nil {
			t.Fatal(err)
		}
	}

	expected := &dieterv1.State{StorePath: data.Root}
	projects, err := data.ListProjects()
	if err != nil {
		t.Fatal(err)
	}
	for _, project := range projects {
		expected.Projects = append(expected.Projects, protoProject(project))
		projectState, err := data.State(project.ID, store.CardFilter{})
		if err != nil {
			t.Fatal(err)
		}
		for _, board := range projectState.Boards {
			expected.Boards = append(expected.Boards, protoBoard(board))
		}
		for _, card := range projectState.Cards {
			expected.Cards = append(expected.Cards, protoCard(card))
		}
		for _, chat := range projectState.Chats {
			expected.Chats = append(expected.Chats, protoCard(chat))
		}
	}
	application := NewWithRunner(data, nil, &fakeRunner{})
	actual, err := (&grpcAPI{server: application}).globalSnapshot(0, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(expected, actual.snapshot.GetState()) {
		t.Fatalf("one-pass state differs\nexpected=%v\nactual=%v", expected, actual.snapshot.GetState())
	}
}

func TestGetStateAllProjectsSupportsConditionalDirectoryRefresh(t *testing.T) {
	data := store.New(t.TempDir())
	var firstProject model.Project
	var firstBoard model.Board
	for index, name := range []string{"Alpha", "Beta"} {
		project, err := data.CreateProject(store.CreateProjectInput{Name: name, Path: testRepository(t)})
		if err != nil {
			t.Fatal(err)
		}
		board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := data.CreateCard(store.CreateCardInput{Project: project.ID, Board: board.ID, Title: name + " card"}); err != nil {
			t.Fatal(err)
		}
		if _, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: name + " chat"}); err != nil {
			t.Fatal(err)
		}
		if index == 0 {
			firstProject, firstBoard = project, board
		}
	}

	api := &grpcAPI{server: NewWithRunner(data, nil, &fakeRunner{})}
	initial, err := api.GetState(context.Background(), &dieterv1.GetStateRequest{AllProjects: true})
	if err != nil {
		t.Fatal(err)
	}
	if initial.GetNotModified() || initial.GetCursor().GetEpoch() == "" || len(initial.GetProjects()) != 2 || len(initial.GetBoards()) != 2 || len(initial.GetCards()) != 2 || len(initial.GetChats()) != 2 {
		t.Fatalf("all-project state = %#v", initial)
	}
	unchanged, err := api.GetState(context.Background(), &dieterv1.GetStateRequest{
		AllProjects: true, IfNotModified: initial.GetCursor(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if !unchanged.GetNotModified() || unchanged.GetCursor().GetSequence() != initial.GetCursor().GetSequence() || len(unchanged.GetProjects()) != 0 || len(unchanged.GetCards()) != 0 {
		t.Fatalf("conditional state = %#v", unchanged)
	}
	if _, err := data.CreateCard(store.CreateCardInput{Project: firstProject.ID, Board: firstBoard.ID, Title: "Changed"}); err != nil {
		t.Fatal(err)
	}
	changed, err := api.GetState(context.Background(), &dieterv1.GetStateRequest{
		AllProjects: true, IfNotModified: initial.GetCursor(),
	})
	if err != nil {
		t.Fatal(err)
	}
	if changed.GetNotModified() || changed.GetCursor().GetSequence() <= initial.GetCursor().GetSequence() || len(changed.GetCards()) != 3 {
		t.Fatalf("changed conditional state = %#v", changed)
	}
}
