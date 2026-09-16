package store

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"

	"github.com/dbpprt/dieter/internal/model"
)

type conversationCheckpoint struct {
	conversation     model.Conversation
	snapshot, events os.FileInfo
}

type conversationCheckpoints struct {
	mu       sync.Mutex
	flushing sync.Mutex
	pending  map[string]conversationCheckpoint
	bytes    int64
}

// Called with the writer lock held; the immutable checkpoint is encoded and
// fsynced only after releasing it. The durable event journal remains intact.
func (s *Store) queueConversationCheckpoint(id string, c model.Conversation) {
	snapshot, _ := os.Stat(filepath.Join(s.conversationPath(id), "snapshot.json"))
	events, _ := os.Stat(filepath.Join(s.conversationPath(id), "events.ndjson"))
	s.checkpoints.mu.Lock()
	defer s.checkpoints.mu.Unlock()
	if s.checkpoints.pending == nil {
		s.checkpoints.pending = make(map[string]conversationCheckpoint)
	}
	size := int64(4096)
	if snapshot != nil {
		size += snapshot.Size()
	}
	if events != nil {
		size += events.Size()
	}
	if old, ok := s.checkpoints.pending[id]; ok {
		s.checkpoints.bytes -= checkpointBytes(old)
		delete(s.checkpoints.pending, id)
	}
	// Dropping an optional checkpoint never drops a durable journal event.
	if size > 128<<20 || s.checkpoints.bytes+size > 128<<20 {
		return
	}
	s.checkpoints.pending[id] = conversationCheckpoint{cloneConversation(c), snapshot, events}
	s.checkpoints.bytes += size
}

func (s *Store) flushConversationCheckpoints() {
	if !s.checkpoints.flushing.TryLock() {
		return
	}
	defer s.checkpoints.flushing.Unlock()
	for range 4 {
		s.checkpoints.mu.Lock()
		id := ""
		var checkpoint conversationCheckpoint
		for key, v := range s.checkpoints.pending {
			id, checkpoint = key, v
			delete(s.checkpoints.pending, key)
			s.checkpoints.bytes -= checkpointBytes(v)
			break
		}
		s.checkpoints.mu.Unlock()
		if id == "" {
			return
		}
		if err := s.writeConversationCheckpoint(id, checkpoint); err != nil {
			slog.Warn("conversation checkpoint deferred; journal retained", "cardID", id, "error", err)
		}
	}
}

func (s *Store) writeConversationCheckpoint(id string, c conversationCheckpoint) error {
	wire := conversationCheckpointWire{Conversation: c.conversation}
	if c.events != nil {
		wire.EventOffset = c.events.Size()
		wire.EventBoundary, _ = conversationEventBoundary(filepath.Join(s.conversationPath(id), "events.ndjson"), wire.EventOffset)
	}
	snapshot, err := json.Marshal(wire)
	if err != nil {
		return err
	}
	dir := s.conversationPath(id)
	file, err := os.CreateTemp(dir, ".checkpoint-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err := file.Write(snapshot); err != nil {
		file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	release, err := s.beginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	path := filepath.Join(dir, "snapshot.json")
	current, _ := os.Stat(path)
	events, _ := os.Stat(filepath.Join(dir, "events.ndjson"))
	// Another checkpoint or journal replacement wins. Appends are safe: replay
	// applies the suffix following this older checkpoint on recovery.
	if !sameFileRevision(current, c.snapshot) || events == nil || c.events == nil || !os.SameFile(events, c.events) || events.Size() < c.events.Size() {
		return nil
	}
	if err := os.Rename(file.Name(), path); err != nil {
		return err
	}
	updated, _ := os.Stat(path)
	s.conversations.mu.Lock()
	if entry, ok := s.conversations.entries[id]; ok && sameFileRevision(entry.snapshot, current) {
		if entry.snapshot != nil {
			s.conversations.bytes -= entry.snapshot.Size()
			entry.bytes -= entry.snapshot.Size()
		}
		if updated != nil {
			s.conversations.bytes += updated.Size()
			entry.bytes += updated.Size()
		}
		entry.snapshot = updated
		if s.conversations.bytes > maxConversationCacheBytes {
			delete(s.conversations.entries, id)
			s.conversations.bytes -= entry.bytes
		} else {
			s.conversations.entries[id] = entry
		}
	}
	s.conversations.mu.Unlock()
	return nil
}

// Extra JSON fields are ignored by old versions, which can always replay the
// retained journal. Validate both ends before trusting an offset after restart.
type conversationCheckpointWire struct {
	model.Conversation
	EventOffset   int64  `json:"eventOffset,omitempty"`
	EventBoundary string `json:"eventBoundary,omitempty"`
}

func conversationEventBoundary(path string, offset int64) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	if offset <= 0 {
		return "", nil
	}
	n := min(offset, int64(128))
	first := make([]byte, n)
	tail := make([]byte, n)
	if _, err := io.ReadFull(io.NewSectionReader(file, 0, n), first); err != nil {
		return "", err
	}
	if _, err := io.ReadFull(io.NewSectionReader(file, offset-n, n), tail); err != nil {
		return "", err
	}
	if tail[len(tail)-1] != '\n' {
		return "", io.ErrUnexpectedEOF
	}
	h := sha256.New()
	h.Write(first)
	h.Write(tail)
	return hex.EncodeToString(h.Sum(nil)), nil
}

func checkpointBytes(c conversationCheckpoint) int64 {
	size := int64(4096)
	if c.snapshot != nil {
		size += c.snapshot.Size()
	}
	if c.events != nil {
		size += c.events.Size()
	}
	return size
}
