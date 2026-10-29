package conversations_test

import (
	"encoding/json"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestCardTokenUsageProjectsExistingHistoryAndRefreshesAfterRestart(t *testing.T) {
	t.Parallel()
	s, p, b := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, Title: "Usage", Prompt: "Count"})
	if err != nil {
		t.Fatal(err)
	}
	appendChunk := func(raw string) {
		t.Helper()
		if _, _, err := s.Conversations.AppendUIChunk(card.ID, "turn", json.RawMessage(raw)); err != nil {
			t.Fatal(err)
		}
	}
	appendChunk(`{"type":"start","messageId":"answer"}`)
	appendChunk(`{"type":"message-metadata","messageMetadata":{"totalUsage":{"inputTokens":80,"outputTokens":20,"totalTokens":100}}}`)
	for _, data := range []*store.Store{s, store.New(s.Root)} {
		got, err := data.Kanban.ResolveCard(card.ID)
		if err != nil || got.TokenUsage == nil || got.TokenUsage.TotalTokens != 100 {
			t.Fatalf("projection: %+v %v", got.TokenUsage, err)
		}
	}
	appendChunk(`{"type":"message-metadata","messageMetadata":{"totalUsage":{"inputTokens":160,"outputTokens":40,"totalTokens":200}}}`)
	got, err := s.Kanban.ResolveCard(card.ID)
	if err != nil || got.TokenUsage.TotalTokens != 200 || got.TokenUsage.ReportedMessages != 1 {
		t.Fatalf("refresh: %+v %v", got.TokenUsage, err)
	}
	// Replaying the same final metadata replaces the message's usage.
	appendChunk(`{"type":"finish","messageMetadata":{"totalUsage":{"inputTokens":160,"outputTokens":40,"totalTokens":200}}}`)
	got, err = s.Kanban.ResolveCard(card.ID)
	if err != nil || got.TokenUsage.TotalTokens != 200 {
		t.Fatalf("replay: %+v %v", got.TokenUsage, err)
	}
}

func TestTokenUsageMetadataRefreshesDirectorySync(t *testing.T) {
	t.Parallel()
	s, p, b := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, Title: "Usage sync", Prompt: "Count"})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Conversations.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"start","messageId":"answer"}`)); err != nil {
		t.Fatal(err)
	}
	beforeChanges, beforeMetadata := testkit.ChangeCounters(t, s)
	if _, _, err := s.Conversations.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"message-metadata","messageMetadata":{"totalUsage":{"inputTokens":8,"outputTokens":2}}}`)); err != nil {
		t.Fatal(err)
	}
	// The metadata counter holds the sequence of the latest metadata change.
	if changes, metadata := testkit.ChangeCounters(t, s); changes != beforeChanges+1 || metadata != changes {
		t.Fatalf("usage must change metadata once: %d/%d -> %d/%d", beforeChanges, beforeMetadata, changes, metadata)
	}
	state, err := s.Kanban.GlobalState()
	if err != nil || len(state.Cards) != 1 || state.Cards[0].TokenUsage == nil || state.Cards[0].TokenUsage.TotalTokens != 10 {
		t.Fatalf("directory: %+v %v", state.Cards, err)
	}
}
