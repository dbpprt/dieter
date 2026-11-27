package memory

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

// TestRecallEval is eval E1: paraphrased questions against a fixed corpus of
// one project's conversations (tests/fixtures/memory/recall.json). It guards
// the ranking (BM25 weights, prefix terms, synonyms, identifier terms,
// digests) against regressions: hit@3 must stay at or above 0.9.
func TestRecallEval(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "tests", "fixtures", "memory", "recall.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Conversations []struct {
			ID, Title, Prompt, Tool, Answer string
			Files                           []string
		}
		Queries []struct{ Query, Answer string }
	}
	if err = json.Unmarshal(raw, &fixture); err != nil {
		t.Fatal(err)
	}
	index := New(t.TempDir())
	defer index.Close()
	for _, conversation := range fixture.Conversations {
		var input any = map[string]string{"command": "go test ./..."}
		if len(conversation.Files) > 0 {
			input = map[string]string{"file_path": conversation.Files[0]}
		}
		messages := []model.UIMessage{
			text(conversation.ID+"_u", "user", conversation.Prompt),
			{ID: conversation.ID + "_a", Role: "assistant", Parts: []model.UIMessagePart{
				tool("Read", "output-available", input, conversation.Tool),
				{Type: "text", Text: conversation.Answer},
			}},
		}
		card := Card{ID: conversation.ID, Project: "p_eval", Title: conversation.Title, Lane: "done", Harness: "claude-code", Scope: "board", Brief: conversation.Prompt}
		if _, err = index.IndexCard(card, messages); err != nil {
			t.Fatal(err)
		}
	}
	hit1, hit3, reciprocal := 0, 0, 0.0
	for _, query := range fixture.Queries {
		hits, err := index.Search(Query{Project: "p_eval", Text: query.Query, Limit: 10})
		if err != nil {
			t.Fatal(err)
		}
		rank := 0
		for index, hit := range hits {
			if hit.CardID == query.Answer {
				rank = index + 1
				break
			}
		}
		switch {
		case rank == 1:
			hit1++
			hit3++
		case rank > 0 && rank <= 3:
			hit3++
		}
		if rank > 0 {
			reciprocal += 1 / float64(rank)
		}
		if rank != 1 {
			top := ""
			if len(hits) > 0 {
				top = hits[0].CardID
			}
			t.Logf("%q: %s at rank %d (top %s)", query.Query, query.Answer, rank, top)
		}
	}
	total := float64(len(fixture.Queries))
	t.Logf("recall eval: %d queries, hit@1 %.2f, hit@3 %.2f, MRR %.3f", len(fixture.Queries), float64(hit1)/total, float64(hit3)/total, reciprocal/total)
	if float64(hit3)/total < 0.9 {
		t.Fatalf("hit@3 %.2f is below 0.9", float64(hit3)/total)
	}
}
