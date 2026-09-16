package store

import (
	"errors"
	"os"
	"path/filepath"
	"sync"
)

// Runtime maintenance scans the whole directory, not only the conversations a
// client is viewing. Its tiny status summaries must survive transcript eviction.
// Both file identities/revisions are required: checkpoint mtime alone can hide a
// newer terminal event when an older checkpoint finishes publishing afterwards.
type conversationStatusEntry struct {
	status           string
	snapshot, events os.FileInfo
	used             uint64
}

type conversationStatusCache struct {
	mu      sync.Mutex
	entries map[string]conversationStatusEntry
	clock   uint64
}

const maxConversationStatuses = 4096

func conversationStatusFiles(dir string) (os.FileInfo, os.FileInfo, error) {
	snapshot, err := os.Stat(filepath.Join(dir, "snapshot.json"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, nil, err
	}
	events, err := os.Stat(filepath.Join(dir, "events.ndjson"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, nil, err
	}
	return snapshot, events, nil
}

func (s *Store) conversationStatus(cardID string) (string, error) {
	snapshot, events, err := conversationStatusFiles(s.conversationPath(cardID))
	if err != nil {
		return "", err
	}
	cache := &s.statuses
	cache.mu.Lock()
	if entry, ok := cache.entries[cardID]; ok && sameFileRevision(entry.snapshot, snapshot) && sameFileRevision(entry.events, events) {
		cache.clock++
		entry.used = cache.clock
		cache.entries[cardID] = entry
		cache.mu.Unlock()
		return entry.status, nil
	}
	cache.mu.Unlock()
	conversation, err := s.loadConversation(cardID)
	if err != nil {
		return "", err
	}
	// loadConversation also seeds this cache when it publishes a stable replay.
	// Cover its existing-projection and missing-journal paths without pairing an
	// older result with revisions from a concurrent writer.
	afterSnapshot, afterEvents, statErr := conversationStatusFiles(s.conversationPath(cardID))
	if statErr == nil && sameFileRevision(snapshot, afterSnapshot) && sameFileRevision(events, afterEvents) {
		s.rememberConversationStatus(cardID, conversation.Status, snapshot, events)
	}
	return conversation.Status, nil
}

func (s *Store) rememberConversationStatus(id, status string, snapshot, events os.FileInfo) {
	if len(status) > 128 {
		return
	}
	cache := &s.statuses
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if cache.entries == nil {
		cache.entries = make(map[string]conversationStatusEntry)
	}
	if _, exists := cache.entries[id]; !exists && len(cache.entries) >= maxConversationStatuses {
		oldest := ""
		age := ^uint64(0)
		for key, entry := range cache.entries {
			if entry.used < age {
				oldest, age = key, entry.used
			}
		}
		delete(cache.entries, oldest)
	}
	cache.clock++
	cache.entries[id] = conversationStatusEntry{status, snapshot, events, cache.clock}
}
