package store

import (
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"

	"github.com/dbpprt/dieter/internal/model"
)

type cardUsageCacheEntry struct {
	revision string
	usage    model.TokenUsage
}

// Cache only small summaries, not transcripts. Including both file revisions
// invalidates across processes and after an event committed before a crash.
func (s *Store) cardTokenUsage(cardID string) *model.TokenUsage {
	revision := ""
	for _, name := range []string{"snapshot.json", "events.ndjson"} {
		info, err := os.Stat(filepath.Join(s.conversationPath(cardID), name))
		if err != nil && !os.IsNotExist(err) {
			return &model.TokenUsage{Partial: true}
		}
		if err == nil {
			revision += fmt.Sprintf("%s:%d:%d;", name, info.Size(), info.ModTime().UnixNano())
		}
	}
	if revision == "" {
		return nil
	}
	s.usageMu.Lock()
	defer s.usageMu.Unlock()
	if entry, ok := s.usageCache[cardID]; ok && entry.revision == revision {
		usage := entry.usage
		return &usage
	}
	conversation, err := s.loadConversation(cardID)
	if err != nil {
		return &model.TokenUsage{Partial: true}
	}
	usage := conversationTokenUsage(conversation)
	if s.usageCache == nil || len(s.usageCache) >= 512 {
		s.usageCache = make(map[string]cardUsageCacheEntry)
	}
	s.usageCache[cardID] = cardUsageCacheEntry{revision, usage}
	return &usage
}

func conversationTokenUsage(conversation model.Conversation) model.TokenUsage {
	var result model.TokenUsage
	seen := map[string]bool{}
	for _, seed := range conversation.ForkSeed {
		seen[seed.ID] = true
	}
	for _, message := range conversation.Messages {
		if message.Role != "assistant" || seen[message.ID] {
			continue
		}
		if message.ID != "" {
			seen[message.ID] = true
		}
		var metadata struct {
			TotalUsage json.RawMessage `json:"totalUsage"`
			Usage      json.RawMessage `json:"usage"`
		}
		_ = json.Unmarshal(message.Metadata, &metadata)
		var usage struct {
			Input  *int64 `json:"inputTokens"`
			Output *int64 `json:"outputTokens"`
			Total  *int64 `json:"totalTokens"`
		}
		cumulative := len(metadata.TotalUsage) > 0 && string(metadata.TotalUsage) != "null"
		raw := metadata.TotalUsage
		if !cumulative {
			raw = metadata.Usage
		}
		if json.Unmarshal(raw, &usage) != nil {
			result.MissingMessages++
			result.Partial = true
			continue
		}
		valid := func(n *int64) bool { return n != nil && *n >= 0 }
		hasInput, hasOutput, hasTotal := valid(usage.Input), valid(usage.Output), valid(usage.Total)
		if !hasInput && !hasOutput && !hasTotal {
			result.MissingMessages++
			result.Partial = true
			continue
		}
		add := func(target *int64, value int64) {
			if value > math.MaxInt64-*target {
				*target = math.MaxInt64
				result.Partial = true
			} else {
				*target += value
			}
		}
		var total int64
		if hasInput {
			add(&result.InputTokens, *usage.Input)
			add(&total, *usage.Input)
		}
		if hasOutput {
			add(&result.OutputTokens, *usage.Output)
			add(&total, *usage.Output)
		}
		if hasTotal {
			total = *usage.Total
		}
		add(&result.TotalTokens, total)
		result.ReportedMessages++
		result.Partial = result.Partial || !cumulative || !hasInput || !hasOutput
	}
	return result
}
