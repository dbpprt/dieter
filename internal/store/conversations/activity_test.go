package conversations_test

import (
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestCoalescedActivityRetainsJournalAndFlushesSemanticEventToPeer(t *testing.T) {
	t.Parallel()
	s, project, _ := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "stream"})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err = s.Conversations.Append(card.ID, "ui-chunk", "t", "m", map[string]string{"type": "text-start", "id": "text"}); err != nil {
		t.Fatal(err)
	}
	for range 20 {
		if _, _, err = s.Conversations.Append(card.ID, "ui-chunk", "t", "m", map[string]string{"type": "text-delta", "id": "text", "delta": "token"}); err != nil {
			t.Fatal(err)
		}
	}
	// A fresh Store has no in-memory projection. Replay must recover every
	// acknowledged delta even if the last derived timestamp was coalesced.
	reopened := store.New(s.Root)
	defer reopened.Close()
	conversation, err := reopened.Conversations.Get(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if conversation.LastSeq != 21 {
		t.Fatalf("lost durable events: %d", conversation.LastSeq)
	}
	event, _, err := reopened.Conversations.Append(card.ID, "ui-chunk", "t", "m", map[string]string{"type": "finish"})
	if err != nil {
		t.Fatal(err)
	}
	updated, err := s.Kanban.ResolveCard(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if updated.LastActivityAt != event.CreatedAt {
		t.Fatal("finish did not flush activity")
	}
	identity, err := s.Replica.PeerIdentity()
	if err != nil {
		t.Fatal(err)
	}
	data, err := s.Replica.PeerData(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	peerCard, ok, err := kanban.SharedCard(data, card.ID, model.Card{})
	if err != nil || !ok || peerCard.LastActivityAt != event.CreatedAt {
		t.Fatalf("peer summary not flushed: %+v %v", peerCard, err)
	}
}
