package conversations

import (
	"os"

	"github.com/dbpprt/dieter/internal/model"
)

// Test seams for the external conversation tests, which run against the composed store.

// CheckpointWire is the encoding of a conversation checkpoint (snapshot.json).
type CheckpointWire = conversationCheckpointWire

// SameFileRevision reports whether two stats describe the same file revision.
func SameFileRevision(a, b os.FileInfo) bool { return sameFileRevision(a, b) }

// ProjectionCacheClock is the use clock of the transcript projection cache.
func (s *Store) ProjectionCacheClock() uint64 {
	s.conversations.mu.Lock()
	defer s.conversations.mu.Unlock()
	return s.conversations.clock
}

// LoadConversation loads a card's conversation projection without the owner check.
func (s *Store) LoadConversation(cardID string) (model.Conversation, error) {
	return s.loadConversation(cardID)
}

// AppendConversationEvents appends events inside the caller's write (crash
// injection: the caller exits before the write finishes).
func (s *Store) AppendConversationEvents(card model.Card, conversation model.Conversation, events []model.ConversationEvent) ([]model.ConversationEvent, model.Conversation, error) {
	return s.appendConversationEvents(card, conversation, events)
}
