package store

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
)

func TestConversationActivityCoalescesOnlyTokens(t *testing.T) {
	at := time.Now().UTC()
	for _, kind := range []string{"text-delta", "reasoning-delta", "tool-input-delta", "finish", "abort", "error", "message-metadata", "tool-input-start"} {
		data, _ := json.Marshal(map[string]string{"type": kind})
		event := model.ConversationEvent{Type: "ui-chunk", CreatedAt: at.Format(time.RFC3339Nano), Data: data}
		tokens := kind == "text-delta" || kind == "reasoning-delta" || kind == "tool-input-delta"
		if shouldPublishConversationActivity(at.Add(-time.Millisecond).Format(time.RFC3339Nano), event) == tokens {
			t.Errorf("wrong publication policy for %s", kind)
		}
		if !shouldPublishConversationActivity(at.Add(-250*time.Millisecond).Format(time.RFC3339Nano), event) {
			t.Errorf("activity must advance at bounded intervals: %s", kind)
		}
	}
}

func TestCoalescedActivityRetainsJournalAndFlushesSemanticEventToPeer(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowReview)
	card, err := s.CreateChat(CreateCardInput{Project: project.ID, Title: "stream"})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err = s.AppendConversationEvent(card.ID, "ui-chunk", "t", "m", map[string]string{"type": "text-start", "id": "text"}); err != nil {
		t.Fatal(err)
	}
	for range 20 {
		if _, _, err = s.AppendConversationEvent(card.ID, "ui-chunk", "t", "m", map[string]string{"type": "text-delta", "id": "text", "delta": "token"}); err != nil {
			t.Fatal(err)
		}
	}
	// A fresh Store has no in-memory projection. Replay must recover every
	// acknowledged delta even if the last derived timestamp was coalesced.
	reopened := New(s.Root)
	defer reopened.Close()
	conversation, err := reopened.Conversation(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if conversation.LastSeq != 21 {
		t.Fatalf("lost durable events: %d", conversation.LastSeq)
	}
	event, _, err := reopened.AppendConversationEvent(card.ID, "ui-chunk", "t", "m", map[string]string{"type": "finish"})
	if err != nil {
		t.Fatal(err)
	}
	updated, err := s.ResolveCard(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if updated.LastActivityAt != event.CreatedAt {
		t.Fatal("finish did not flush activity")
	}
	identity, err := s.PeerIdentity()
	if err != nil {
		t.Fatal(err)
	}
	data, err := s.PeerData(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	peerCard, ok, err := sharedCard(data, card.ID, model.Card{})
	if err != nil || !ok || peerCard.LastActivityAt != event.CreatedAt {
		t.Fatalf("peer summary not flushed: %+v %v", peerCard, err)
	}
}
