package store

import (
	"encoding/json"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func TestConversationTokenUsageTotalsAndPartialCoverage(t *testing.T) {
	msg := func(id, metadata string) model.UIMessage {
		return model.UIMessage{ID: id, Role: "assistant", Metadata: json.RawMessage(metadata)}
	}
	seed := msg("seed", `{"totalUsage":{"inputTokens":900,"outputTokens":100}}`)
	complete := msg("a", `{"usage":{"totalTokens":5},"totalUsage":{"inputTokens":100,"outputTokens":20,"totalTokens":120}}`)
	c := model.Conversation{ForkSeed: []model.UIMessage{seed}, Messages: []model.UIMessage{
		seed, complete, complete,
		msg("b", `{"totalUsage":{"inputTokens":30,"outputTokens":10}}`),
	}}
	got := conversationTokenUsage(c)
	if got.TotalTokens != 160 || got.InputTokens != 130 || got.OutputTokens != 30 || got.ReportedMessages != 2 || got.Partial {
		t.Fatalf("complete totals: %+v", got)
	}
	c.Messages = append(c.Messages, msg("c", `{"usage":{"inputTokens":7,"outputTokens":3}}`), msg("d", `{}`), msg("e", `{"totalUsage":{"totalTokens":15}}`))
	got = conversationTokenUsage(c)
	if got.TotalTokens != 185 || got.ReportedMessages != 4 || got.MissingMessages != 1 || !got.Partial {
		t.Fatalf("partial totals: %+v", got)
	}
	c.Messages = []model.UIMessage{msg("negative", `{"totalUsage":{"inputTokens":-1}}`), msg("invalid", `{"totalUsage":{"totalTokens":"bad"}}`)}
	got = conversationTokenUsage(c)
	if got.TotalTokens != 0 || got.MissingMessages != 2 || !got.Partial {
		t.Fatalf("invalid usage: %+v", got)
	}
}

func TestCardTokenUsageProjectsExistingHistoryAndRefreshesAfterRestart(t *testing.T) {
	s, p, b := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, Title: "Usage", Prompt: "Count"})
	if err != nil {
		t.Fatal(err)
	}
	appendChunk := func(raw string) {
		t.Helper()
		if _, _, err := s.AppendUIChunk(card.ID, "turn", json.RawMessage(raw)); err != nil {
			t.Fatal(err)
		}
	}
	appendChunk(`{"type":"start","messageId":"answer"}`)
	appendChunk(`{"type":"message-metadata","messageMetadata":{"totalUsage":{"inputTokens":80,"outputTokens":20,"totalTokens":100}}}`)
	for _, data := range []*Store{s, New(s.Root)} {
		got, err := data.ResolveCard(card.ID)
		if err != nil || got.TokenUsage == nil || got.TokenUsage.TotalTokens != 100 {
			t.Fatalf("projection: %+v %v", got.TokenUsage, err)
		}
	}
	appendChunk(`{"type":"message-metadata","messageMetadata":{"totalUsage":{"inputTokens":160,"outputTokens":40,"totalTokens":200}}}`)
	got, err := s.ResolveCard(card.ID)
	if err != nil || got.TokenUsage.TotalTokens != 200 || got.TokenUsage.ReportedMessages != 1 {
		t.Fatalf("refresh: %+v %v", got.TokenUsage, err)
	}
	// Replaying the same final metadata replaces the message's usage.
	appendChunk(`{"type":"finish","messageMetadata":{"totalUsage":{"inputTokens":160,"outputTokens":40,"totalTokens":200}}}`)
	got, err = s.ResolveCard(card.ID)
	if err != nil || got.TokenUsage.TotalTokens != 200 {
		t.Fatalf("replay: %+v %v", got.TokenUsage, err)
	}
}

func TestTokenUsageMetadataRefreshesDirectorySync(t *testing.T) {
	s, p, b := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, Title: "Usage sync", Prompt: "Count"})
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"start","messageId":"answer"}`)); err != nil {
		t.Fatal(err)
	}
	cursor, _, err := s.SyncEvents(0, 1)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"message-metadata","messageMetadata":{"totalUsage":{"inputTokens":8,"outputTokens":2}}}`)); err != nil {
		t.Fatal(err)
	}
	_, events, err := s.SyncEvents(cursor.Sequence, 10)
	if err != nil || len(events) != 1 || events[0].Kind != "store_changed" {
		t.Fatalf("usage invalidation: %+v %v", events, err)
	}
	state, err := s.GlobalState()
	if err != nil || len(state.Cards) != 1 || state.Cards[0].TokenUsage == nil || state.Cards[0].TokenUsage.TotalTokens != 10 {
		t.Fatalf("directory: %+v %v", state.Cards, err)
	}
}
