package conversations

import (
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/home"
)

func TestConversationStatusSummaryCacheIsBounded(t *testing.T) {
	t.Parallel()
	s := New(home.New(t.TempDir()), nil, nil, nil)
	for i := range maxConversationStatuses + 1 {
		s.rememberConversationStatus(fmt.Sprint(i), "idle", nil, nil)
	}
	if len(s.statuses.entries) != maxConversationStatuses {
		t.Fatalf("status entries: %d", len(s.statuses.entries))
	}
	if _, found := s.statuses.entries["0"]; found {
		t.Fatal("oldest status was not evicted")
	}
}

func TestConversationActivityCoalescesOnlyTokens(t *testing.T) {
	t.Parallel()
	at := time.Now().UTC()
	for _, kind := range []string{"text-delta", "reasoning-delta", "tool-input-delta", "finish", "abort", "error", "message-metadata", "tool-input-start"} {
		data, _ := json.Marshal(map[string]string{"type": kind})
		event := model.ConversationEvent{Type: "ui-chunk", CreatedAt: at.Format(time.RFC3339Nano), Data: data}
		tokens := kind == "text-delta" || kind == "reasoning-delta" || kind == "tool-input-delta"
		if shouldPublishConversationActivity(at.Add(-time.Millisecond).Format(time.RFC3339Nano), event) == tokens {
			t.Errorf("wrong publication policy for %s", kind)
		}
		if !shouldPublishConversationActivity(at.Add(-streamedActivityInterval).Format(time.RFC3339Nano), event) {
			t.Errorf("activity must advance at bounded intervals: %s", kind)
		}
	}
}

func TestConversationTokenUsageTotalsAndPartialCoverage(t *testing.T) {
	t.Parallel()
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
