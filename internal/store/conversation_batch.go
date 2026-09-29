package store

import (
	"encoding/json"
	"fmt"

	"github.com/dbpprt/dieter/internal/model"
)

const (
	MaxUIChunkBatchEvents = 32
	MaxUIChunkBatchBytes  = 64 << 10
)

// AppendUIChunks persists an ordered, bounded batch in one writer transaction
// and one journal fsync. Success acknowledges every event; failed appends must
// not be retried blindly because a complete prefix may already be on disk.
// Larger individual chunks retain the existing AppendUIChunk path and limit.
func (s *Store) AppendUIChunks(cardRef, turnID string, chunks []json.RawMessage) ([]model.ConversationEvent, model.Conversation, error) {
	if len(chunks) == 0 || len(chunks) > MaxUIChunkBatchEvents {
		return nil, model.Conversation{}, fmt.Errorf("UI chunk batch must contain 1–%d events", MaxUIChunkBatchEvents)
	}
	size := 0
	writeKind := "conversation_changed"
	events := make([]model.ConversationEvent, len(chunks))
	for i, chunk := range chunks {
		size += len(chunk)
		if size > MaxUIChunkBatchBytes || !json.Valid(chunk) {
			return nil, model.Conversation{}, fmt.Errorf("UI chunk batch must contain valid JSON within %d bytes", MaxUIChunkBatchBytes)
		}
		if conversationEventWriteKind("ui-chunk", chunk) == "store_changed" {
			writeKind = "store_changed"
		}
		events[i] = model.ConversationEvent{Type: "ui-chunk", TurnID: turnID, Data: chunk}
	}
	release, err := s.beginWriteKind(writeKind)
	if err != nil {
		return nil, model.Conversation{}, err
	}
	defer release()
	card, err := s.ResolveCard(cardRef)
	if err != nil {
		return nil, model.Conversation{}, err
	}
	conversation, err := s.loadConversation(card.ID)
	if err != nil {
		return nil, model.Conversation{}, err
	}
	return s.appendConversationEvents(card, conversation, events)
}
