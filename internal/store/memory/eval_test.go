package memory

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/dbpprt/dieter/internal/memory/embed"
	"github.com/dbpprt/dieter/internal/model"
)

// TestRecallEval is eval E1: paraphrased questions against a fixed corpus of
// one project's conversations (tests/fixtures/memory/recall.json). It guards
// the ranking (BM25 weights, prefix terms, synonyms, identifier terms,
// digests, and their fusion with embeddings) against regressions: keyword
// recall must keep hit@3 at or above 0.9, hybrid recall hit@1 at or above
// 0.85 and hit@3 at or above 0.95.
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
	encoder, err := embed.Load()
	if err != nil {
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
		result, err := index.IndexCard(card, messages, false)
		if err != nil {
			t.Fatal(err)
		}
		vectors := make([][]float32, len(result.Texts))
		for i, text := range result.Texts {
			vectors[i] = encoder.Embed(text.Body)
		}
		if err = index.PutVectors(card.ID, card.Project, result.Texts, vectors); err != nil {
			t.Fatal(err)
		}
	}
	for _, mode := range []struct {
		name       string
		vectors    bool
		hit1, hit3 float64
	}{{"keyword", false, 0, 0.9}, {"hybrid", true, 0.85, 0.95}} {
		hit1, hit3, reciprocal := 0, 0, 0.0
		for _, query := range fixture.Queries {
			search := Query{Project: "p_eval", Text: query.Query, Limit: 10}
			if mode.vectors {
				search.Vector = encoder.Embed(query.Query)
			}
			hits, err := index.Search(search)
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
				t.Logf("%s %q: %s at rank %d (top %s)", mode.name, query.Query, query.Answer, rank, top)
			}
		}
		total := float64(len(fixture.Queries))
		t.Logf("%s recall eval: %d queries, hit@1 %.2f, hit@3 %.2f, MRR %.3f", mode.name, len(fixture.Queries), float64(hit1)/total, float64(hit3)/total, reciprocal/total)
		if float64(hit1)/total < mode.hit1 || float64(hit3)/total < mode.hit3 {
			t.Errorf("%s: hit@1 %.2f, hit@3 %.2f; want at least %.2f and %.2f", mode.name, float64(hit1)/total, float64(hit3)/total, mode.hit1, mode.hit3)
		}
	}
}
