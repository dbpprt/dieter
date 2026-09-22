package store

import (
	"fmt"

	"github.com/dbpprt/dieter/internal/model"
)

// ConversationWindow is an independently owned client projection. Resume state
// and fork seed belong to execution, not client history windows.
type ConversationWindow struct {
	Conversation      model.Conversation
	Start, End, Total int
}

func (s *Store) ConversationWindowByID(cardID string, limit int, before *int32) (ConversationWindow, error) {
	var result ConversationWindow
	if !validFileID(cardID) {
		return result, fmt.Errorf("card %q: %w", cardID, ErrNotFound)
	}
	if before != nil && *before < 0 {
		return result, fmt.Errorf("before must be a non-negative integer")
	}
	if _, err := s.ResolveCard(cardID); err != nil {
		return result, err
	}
	if limit < 1 {
		limit = 30
	}
	limit = min(limit, 100)
	conversation, err := s.loadConversationView(cardID, func(c model.Conversation) model.Conversation {
		result.Total = len(c.Messages)
		result.End = result.Total
		if before != nil {
			result.End = min(int(*before), result.End)
		}
		result.Start = max(0, result.End-limit)
		c.Messages = c.Messages[result.Start:result.End]
		c.ForkSeed = nil
		c.Session = nil
		return cloneConversation(c)
	})
	result.Conversation = conversation
	return result, err
}
