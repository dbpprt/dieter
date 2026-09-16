package store

import (
	"bytes"
	"os"
	"slices"
	"sync"

	"github.com/dbpprt/dieter/internal/model"
)

// Entries own their slices. Callers receive copies, so reducers and RPC readers
// cannot race. Strings (the bulk of transcript text) remain immutable and shared.
const maxConversationCacheBytes = 256 << 20

type conversationCacheEntry struct {
	conversation     model.Conversation
	snapshot, events os.FileInfo
	offset           int64
	bytes            int64
	used             uint64
}

type conversationCache struct {
	mu      sync.Mutex
	entries map[string]conversationCacheEntry
	bytes   int64
	clock   uint64
}

func sameFileRevision(a, b os.FileInfo) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return os.SameFile(a, b) && a.Size() == b.Size() && a.ModTime().Equal(b.ModTime())
}

func cloneConversation(c model.Conversation) model.Conversation {
	cloneParts := func(parts []model.UIMessagePart) []model.UIMessagePart {
		parts = slices.Clone(parts)
		for i := range parts {
			parts[i].Input = bytes.Clone(parts[i].Input)
			parts[i].Output = bytes.Clone(parts[i].Output)
		}
		return parts
	}
	cloneMessages := func(messages []model.UIMessage) []model.UIMessage {
		messages = slices.Clone(messages)
		for i := range messages {
			messages[i].Metadata = bytes.Clone(messages[i].Metadata)
			messages[i].Parts = cloneParts(messages[i].Parts)
		}
		return messages
	}
	cloneSelection := func(s *model.HarnessSelection) *model.HarnessSelection {
		if s == nil {
			return nil
		}
		v := *s
		v.ProviderOptions = cloneStringMap(s.ProviderOptions)
		return &v
	}
	c.Messages = cloneMessages(c.Messages)
	c.ForkSeed = cloneMessages(c.ForkSeed)
	c.MergedSourceIDs = slices.Clone(c.MergedSourceIDs)
	c.DraftAttachments = cloneParts(c.DraftAttachments)
	c.PendingTools = slices.Clone(c.PendingTools)
	for i := range c.PendingTools {
		c.PendingTools[i].Input = bytes.Clone(c.PendingTools[i].Input)
	}
	c.Queue = slices.Clone(c.Queue)
	for i := range c.Queue {
		c.Queue[i].Parts = cloneParts(c.Queue[i].Parts)
		c.Queue[i].Selection = cloneSelection(c.Queue[i].Selection)
	}
	c.Session = bytes.Clone(c.Session)
	if c.ActiveTurn != nil {
		v := *c.ActiveTurn
		v.InstructionLabels = slices.Clone(v.InstructionLabels)
		v.Selection = cloneSelection(v.Selection)
		c.ActiveTurn = &v
	}
	if c.PresentedContent != nil {
		v := *c.PresentedContent
		c.PresentedContent = &v
	}
	c.Subagents = slices.Clone(c.Subagents)
	for i := range c.Subagents {
		c.Subagents[i].RecentOutput = slices.Clone(c.Subagents[i].RecentOutput)
	}
	c.TaskPlans = slices.Clone(c.TaskPlans)
	for i := range c.TaskPlans {
		c.TaskPlans[i].Phases = slices.Clone(c.TaskPlans[i].Phases)
		for j := range c.TaskPlans[i].Phases {
			c.TaskPlans[i].Phases[j].Tasks = slices.Clone(c.TaskPlans[i].Phases[j].Tasks)
		}
	}
	return c
}

func (s *Store) cacheConversation(id string, c model.Conversation, snapshot, events os.FileInfo, offset int64) {
	s.rememberConversationStatus(id, c.Status, snapshot, events)
	// File bytes overestimate live projection size (including the retained journal)
	// but provide a cheap conservative bound without encoding on the hot path.
	size := int64(4096)
	if snapshot != nil {
		size += snapshot.Size()
	}
	if events != nil {
		size += events.Size()
	}
	cache := &s.conversations
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if old, ok := cache.entries[id]; ok {
		cache.bytes -= old.bytes
		delete(cache.entries, id)
	}
	if size > maxConversationCacheBytes {
		return
	}
	if cache.entries == nil {
		cache.entries = make(map[string]conversationCacheEntry)
	}
	for len(cache.entries) > 0 && (cache.bytes+size > maxConversationCacheBytes || len(cache.entries) >= 64) {
		oldest := ""
		var age uint64 = ^uint64(0)
		for key, v := range cache.entries {
			if v.used < age {
				oldest, age = key, v.used
			}
		}
		cache.bytes -= cache.entries[oldest].bytes
		delete(cache.entries, oldest)
	}
	cache.clock++
	cache.entries[id] = conversationCacheEntry{cloneConversation(c), snapshot, events, offset, size, cache.clock}
	cache.bytes += size
}
