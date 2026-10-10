package server

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/gen/dieter/v1/dieterv1connect"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

func changesFixture(t *testing.T) (*store.Store, *grpcAPI, model.Card) {
	t.Helper()
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Changes", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "before", Prompt: "Owner-only prompt"})
	if err != nil {
		t.Fatal(err)
	}
	return data, &grpcAPI{server: NewWithRunner(data, slog.New(slog.NewTextHandler(io.Discard, nil)), &fakeRunner{})}, card
}

// watchChangesFrames runs a stream until stop is called or the stream fails.
func watchChangesFrames(t *testing.T, api *grpcAPI, request *dieterv1.ChangesRequest) (<-chan *dieterv1.ChangesFrame, func() error) {
	t.Helper()
	ctx, cancel := context.WithCancel(t.Context())
	frames := make(chan *dieterv1.ChangesFrame, 256)
	done := make(chan error, 1)
	go func() {
		done <- api.watchChanges(ctx, request, func(frame *dieterv1.ChangesFrame) error {
			select {
			case frames <- proto.Clone(frame).(*dieterv1.ChangesFrame):
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		})
	}()
	var once sync.Once
	var result error
	stop := func() error {
		once.Do(func() {
			cancel()
			select {
			case result = <-done:
			case <-time.After(5 * time.Second):
				result = errors.New("change stream did not stop")
			}
		})
		return result
	}
	t.Cleanup(func() { _ = stop() })
	return frames, stop
}

func nextChangesFrame(t *testing.T, frames <-chan *dieterv1.ChangesFrame) *dieterv1.ChangesFrame {
	t.Helper()
	select {
	case frame := <-frames:
		return frame
	case <-time.After(10 * time.Second):
		t.Fatal("no change frame")
		return nil
	}
}

// untilCaughtUp collects frames through the first caught-up data frame.
func untilCaughtUp(t *testing.T, frames <-chan *dieterv1.ChangesFrame) []*dieterv1.ChangesFrame {
	t.Helper()
	var collected []*dieterv1.ChangesFrame
	for {
		frame := nextChangesFrame(t, frames)
		collected = append(collected, frame)
		if frame.GetCaughtUp() {
			return collected
		}
	}
}

// nextDataFrame skips heartbeats.
func nextDataFrame(t *testing.T, frames <-chan *dieterv1.ChangesFrame) *dieterv1.ChangesFrame {
	t.Helper()
	for {
		if frame := nextChangesFrame(t, frames); !frame.GetHeartbeat() {
			return frame
		}
	}
}

func recordIDs(frames ...*dieterv1.ChangesFrame) map[string]*dieterv1.PeerRecord {
	ids := map[string]*dieterv1.PeerRecord{}
	for _, frame := range frames {
		for _, record := range frame.GetRecords() {
			ids[record.GetKind()+"/"+record.GetId()] = record
		}
	}
	return ids
}

func TestChangesStreamRecordsThenOnlyWhatChanged(t *testing.T) {
	data, api, card := changesFixture(t)
	identity, err := data.PeerIdentity()
	if err != nil {
		t.Fatal(err)
	}
	frames, _ := watchChangesFrames(t, api, &dieterv1.ChangesRequest{HeartbeatMs: 1_000})
	initial := untilCaughtUp(t, frames)
	first := initial[0]
	if !first.GetResetRecords() || !first.GetResetLocal() || first.GetDaemonId() != identity.DaemonID || first.GetAccount() != identity.Account {
		t.Fatalf("first frame does not start both halves: %#v", first)
	}
	checkouts, err := data.ListCheckouts(card.ProjectID)
	if err != nil || len(checkouts) != 1 {
		t.Fatalf("checkouts=%v err=%v", checkouts, err)
	}
	var checkout *dieterv1.Checkout
	for _, frame := range initial {
		for _, value := range frame.GetOwnedCheckouts() {
			if value.GetId() == checkouts[0].ID {
				checkout = value
			}
		}
	}
	if checkout == nil || checkout.GetPath() != checkouts[0].Path || checkout.GetPath() == "" {
		t.Fatalf("owned checkout lacks its path: %#v", checkout)
	}
	records := recordIDs(initial...)
	identityRecord := records["item/"+card.ID+".identity"]
	placement := records["item/"+card.ID+".placement"]
	if identityRecord == nil || placement == nil || records["project/"+card.ProjectID+".name"] == nil {
		t.Fatalf("shared records missing: %v", records)
	}
	if placement.GetValueRevision() == "" || placement.GetRevision() == "" || placement.GetVersions()[0].GetRank() == "" || len(placement.GetVersions()[0].GetProvenanceJson()) != 0 {
		t.Fatalf("record lacks rank or revisions, or leaks proofs: %#v", placement)
	}
	var owned *dieterv1.Card
	for _, frame := range initial {
		for _, value := range frame.GetOwnedCards() {
			if value.GetId() == card.ID {
				owned = value
			}
		}
	}
	if owned == nil || owned.GetInitialPrompt() != "Owner-only prompt" || owned.GetTitle() != "" || owned.GetLane() != "" {
		t.Fatalf("owner details missing or carry shared fields: %#v", owned)
	}

	if _, err := data.RenameCard(card.ID, "after"); err != nil {
		t.Fatal(err)
	}
	changed := nextDataFrame(t, frames)
	changedRecords := recordIDs(changed)
	if changedRecords["item/"+card.ID+".title"] == nil || changedRecords["project/"+card.ProjectID+".name"] != nil {
		t.Fatalf("rename did not stream only what changed: %v", changedRecords)
	}
	if changed.GetResetRecords() || changed.GetResetLocal() {
		t.Fatalf("live change reset the stream: %#v", changed)
	}
	if changed.GetCursor().GetRecordsSequence() <= initial[len(initial)-1].GetCursor().GetRecordsSequence() {
		t.Fatalf("cursor did not advance: %v", changed.GetCursor())
	}
}

func TestChangesResumeFromCursorAndResetWhenItNoLongerApplies(t *testing.T) {
	data, api, card := changesFixture(t)
	frames, stop := watchChangesFrames(t, api, &dieterv1.ChangesRequest{})
	initial := untilCaughtUp(t, frames)
	cursor := initial[len(initial)-1].GetCursor()
	if err := stop(); !errors.Is(err, context.Canceled) {
		t.Fatalf("stop: %v", err)
	}
	if _, err := data.RenameCard(card.ID, "while away"); err != nil {
		t.Fatal(err)
	}

	resumed, _ := watchChangesFrames(t, api, &dieterv1.ChangesRequest{After: cursor})
	frame := nextDataFrame(t, resumed)
	records := recordIDs(frame)
	if frame.GetResetRecords() || frame.GetResetLocal() || records["item/"+card.ID+".title"] == nil || records["project/"+card.ProjectID+".name"] != nil {
		t.Fatalf("resume did not continue from the cursor: reset=%v/%v records=%v", frame.GetResetRecords(), frame.GetResetLocal(), records)
	}

	for name, after := range map[string]*dieterv1.ChangesCursor{
		"other epochs":   {RecordsEpoch: "other", RecordsSequence: 1, LocalEpoch: "other", LocalSequence: 1},
		"ahead of store": {RecordsEpoch: cursor.GetRecordsEpoch(), RecordsSequence: cursor.GetRecordsSequence() + 1000, LocalEpoch: cursor.GetLocalEpoch(), LocalSequence: cursor.GetLocalSequence() + 1000},
	} {
		t.Run(name, func(t *testing.T) {
			stream, _ := watchChangesFrames(t, api, &dieterv1.ChangesRequest{After: after})
			first := nextDataFrame(t, stream)
			if !first.GetResetRecords() || !first.GetResetLocal() {
				t.Fatalf("stale cursor was not reset: %#v", first)
			}
			if recordIDs(untilCaughtUpFrom(t, first, stream)...)["project/"+card.ProjectID+".name"] == nil {
				t.Fatal("reset did not replay the records")
			}
		})
	}
}

func untilCaughtUpFrom(t *testing.T, first *dieterv1.ChangesFrame, frames <-chan *dieterv1.ChangesFrame) []*dieterv1.ChangesFrame {
	t.Helper()
	collected := []*dieterv1.ChangesFrame{first}
	if first.GetCaughtUp() {
		return collected
	}
	return append(collected, untilCaughtUp(t, frames)...)
}

func TestChangesSendOnlyHeartbeatsForNoops(t *testing.T) {
	data, api, card := changesFixture(t)
	frames, _ := watchChangesFrames(t, api, &dieterv1.ChangesRequest{HeartbeatMs: 1_000})
	initial := untilCaughtUp(t, frames)
	cursor := initial[len(initial)-1].GetCursor()
	if err := data.SaveCommandResult("changes-test", "projection-neutral", store.CommandResult{Kind: "test"}); err != nil {
		t.Fatal(err)
	}
	if _, err := data.UpdateCardCache(card.ID, store.CardCacheInput{Runtime: card.Runtime}); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		frame := nextChangesFrame(t, frames)
		if !frame.GetHeartbeat() || !frame.GetCaughtUp() || !proto.Equal(frame.GetCursor(), cursor) {
			t.Fatalf("a no-op produced data or moved the cursor: %#v", frame)
		}
	}
}

func TestChangesCarryRunningTurnActivityAndFinish(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Activity", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Turn", Provider: "mock", Model: "mock"})
	if err != nil {
		t.Fatal(err)
	}
	release := make(chan struct{})
	stopped := make(chan struct{})
	api := &grpcAPI{server: NewWithRunner(data, slog.New(slog.NewTextHandler(io.Discard, nil)), gatedRunner{release: release, stopped: stopped})}
	frames, _ := watchChangesFrames(t, api, &dieterv1.ChangesRequest{HeartbeatMs: 1_000})
	untilCaughtUp(t, frames)
	updates, err := api.server.app.StartCardWithMessageParts(card.ID, []model.UIMessagePart{{Type: "text", Text: "Work"}}, "", "", "", nil, "")
	if err != nil {
		t.Fatal(err)
	}
	finished := make(chan struct{})
	go func() {
		for range updates {
		}
		close(finished)
	}()
	var activity *dieterv1.Conversation
	for activity == nil {
		for _, value := range nextDataFrame(t, frames).GetActivities() {
			for _, message := range value.GetMessages() {
				for _, part := range message.GetParts() {
					if value.GetCardId() == card.ID && part.GetType() == "text" && part.GetText() == "first" {
						activity = value
					}
				}
			}
		}
	}
	if activity.GetStatus() != "running" || activity.GetMessages()[0].GetRole() != "user" {
		t.Fatalf("activity does not start at the turn's user message: %#v", activity)
	}
	close(release)
	<-stopped
	<-finished
	for idle := false; !idle; {
		if record := recordIDs(nextDataFrame(t, frames))["item/"+card.ID+".summary"]; record != nil {
			for _, version := range record.GetVersions() {
				idle = idle || strings.Contains(string(version.GetValueJson()), `"runtime":"idle"`)
			}
		}
	}
	if err := data.WaitForWriter(t.Context()); err != nil {
		t.Fatal(err)
	}
}

func TestChangesRemoveArchivedOwnedCards(t *testing.T) {
	data, api, card := changesFixture(t)
	frames, _ := watchChangesFrames(t, api, &dieterv1.ChangesRequest{HeartbeatMs: 1_000})
	untilCaughtUp(t, frames)
	if _, err := data.ArchiveCard(card.ID, true); err != nil {
		t.Fatal(err)
	}
	removed, archivedRecord := false, false
	for !removed || !archivedRecord {
		frame := nextDataFrame(t, frames)
		for _, id := range frame.GetRemovedOwnedCardIds() {
			removed = removed || id == card.ID
		}
		if record := recordIDs(frame)["item/"+card.ID+".archived"]; record != nil {
			archivedRecord = string(record.GetVersions()[0].GetValueJson()) == "true"
		}
	}
}

func TestChangesStreamWhileAWriterHoldsTheLockAndStopOnCancellation(t *testing.T) {
	data, api, _ := changesFixture(t)
	lock, err := os.OpenFile(filepath.Join(data.Root, ".writer-admission"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	frames, stop := watchChangesFrames(t, api, &dieterv1.ChangesRequest{HeartbeatMs: 1_000})
	if frame := nextChangesFrame(t, frames); !frame.GetResetRecords() {
		t.Fatalf("first frame: %#v", frame)
	}
	if err := stop(); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation did not release the stream: %v", err)
	}
}

func TestChangesRecoverAWriterKilledBeforeItsCommit(t *testing.T) {
	data, api, _ := changesFixture(t)
	frames, _ := watchChangesFrames(t, api, &dieterv1.ChangesRequest{HeartbeatMs: 1_000})
	untilCaughtUp(t, frames)
	before, err := data.ChangeCount()
	if err != nil {
		t.Fatal(err)
	}
	pending := fmt.Sprintf(`{"sequence":%d,"kind":"store_changed"}`, before+1)
	if err := os.WriteFile(filepath.Join(data.Root, "sync", "pending.json"), []byte(pending), 0o600); err != nil {
		t.Fatal(err)
	}
	for deadline := time.Now().Add(10 * time.Second); data.SyncMutationPending(); time.Sleep(20 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("killed writer was not recovered")
		}
	}
	if after, err := data.ChangeCount(); err != nil || after != before+1 {
		t.Fatalf("recovered change count=%d want %d (%v)", after, before+1, err)
	}
}

func TestChangesSkipAnUnreadableConversation(t *testing.T) {
	data, api, card := changesFixture(t)
	if _, err := data.MarkPromptSent(card.ID); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(data.Root, "conversations", card.ID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "snapshot.json"), []byte("broken"), 0o600); err != nil {
		t.Fatal(err)
	}
	frames, _ := watchChangesFrames(t, api, &dieterv1.ChangesRequest{})
	owned := false
	for _, frame := range untilCaughtUp(t, frames) {
		for _, value := range frame.GetOwnedCards() {
			owned = owned || value.GetId() == card.ID
		}
		if len(frame.GetActivities()) != 0 {
			t.Fatalf("unreadable conversation produced activity: %v", frame.GetActivities())
		}
	}
	if !owned {
		t.Fatal("an unreadable conversation stalled its card")
	}
}

func TestChangesBoundConcurrentStreams(t *testing.T) {
	_, api, _ := changesFixture(t)
	api.server.changeStreams.Store(maxChangeStreams)
	err := api.watchChanges(t.Context(), &dieterv1.ChangesRequest{}, func(*dieterv1.ChangesFrame) error { return nil })
	if status.Code(err) != codes.ResourceExhausted || api.server.changeStreams.Load() != maxChangeStreams {
		t.Fatalf("stream above the bound: %v", err)
	}
}

func TestChangesFramesStayBounded(t *testing.T) {
	data, api, card := changesFixture(t)
	// Each chat has several records, so a dozen span more than one page.
	for index := range 12 {
		if _, err := data.CreateChat(store.CreateCardInput{Project: card.ProjectID, Title: fmt.Sprintf("chat %d", index)}); err != nil {
			t.Fatal(err)
		}
	}
	frames, _ := watchChangesFrames(t, api, &dieterv1.ChangesRequest{})
	initial := untilCaughtUp(t, frames)
	if len(initial) < 2 {
		t.Fatalf("%d chats fit one frame", len(initial))
	}
	for index, frame := range initial {
		if len(frame.GetRecords()) > 64 || len(frame.GetOwnedCards()) > maxLocalChanges || proto.Size(frame) > 4<<20 {
			t.Fatalf("frame %d exceeds its bounds: records=%d owned=%d bytes=%d", index, len(frame.GetRecords()), len(frame.GetOwnedCards()), proto.Size(frame))
		}
		if frame.GetCaughtUp() != (index == len(initial)-1) {
			t.Fatalf("frame %d caughtUp=%v", index, frame.GetCaughtUp())
		}
	}
	owned := 0
	for _, frame := range initial {
		owned += len(frame.GetOwnedCards())
	}
	if owned != 13 {
		t.Fatalf("owned cards=%d", owned)
	}
}

func TestLocalChangesFillTheByteBudgetAndOversizedEntriesGoAlone(t *testing.T) {
	local := newLocalChanges(nil)
	large := strings.Repeat("p", 3<<20)
	if err := local.apply(map[string]proto.Message{
		"card/a": &dieterv1.Card{Id: "a", InitialPrompt: large},
		"card/b": &dieterv1.Card{Id: "b", InitialPrompt: large},
		"card/c": &dieterv1.Card{Id: "c", InitialPrompt: large},
	}); err != nil {
		t.Fatal(err)
	}
	changes, epoch, next, reset, more := local.since("", 0, maxLocalChanges, maxChangesFrameBytes, true)
	if len(changes) != 2 || !reset || !more || next != changes[1].entry.sequence {
		t.Fatalf("first page: changes=%d reset=%v more=%v next=%d", len(changes), reset, more, next)
	}
	// Beside a record page, an entry that does not fit waits.
	waiting, _, unchanged, _, more := local.since(epoch, next, maxLocalChanges, 1<<20, false)
	if len(waiting) != 0 || !more || unchanged != next {
		t.Fatalf("entry did not wait: changes=%d more=%v next=%d", len(waiting), more, unchanged)
	}
	// Alone, even an entry above the budget is sent.
	last, _, end, reset, more := local.since(epoch, next, maxLocalChanges, 1<<20, true)
	if len(last) != 1 || reset || more || end != 3 {
		t.Fatalf("last page: changes=%d reset=%v more=%v next=%d", len(last), reset, more, end)
	}
	// Small entries are bounded by count.
	small := map[string]proto.Message{}
	for index := range maxLocalChanges + 5 {
		small[fmt.Sprintf("card/s%d", index)] = &dieterv1.Card{Id: fmt.Sprint(index)}
	}
	if err := local.apply(small); err != nil {
		t.Fatal(err)
	}
	page, _, _, reset, more := local.since(epoch, end, maxLocalChanges, maxChangesFrameBytes, true)
	if len(page) != maxLocalChanges || reset || !more {
		t.Fatalf("count bound: changes=%d reset=%v more=%v", len(page), reset, more)
	}
}

func TestChangesCarryPeerSyncIssues(t *testing.T) {
	interval := localDiagnosticsInterval
	localDiagnosticsInterval = 50 * time.Millisecond
	t.Cleanup(func() { localDiagnosticsInterval = interval })
	data, api, _ := changesFixture(t)
	identity, err := data.PeerIdentity()
	if err != nil {
		t.Fatal(err)
	}
	frames, _ := watchChangesFrames(t, api, &dieterv1.ChangesRequest{HeartbeatMs: 1_000})
	untilCaughtUp(t, frames)
	now := time.Now().UTC()
	for _, issue := range []store.PeerSyncDiagnostic{
		{PeerID: "online", LastAttemptAt: now.Format(time.RFC3339Nano), FailureCode: "Unavailable"},
		{PeerID: "rejected", LastAttemptAt: now.Add(-time.Hour).Format(time.RFC3339Nano), FailureCode: "invalid-record", RecordID: "b_one.retired"},
		{PeerID: "old", LastAttemptAt: now.Add(-time.Hour).Format(time.RFC3339Nano), FailureCode: "Unavailable"},
	} {
		if err := data.RecordPeerSync(identity, issue); err != nil {
			t.Fatal(err)
		}
	}
	if err := data.ObservePeerAvailability(identity, map[string]bool{"online": true, "old": true}); err != nil {
		t.Fatal(err)
	}
	var issues []*dieterv1.PeerSyncDiagnostic
	for issues == nil {
		if status := nextDataFrame(t, frames).GetPeerSync(); status != nil {
			issues = status.GetIssues()
		}
	}
	peers := map[string]bool{}
	for _, issue := range issues {
		peers[issue.GetPeerId()] = true
	}
	if len(peers) != 2 || !peers["online"] || !peers["rejected"] {
		t.Fatalf("issues=%v", issues)
	}
	for _, peer := range []string{"online", "rejected"} {
		if err := data.RecordPeerSync(identity, store.PeerSyncDiagnostic{PeerID: peer, LastAttemptAt: time.Now().UTC().Format(time.RFC3339Nano)}); err != nil {
			t.Fatal(err)
		}
	}
	for {
		if status := nextDataFrame(t, frames).GetPeerSync(); status != nil && len(status.GetIssues()) == 0 {
			return
		}
	}
}

func TestChangesAndOutboxCommandsEndToEnd(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Outbox", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	client, _ := newConnectTestClient(t, data, &fakeRunner{})
	stream, err := client.WatchChanges(ctx, connect.NewRequest(&dieterv1.ChangesRequest{HeartbeatMs: 1_000}))
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()

	request := &dieterv1.CreateConversationRequest{
		ProjectId: project.ID, BoardId: board.ID, Lane: model.LaneTodo,
		Title: "Optimistic card", Prompt: "Queue me", Provider: "mock", Model: "mock", DeferStart: true,
		WorkspaceMode: model.WorkspaceModeWorktree, ClientId: "mac-installation", CommandId: "create-1",
	}
	created, err := client.CreateCard(ctx, connect.NewRequest(request))
	if err != nil {
		t.Fatal(err)
	}
	repeated, err := client.CreateCard(ctx, connect.NewRequest(request))
	if err != nil || repeated.Msg.GetId() != created.Msg.GetId() {
		t.Fatalf("idempotent create first=%q repeated=%#v err=%v", created.Msg.GetId(), repeated.Msg, err)
	}
	chatRequest := &dieterv1.CreateConversationRequest{
		ProjectId: project.ID, Title: "Outbox chat", Prompt: "Wait", Provider: "mock", Model: "mock", DeferStart: true,
		WorkspaceMode: model.WorkspaceModeProject, ClientId: "android-installation", CommandId: "chat-1",
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
	// Clients confirm a created card by its shared identity and a sent message
	// by the owner's activity.
	createdSeen, delivered := false, false
	for !createdSeen || !delivered {
		if !stream.Receive() {
			t.Fatalf("change stream ended: %v", stream.Err())
		}
		frame := stream.Msg()
		createdSeen = createdSeen || recordIDs(frame)["item/"+created.Msg.GetId()+".identity"] != nil
		for _, activity := range frame.GetActivities() {
			for _, item := range activity.GetMessages() {
				delivered = delivered || activity.GetCardId() == chat.Msg.GetId() && item.GetId() == "msg_local_visible"
			}
		}
	}
	deadline := time.Now().Add(20 * time.Second)
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
		if count == 1 && conversation.Status == "idle" && resolved.Runtime == "idle" && conversation.ActiveTurn == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("stable message count=%d conversation=%#v", count, conversation)
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(100 * time.Millisecond)
	if err := data.WaitForWriter(ctx); err != nil {
		t.Fatal(err)
	}
}

func TestIdempotentStartAdmissionReachesTheStream(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Admission", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateCard(store.CreateCardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Admit me", Prompt: "Read only", Provider: "mock", Model: "mock"})
	if err != nil {
		t.Fatal(err)
	}
	release := make(chan struct{})
	var releaseOnce sync.Once
	stopRunner := func() {
		releaseOnce.Do(func() { close(release) })
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			if resolved, err := data.ResolveCard(card.ID); err == nil && resolved.Runtime == "idle" {
				_ = data.WaitForWriter(context.Background())
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
	}
	t.Cleanup(stopRunner)
	client, _ := newConnectTestClient(t, data, gatedRunner{release: release})
	stream, err := client.WatchChanges(ctx, connect.NewRequest(&dieterv1.ChangesRequest{HeartbeatMs: 1_000}))
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	request := &dieterv1.StartCardRequest{CardId: card.ID, ClientId: "android-test", CommandId: "start-once"}
	started, err := client.StartCard(ctx, connect.NewRequest(request))
	if err != nil || !started.Msg.GetAccepted() || started.Msg.GetCard().GetLane() != model.LaneRunning || started.Msg.GetCard().GetInitialPromptSentAt() == "" {
		t.Fatalf("start admission response=%#v err=%v", started.Msg, err)
	}
	replayed, err := client.StartCard(ctx, connect.NewRequest(request))
	if err != nil || !replayed.Msg.GetReplayed() || replayed.Msg.GetCard().GetId() != card.ID {
		t.Fatalf("replayed start=%#v err=%v", replayed.Msg, err)
	}
	for running := false; !running; {
		if !stream.Receive() {
			t.Fatalf("change stream ended: %v", stream.Err())
		}
		if record := recordIDs(stream.Msg())["item/"+card.ID+".placement"]; record != nil {
			for _, version := range record.GetVersions() {
				running = running || strings.Contains(string(version.GetValueJson()), `"lane":"running"`)
			}
		}
	}
	stopRunner()
}

func TestIdleDaemonStreamsOnlyHeartbeatsAndRecordsNoChanges(t *testing.T) {
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
	go func() {
		daemonDone <- ListenDaemon(daemonCtx, address, data, &fakeRunner{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	}()
	defer func() {
		stopDaemon()
		select {
		case <-daemonDone:
		case <-time.After(5 * time.Second):
			t.Error("idle daemon did not stop")
		}
	}()
	client := dieterv1connect.NewDieterServiceClient(localHTTPClient(&http.Client{}, data.Root), "http://"+address)
	for deadline := time.Now().Add(5 * time.Second); ; {
		readyCtx, cancelReady := context.WithTimeout(context.Background(), 250*time.Millisecond)
		_, healthErr := client.Health(readyCtx, connect.NewRequest(&emptypb.Empty{}))
		cancelReady()
		if healthErr == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("idle daemon did not become ready: %v", healthErr)
		}
		time.Sleep(20 * time.Millisecond)
	}
	before, err := data.ChangeCount()
	if err != nil {
		t.Fatal(err)
	}
	watchCtx, stopWatch := context.WithCancel(context.Background())
	stream, err := client.WatchChanges(watchCtx, connect.NewRequest(&dieterv1.ChangesRequest{HeartbeatMs: 1_000}))
	if err != nil {
		stopWatch()
		t.Fatal(err)
	}
	if !stream.Receive() || !stream.Msg().GetCaughtUp() {
		stopWatch()
		t.Fatalf("initial idle frame=%#v err=%v", stream.Msg(), stream.Err())
	}
	started := time.Now()
	timer := time.AfterFunc(25*time.Second, stopWatch)
	heartbeats := 0
	var violations []string
	for stream.Receive() {
		if frame := stream.Msg(); !frame.GetHeartbeat() {
			violations = append(violations, fmt.Sprintf("data frame: %#v", frame))
			continue
		}
		heartbeats++
	}
	timer.Stop()
	if elapsed := time.Since(started); elapsed < 25*time.Second {
		t.Fatalf("idle observation ended early after %s: %v", elapsed, stream.Err())
	}
	if heartbeats < 20 {
		t.Errorf("idle heartbeats=%d, want at least 20", heartbeats)
	}
	if after, err := data.ChangeCount(); err != nil || after != before {
		violations = append(violations, fmt.Sprintf("store recorded changes %d -> %d (%v)", before, after, err))
	}
	if len(violations) != 0 {
		t.Fatalf("idle daemon changed: %v", violations)
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
	actual, err := (&grpcAPI{server: NewWithRunner(data, nil, &fakeRunner{})}).GetState(t.Context(), &dieterv1.GetStateRequest{AllProjects: true})
	if err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(expected, actual) {
		t.Fatalf("one-pass state differs\nexpected=%v\nactual=%v", expected, actual)
	}
}
