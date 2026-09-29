package server

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

type batchWatchRunner struct{ release <-chan struct{} }

func (r batchWatchRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	chunk := func(raw string) error { return emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(raw)}) }
	if err := chunk(`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`); err != nil {
		return err
	}
	if err := chunk(`{"type":"text-start","id":"text"}`); err != nil {
		return err
	}
	for part := range 2 {
		for range 17 {
			if err := chunk(`{"type":"text-delta","id":"text","delta":"x"}`); err != nil {
				return err
			}
		}
		if part == 0 {
			select {
			case <-r.release:
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	}
	if err := chunk(`{"type":"finish"}`); err != nil {
		return err
	}
	return emit(harness.Output{Type: "session", State: json.RawMessage(`{"type":"resume-session","data":{"id":"batched-watch"}}`)})
}

func TestConversationWatchReceivesTimedBatchesAndReconnectsDuringTurn(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	data := store.New(t.TempDir())
	defer data.Close()
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Batch watch", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Timed batch", Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	release := make(chan struct{})
	finish := sync.OnceFunc(func() { close(release) })
	defer finish()
	client, _ := newConnectTestClient(t, data, batchWatchRunner{release: release})
	watchCtx, stopWatch := context.WithCancel(ctx)
	defer stopWatch()
	stream, err := client.WatchConversation(watchCtx, connect.NewRequest(&dieterv1.WatchConversationRequest{CardId: card.ID, IntervalMs: 100}))
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	if !stream.Receive() || stream.Msg().GetSnapshot() == nil {
		t.Fatalf("initial snapshot: %v", stream.Err())
	}
	if _, err := client.SendMessage(ctx, connect.NewRequest(&dieterv1.SendMessageRequest{CardId: card.ID, Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Stream"}}})); err != nil {
		t.Fatal(err)
	}
	textIn := func(update *dieterv1.ConversationUpdate) string {
		messages := update.GetChangedMessages()
		if update.GetSnapshot() != nil {
			messages = update.GetSnapshot().GetConversation().GetMessages()
		}
		for _, message := range messages {
			if message.GetRole() == "assistant" {
				for _, part := range message.GetParts() {
					if part.GetType() == "text" {
						return part.GetText()
					}
				}
			}
		}
		return ""
	}
	var seq int64
	for stream.Receive() {
		if textIn(stream.Msg()) == strings.Repeat("x", 17) {
			seq = stream.Msg().GetLastSeq()
			break
		}
	}
	if seq == 0 {
		t.Fatalf("timer did not publish while runner waited: %v", stream.Err())
	}
	reader := store.New(data.Root)
	defer reader.Close()
	conversation, err := reader.Conversation(card.ID)
	if err != nil || conversation.LastSeq < seq || conversation.Messages[1].Parts[0].Text != strings.Repeat("x", 17) || conversation.Status != "running" {
		t.Fatalf("watch published before persistence: %+v %v", conversation, err)
	}
	stopWatch()
	_ = stream.Close()
	resumed, err := client.WatchConversation(ctx, connect.NewRequest(&dieterv1.WatchConversationRequest{CardId: card.ID, AfterSeq: seq, IntervalMs: 100}))
	if err != nil {
		t.Fatal(err)
	}
	defer resumed.Close()
	if !resumed.Receive() || resumed.Msg().GetSnapshot() != nil || resumed.Msg().GetLastSeq() != seq || len(resumed.Msg().GetChangedMessages()) != 0 {
		t.Fatalf("resume duplicated batch: %v %v", resumed.Msg(), resumed.Err())
	}
	finish()
	text := ""
	completed := false
	for resumed.Receive() {
		if next := textIn(resumed.Msg()); next != "" {
			text = next
		}
		if text == strings.Repeat("x", 34) && resumed.Msg().GetStatus() == "idle" && resumed.Msg().GetDetail().GetCard().GetRuntime() == "idle" {
			completed = true
			break
		}
	}
	if !completed {
		t.Fatalf("resumed watch lost completion: text=%q err=%v", text, resumed.Err())
	}
	if err := data.WaitForWriter(ctx); err != nil {
		t.Fatal(err)
	}
	conversation, err = reader.Conversation(card.ID)
	if err != nil || !strings.Contains(string(conversation.Session), "batched-watch") {
		t.Fatalf("watch completion preceded trailing session: %+v %v", conversation, err)
	}
}
