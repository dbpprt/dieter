package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"golang.org/x/sys/unix"
	"google.golang.org/protobuf/proto"
)

func syncRecoveryFixture(t *testing.T) (*store.Store, *grpcAPI, model.Card) {
	t.Helper()
	data := store.New(t.TempDir())
	p, err := data.CreateProject(store.CreateProjectInput{Name: "Sync recovery", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	c, err := data.CreateChat(store.CreateCardInput{Project: p.ID, Title: "before"})
	if err != nil {
		t.Fatal(err)
	}
	return data, &grpcAPI{server: NewWithRunner(data, nil, &fakeRunner{})}, c
}

func TestSyncBurstDoesNotSkipMetadataBeyondDiagnosticBatch(t *testing.T) {
	data, api, card := syncRecoveryFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	initial := true
	found := false
	stop := errors.New("done")
	err := api.watchSync(ctx, &dieterv1.SyncRequest{ConversationLimit: 30, RecentConversationLimit: 8}, func(frame *dieterv1.SyncFrame) error {
		if initial {
			initial = false
			for range 256 {
				if _, _, err := data.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"text-delta","delta":"x"}`)); err != nil {
					return err
				}
			}
			_, err := data.UpdateCard(card.ID, "after", "fixture")
			return err
		}
		if frame.Heartbeat {
			return nil
		}
		for _, chat := range frame.GetDelta().GetChats() {
			if chat.Id == card.ID && chat.Title == "after" {
				found = true
			}
		}
		current, _, _ := data.SyncEvents(^uint64(0), 1)
		if frame.GetCursor().GetSequence() != current.Sequence {
			t.Errorf("applied cursor did not match complete projection")
		}
		return stop
	})
	if !errors.Is(err, stop) || !found {
		t.Fatalf("lost metadata beyond row 256: found=%v err=%v", found, err)
	}
}

func TestSyncRecoveryFrameIncludesEventsThroughPublishedCursor(t *testing.T) {
	data, api, _ := syncRecoveryFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	stop := errors.New("done")
	var initialSequence uint64
	err := api.watchSync(ctx, &dieterv1.SyncRequest{}, func(frame *dieterv1.SyncFrame) error {
		if initialSequence == 0 {
			initialSequence = frame.GetCursor().GetSequence()
			pending, err := json.Marshal(store.SyncEvent{
				Sequence: initialSequence + 1,
				Kind:     "store_changed",
			})
			if err != nil {
				return err
			}
			return os.WriteFile(filepath.Join(data.Root, "sync", "pending.json"), pending, 0600)
		}
		if frame.GetHeartbeat() || frame.GetCursor().GetSequence() <= initialSequence {
			return nil
		}
		if len(frame.GetEvents()) != 1 || frame.GetEvents()[0].GetSequence() != frame.GetCursor().GetSequence() {
			t.Fatalf("recovered cursor skipped its diagnostic event: %#v", frame)
		}
		return stop
	})
	if !errors.Is(err, stop) {
		t.Fatalf("recovered sync event was not published: %v", err)
	}
}

func TestSyncHeartbeatsSurviveBlockedProjectionAndCancellation(t *testing.T) {
	data, api, _ := syncRecoveryFixture(t)
	lock, err := os.OpenFile(filepath.Join(data.Root, ".writer-admission"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	frameReceived := make(chan *dieterv1.SyncFrame, 1)
	go func() {
		done <- api.watchSync(ctx, &dieterv1.SyncRequest{HeartbeatMs: 1000}, func(frame *dieterv1.SyncFrame) error { frameReceived <- frame; return nil })
	}()
	select {
	case frame := <-frameReceived:
		if !frame.Heartbeat || !frame.TransportOnly || !frame.ProjectionPending || frame.Cursor != nil {
			t.Fatalf("blocked projection advertised data: %+v", frame)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("projection blocked the transport heartbeat")
	}
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("cancellation did not release watch")
	}
	// The projection worker must release its process mutex after cancellation.
	_ = unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	ctx2, cancel2 := context.WithTimeout(context.Background(), time.Second)
	defer cancel2()
	if _, _, err := data.GlobalStateContext(ctx2); err != nil {
		t.Fatal(err)
	}
}

func TestSyncResumesOnlyExactRetainedProjection(t *testing.T) {
	data, api, card := syncRecoveryFixture(t)
	stop := errors.New("done")
	var after *dieterv1.SyncCursor
	request := &dieterv1.SyncRequest{}
	if err := api.watchSync(context.Background(), request, func(frame *dieterv1.SyncFrame) error { after = frame.Cursor; return stop }); !errors.Is(err, stop) {
		t.Fatal(err)
	}
	if after.GetProjectionId() == "" {
		t.Fatal("missing resumable projection identity")
	}
	if _, err := data.UpdateCard(card.ID, "after", "fixture"); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	frames := 0
	err := api.watchSync(ctx, &dieterv1.SyncRequest{After: after}, func(frame *dieterv1.SyncFrame) error {
		if frame.Heartbeat {
			return nil
		}
		frames++
		if frame.Snapshot != nil || frame.Reset_ {
			t.Fatal("retained cursor unexpectedly bootstrapped")
		}
		if len(frame.GetDelta().GetChats()) != 1 || frame.Delta.Chats[0].Title != "after" {
			t.Fatalf("bad resumed delta: %+v", frame)
		}
		return stop
	})
	if !errors.Is(err, stop) {
		t.Fatal(err)
	}
	after = proto.Clone(after).(*dieterv1.SyncCursor)
	after.ProjectionId = "evicted"
	err = api.watchSync(ctx, &dieterv1.SyncRequest{After: after}, func(frame *dieterv1.SyncFrame) error {
		if !frame.Reset_ || frame.Snapshot == nil {
			t.Fatal("missing projection was not explicitly reset")
		}
		return stop
	})
	if !errors.Is(err, stop) {
		t.Fatal(err)
	}
}

func TestSyncMetadataArrivesBeforeMalformedConversation(t *testing.T) {
	data, api, card := syncRecoveryFixture(t)
	dir := filepath.Join(data.Root, "conversations", card.ID)
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "snapshot.json"), []byte("broken"), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	frames := 0
	stop := errors.New("done")
	err := api.watchSync(ctx, &dieterv1.SyncRequest{ConversationLimit: 30, RecentConversationLimit: 8}, func(frame *dieterv1.SyncFrame) error {
		if frame.Heartbeat {
			return nil
		}
		frames++
		if frames == 1 {
			if frame.Snapshot == nil || len(frame.Snapshot.State.Chats) != 1 || len(frame.Snapshot.Conversations) != 0 {
				t.Fatalf("metadata bootstrap: %+v", frame)
			}
			return nil
		}
		return stop
	})
	if !errors.Is(err, stop) {
		t.Fatal(err)
	}
}

func TestSyncDirectoryPagesStayWithinWireBudget(t *testing.T) {
	snapshot := &dieterv1.GlobalSnapshot{State: &dieterv1.State{}}
	for i := range 30 {
		snapshot.State.Chats = append(snapshot.State.Chats, &dieterv1.Card{Id: fmt.Sprint(i), Title: strings.Repeat("x", 600000)})
	}
	var ids []string
	pages := 0
	cursor := &dieterv1.SyncCursor{Epoch: "test", Sequence: 7}
	err := sendBoundedSyncFrame(&dieterv1.SyncFrame{Snapshot: snapshot, Cursor: cursor, Reset_: true}, func(frame *dieterv1.SyncFrame) error {
		pages++
		if proto.Size(frame) > maxSyncFrameBytes {
			t.Fatal("oversized frame")
		}
		if frame.ProjectionPending && frame.Cursor != nil {
			t.Fatal("partial batch advanced cursor")
		}
		ids = append(ids, func() []string {
			var result []string
			for _, c := range frame.GetDelta().GetChats() {
				result = append(result, c.Id)
			}
			return result
		}()...)
		return nil
	})
	if err != nil || pages < 3 || len(ids) != 30 {
		t.Fatalf("paged directory: pages=%d ids=%d err=%v", pages, len(ids), err)
	}

}

func TestConversationByteBudgetPreservesPagingBoundaries(t *testing.T) {
	_, api, card := syncRecoveryFixture(t)
	conversation := model.Conversation{CardID: card.ID}
	for i := range 30 {
		conversation.Messages = append(conversation.Messages, model.UIMessage{ID: fmt.Sprint(i), Role: "assistant", Parts: []model.UIMessagePart{{Type: "text", Text: strings.Repeat("x", 600000)}}})
		conversation.Subagents = append(conversation.Subagents, model.Subagent{ID: fmt.Sprint(i), MessageID: fmt.Sprint(i), RecentOutput: []string{"output"}})
		conversation.TaskPlans = append(conversation.TaskPlans, model.TaskPlan{ID: fmt.Sprint(i), MessageID: fmt.Sprint(i), State: "done"})
	}
	snapshot := api.conversationSnapshotFrom(model.CardDetail{Card: card}, conversation, 30, nil)
	if proto.Size(snapshot) > 12<<20 {
		t.Fatal("selected conversation exceeded its byte budget")
	}
	if !snapshot.Page.HasMore || snapshot.Page.Total != 30 || snapshot.Page.End != 30 || snapshot.Page.Start != int32(30-len(snapshot.Conversation.Messages)) {
		t.Fatalf("incorrect byte-bounded page: %+v", snapshot.Page)
	}
	if snapshot.Conversation.Messages[len(snapshot.Conversation.Messages)-1].Id != "29" {
		t.Fatal("latest message was dropped")
	}
	if len(snapshot.Conversation.Subagents) != len(snapshot.Conversation.Messages) || len(snapshot.Conversation.TaskPlans) != len(snapshot.Conversation.Messages) {
		t.Fatal("paging retained progress for messages outside the page")
	}
}
