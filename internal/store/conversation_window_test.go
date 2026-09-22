package store

import (
	"encoding/json"
	"fmt"
	"reflect"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func TestConversationWindowsPreserveHistoryAndOwnMutablePayloads(t *testing.T) {
	s, p, b := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, Title: "window"})
	if err != nil {
		t.Fatal(err)
	}
	messages := make([]model.UIMessage, 140)
	for i := range messages {
		messages[i] = model.UIMessage{ID: fmt.Sprint(i), Role: "assistant", Metadata: json.RawMessage(`{"key":1}`), Parts: []model.UIMessagePart{{Type: "tool", Input: json.RawMessage(`{"arg":1}`), Output: json.RawMessage(`{"result":2}`)}}}
	}
	if _, err := s.InitializeForkConversation(card.ID, messages); err != nil {
		t.Fatal(err)
	}
	for _, cold := range []bool{false, true} {
		source := s
		if cold {
			source = New(s.Root)
			t.Cleanup(func() { _ = source.Close() })
		}
		for _, tc := range []struct {
			limit      int
			before     *int32
			start, end int
		}{
			{0, nil, 110, 140}, {200, nil, 40, 140}, {10, windowBefore(45), 35, 45}, {10, windowBefore(0), 0, 0}, {10, windowBefore(999), 130, 140},
		} {
			window, err := source.ConversationWindowByID(card.ID, tc.limit, tc.before)
			if err != nil {
				t.Fatal(err)
			}
			if window.Start != tc.start || window.End != tc.end || window.Total != 140 {
				t.Fatalf("page=%+v", window)
			}
			if !reflect.DeepEqual(window.Conversation.Messages, messages[tc.start:tc.end]) {
				t.Fatal("window changed messages")
			}
			if len(window.Conversation.ForkSeed) != 0 || len(window.Conversation.Session) != 0 {
				t.Fatal("execution state copied into client window")
			}
			if len(window.Conversation.Messages) > 0 {
				window.Conversation.Messages[0].Metadata[0] = 'x'
				window.Conversation.Messages[0].Parts[0].Input[0] = 'x'
				window.Conversation.Messages[0].Parts[0].Output[0] = 'x'
			}
		}
		full, err := source.ConversationByID(card.ID)
		if err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(full.Messages, messages) || !reflect.DeepEqual(full.ForkSeed, messages) || len(full.Session) != 0 {
			t.Fatal("window mutation corrupted durable/cache history")
		}
	}
	if _, err := s.SetConversationSession(card.ID, "", json.RawMessage(`{"resume":"private"}`)); err != nil {
		t.Fatal(err)
	}
	window, err := s.ConversationWindowByID(card.ID, 30, nil)
	if err != nil || len(window.Conversation.Session) != 0 {
		t.Fatal("client window contains execution session", err)
	}
	full, err := s.ConversationByID(card.ID)
	if err != nil || string(full.Session) != `{"resume":"private"}` {
		t.Fatal("client window removed execution session", err)
	}
	if _, err := s.ConversationWindowByID(card.ID, 30, windowBefore(-1)); err == nil {
		t.Fatal("negative before accepted")
	}
	if _, err := s.ConversationWindowByID("../invalid", 30, nil); err == nil {
		t.Fatal("invalid ID accepted")
	}
}

func TestConversationWindowSeesCrossProcessAppendWithoutTruncatingCache(t *testing.T) {
	s, p, b := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, Title: "window replay"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.StartConversationTurn(card.ID, "turn", "user", "hello"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"text-delta","delta":"one"}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ConversationWindowByID(card.ID, 1, nil); err != nil {
		t.Fatal(err)
	}
	other := New(s.Root)
	defer other.Close()
	if _, _, err := other.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"text-delta","delta":"two"}`)); err != nil {
		t.Fatal(err)
	}
	window, err := s.ConversationWindowByID(card.ID, 1, nil)
	if err != nil {
		t.Fatal(err)
	}
	if window.Total != 2 || len(window.Conversation.Messages) != 1 || window.Conversation.Messages[0].Parts[0].Text != "onetwo" {
		t.Fatalf("stale window: %+v", window)
	}
	full, err := s.ConversationByID(card.ID)
	if err != nil || len(full.Messages) != 2 {
		t.Fatal("projection replaced cache with a tail", err)
	}
}
func windowBefore(value int32) *int32 { return &value }
