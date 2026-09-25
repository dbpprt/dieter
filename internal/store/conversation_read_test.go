package store

import (
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func TestResponseReadReceiptPersistsAndCannotClearNewReply(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowReview)
	card, err := s.CreateChat(CreateCardInput{Project: project.ID, Title: "Replies"})
	if err != nil {
		t.Fatal(err)
	}
	appendChunk := func(id, kind string, fields map[string]string) int64 {
		t.Helper()
		if fields == nil {
			fields = map[string]string{}
		}
		fields["type"] = kind
		fields["messageId"] = id
		event, _, err := s.AppendConversationEvent(card.ID, "ui-chunk", id, id, fields)
		if err != nil {
			t.Fatal(err)
		}
		return event.Seq
	}
	appendChunk("one", "text-start", map[string]string{"id": "text"})
	appendChunk("one", "text-delta", map[string]string{"id": "text", "delta": "First reply"})
	before, _ := s.ResolveCard(card.ID)
	if before.ResponseSeq != 0 {
		t.Fatal("streaming is not a completed reply")
	}
	first := appendChunk("one", "finish", nil)
	before, _ = s.ResolveCard(card.ID)
	if before.ResponseSeq != first || before.ResponseMessageID != "one" || before.SeenResponseSeq != 0 {
		t.Fatalf("unread reply: %+v", before)
	}
	seen, err := s.MarkConversationRead(card.ID, first)
	if err != nil || seen.SeenResponseSeq != first || seen.LastActivityAt != before.LastActivityAt {
		t.Fatalf("receipt: %+v %v", seen, err)
	}
	appendChunk("two", "start", map[string]string{"messageId": "two"})
	appendChunk("two", "text-start", map[string]string{"id": "text2"})
	appendChunk("two", "text-delta", map[string]string{"id": "text2", "delta": "Second reply"})
	second := appendChunk("two", "finish", nil)
	stale, err := s.MarkConversationRead(card.ID, first)
	if err != nil || stale.ResponseSeq != second || stale.SeenResponseSeq != first {
		t.Fatalf("stale receipt cleared new reply: %+v %v", stale, err)
	}
	if _, err := s.MarkConversationRead(card.ID, second+1); err == nil {
		t.Fatal("accepted future receipt")
	}
	reopened := New(s.Root)
	defer reopened.Close()
	restored, err := reopened.ResolveCard(card.ID)
	if err != nil || restored.ResponseSeq != second || restored.SeenResponseSeq != first {
		t.Fatalf("durability: %+v %v", restored, err)
	}
	identity, _ := s.PeerIdentity()
	data, err := s.PeerData(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	peer, ok, err := sharedCard(data, card.ID, model.Card{})
	if err != nil || !ok || peer.ResponseSeq != second || peer.SeenResponseSeq != first {
		t.Fatalf("peer read state: %+v %v", peer, err)
	}
}

func TestEmptyOrFailedAssistantDoesNotCreateUnreadReply(t *testing.T) {
	for _, end := range []string{"finish", "error", "abort"} {
		t.Run(end, func(t *testing.T) {
			s, project, _ := setup(t, model.WorkflowReview)
			card, _ := s.CreateChat(CreateCardInput{Project: project.ID, Title: end})
			_, _, err := s.AppendConversationEvent(card.ID, "ui-chunk", "turn", "message", map[string]string{"type": end})
			if err != nil {
				t.Fatal(err)
			}
			updated, _ := s.ResolveCard(card.ID)
			if updated.ResponseSeq != 0 {
				t.Fatal("empty/error/abort created unread response")
			}
		})
	}
}
