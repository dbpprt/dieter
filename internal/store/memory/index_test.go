package memory

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/kv"
)

func text(id, role, value string) model.UIMessage {
	return model.UIMessage{ID: id, Role: role, Parts: []model.UIMessagePart{{Type: "text", Text: value}}}
}

func tool(name, state string, input, output any) model.UIMessagePart {
	in, _ := json.Marshal(input)
	out, _ := json.Marshal(output)
	part := model.UIMessagePart{Type: "dynamic-tool", ToolName: name, State: state, Input: in}
	if state == "output-error" {
		part.ErrorText = output.(string)
	} else {
		part.Output = out
	}
	return part
}

func scrollConversation() []model.UIMessage {
	return []model.UIMessage{
		text("m1", "user", "The Mac transcript jumps when new chunks stream in"),
		{ID: "m2", Role: "assistant", Parts: []model.UIMessagePart{
			{Type: "reasoning", Text: "zebrafish-only-in-reasoning"},
			tool("Read", "output-available", map[string]string{"file_path": "apps/apple/mac/TranscriptScrollController.swift"}, "final class TranscriptScrollController {}"),
			tool("Bash", "output-error", map[string]string{"command": "just mac test_unit"}, "DieterMac is running; Mac flows refuse to run"),
			tool("mcp__harness-tools__memory_recall", "output-available", map[string]string{"query": "x"}, "recalled-text-must-not-index"),
			tool("Bash", "output-available", map[string]string{"command": "env"}, "ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz"),
			{Type: "text", Text: "Scroll position is now owned by a native NSScrollView controller."},
		}},
	}
}

func TestIndexSearchAndSafety(t *testing.T) {
	index := New(t.TempDir())
	defer index.Close()
	if index.Exists() {
		t.Fatal("index exists before first use")
	}
	card := Card{ID: "c_scroll", Project: "p_one", Title: "Transcript scroll", Lane: "done", Harness: "codex", Scope: "board", Brief: "Fix scroll jumps"}
	result, err := index.IndexCard(card, scrollConversation())
	if err != nil {
		t.Fatal(err)
	}
	if !result.Full || result.Added != 5 {
		t.Fatalf("result = %+v, want full with 5 observations (prompt, read, error, env, answer)", result)
	}
	other := Card{ID: "c_other", Project: "p_one", Title: "Gateway deploy", Lane: "done", Harness: "claude-code", Scope: "board"}
	if _, err = index.IndexCard(other, []model.UIMessage{text("o1", "user", "Deploy the gateway from the main repository"), text("o2", "assistant", "Added a deploy recipe.")}); err != nil {
		t.Fatal(err)
	}
	hits, err := index.Search(Query{Project: "p_one", Text: "transcript scrolling jumps while streaming"})
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) == 0 || hits[0].CardID != "c_scroll" {
		t.Fatalf("hits = %+v, want c_scroll first", hits)
	}
	if !strings.Contains(hits[0].FinalAnswer, "NSScrollView") || len(hits[0].Snippets) == 0 {
		t.Fatalf("hit = %+v, want final answer and snippets", hits[0])
	}
	for query, want := range map[string]int{
		"zebrafish":                    0, // reasoning is never indexed
		"recalled-text-must-not-index": 0, // memory tool output is never indexed
		"abcdefghijklmnopqrstuvwxyz":   0, // credentials are scrubbed
	} {
		found, err := index.Search(Query{Project: "p_one", Text: query})
		if err != nil {
			t.Fatal(err)
		}
		if len(found) != want {
			t.Fatalf("query %q: %d hits, want %d: %+v", query, len(found), want, found)
		}
	}
	if found, _ := index.Search(Query{Project: "p_two", Text: "transcript scroll"}); len(found) != 0 {
		t.Fatalf("another project's search found %+v", found)
	}
	if found, _ := index.Search(Query{Project: "p_one", Text: "controller", Files: []string{"TranscriptScrollController.swift"}}); len(found) != 1 || found[0].CardID != "c_scroll" {
		t.Fatalf("file-filtered search = %+v", found)
	}
	// Incremental: a second turn adds only its own observations.
	messages := append(scrollConversation(), text("m3", "user", "Also check the iOS keyboard"), text("m4", "assistant", "The keyboard inset is handled."))
	result, err = index.IndexCard(card, messages)
	if err != nil {
		t.Fatal(err)
	}
	if result.Full || result.Added != 6 {
		t.Fatalf("incremental result = %+v, want 6 (the last message's four again, prompt, answer)", result)
	}
	stats, err := index.Stats("p_one")
	if err != nil || stats.Cards != 2 || stats.Observations != 9 {
		t.Fatalf("stats = %+v, %v; want 2 cards, 9 observations", stats, err)
	}
	// Indexing twice is idempotent.
	if result, err = index.IndexCard(card, messages); err != nil || result.Added != 1 {
		t.Fatalf("reindex = %+v, %v", result, err)
	}
	if stats, _ = index.Stats("p_one"); stats.Observations != 9 {
		t.Fatalf("observations after reindex = %d, want 9", stats.Observations)
	}
	if err = index.ForgetCard("c_scroll"); err != nil {
		t.Fatal(err)
	}
	if found, _ := index.Search(Query{Project: "p_one", Text: "transcript scroll"}); len(found) != 0 {
		t.Fatalf("forgotten conversation still found: %+v", found)
	}
}

func TestSavedMemoryMirror(t *testing.T) {
	index := New(t.TempDir())
	defer index.Close()
	memories := []kv.SavedMemory{
		{ID: "mem_a", Revision: "r1", Record: schema.MemoryRecord{Project: "p", Kind: "lesson", Content: "Mac E2E flows refuse to run while DieterMac runs", Status: "active"}},
		{ID: "mem_b", Revision: "r1", Record: schema.MemoryRecord{Project: "p", Kind: "fact", Content: "The gateway deploys from the vps repository", Status: "retired"}},
		{ID: "mem_c", Revision: "r1", Record: schema.MemoryRecord{Project: "p", Kind: "decision", Content: "Gateway deploys from the main repository", Status: "active", ExpiresAt: "2000-01-01T00:00:00Z"}},
	}
	if err := index.SyncMemories("p", memories, "2026-11-27T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	ids, err := index.SearchMemories("p", "mac flows refuse", nil, 5)
	if err != nil || len(ids) != 1 || ids[0] != "mem_a" {
		t.Fatalf("ids = %v, %v", ids, err)
	}
	if ids, _ = index.SearchMemories("p", "gateway deploys", nil, 5); len(ids) != 0 {
		t.Fatalf("retired or expired memories found: %v", ids)
	}
	memories[0].Record.Status, memories[0].Revision = "superseded", "r2"
	memories[0].Record.SupersededBy = "mem_d"
	memories = append(memories, kv.SavedMemory{ID: "mem_d", Revision: "r1", Record: schema.MemoryRecord{Project: "p", Kind: "lesson", Content: "Mac E2E flows refuse to run while any DieterMac process runs; quit it first", Status: "active"}})
	if err = index.SyncMemories("p", memories, "2026-11-27T00:00:00Z"); err != nil {
		t.Fatal(err)
	}
	if ids, _ = index.SearchMemories("p", "mac flows refuse", nil, 5); len(ids) != 1 || ids[0] != "mem_d" {
		t.Fatalf("after supersede ids = %v", ids)
	}
	if ids, _ = index.SearchMemories("p", "mac flows refuse", []string{"fact"}, 5); len(ids) != 0 {
		t.Fatalf("kind filter ids = %v", ids)
	}
}
