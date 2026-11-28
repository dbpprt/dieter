package memory

import (
	"testing"

	"github.com/dbpprt/dieter/internal/memory/embed"
)

func unit(i int) []float32 {
	v := make([]float32, embed.Dim)
	v[i] = 1
	return v
}

// TestVectorsFollowTheIndex: texts to embed come from indexing, stored
// vectors answer queries without shared words, changed or reindexed
// messages are embedded again, file filters and weak matches stay keyword
// only, and forgetting removes the vectors.
func TestVectorsFollowTheIndex(t *testing.T) {
	index := New(t.TempDir())
	defer index.Close()
	card := Card{ID: "c_scroll", Project: "p", Title: "Transcript jumps", Lane: "done", Harness: "claude-code", Scope: "board", Brief: "jumps"}
	messages := scrollConversation()
	result, err := index.IndexCard(card, messages, false)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Texts) != 3 || result.Texts[0].Message != "" || result.Texts[1].Message != "m1" || result.Texts[2].Message != "m2" {
		t.Fatalf("texts = %+v", result.Texts)
	}
	missing, err := index.MissingVectors(card.ID, result.Texts)
	if err != nil || len(missing) != 3 {
		t.Fatalf("missing = %+v, %v", missing, err)
	}
	if err = index.PutVectors(card.ID, card.Project, missing, [][]float32{unit(0), unit(1), unit(2)}); err != nil {
		t.Fatal(err)
	}
	if missing, _ = index.MissingVectors(card.ID, result.Texts); len(missing) != 0 {
		t.Fatalf("stored texts still missing: %+v", missing)
	}

	hits, err := index.Search(Query{Project: "p", Text: "qqqq zzzz", Vector: unit(2)})
	if err != nil || len(hits) != 1 || hits[0].CardID != card.ID || hits[0].MessageID != "m2" || len(hits[0].Snippets) != 1 {
		t.Fatalf("vector-only search = %+v, %v", hits, err)
	}
	if hits, _ = index.Search(Query{Project: "p", Text: "qqqq zzzz", Vector: unit(2), Files: []string{"TranscriptScrollController.swift"}}); len(hits) != 0 {
		t.Fatalf("a file filter must keep recall to keywords: %+v", hits)
	}
	if hits, _ = index.Search(Query{Project: "p", Text: "qqqq zzzz", Vector: unit(9)}); len(hits) != 0 {
		t.Fatalf("a weak match must not be recalled: %+v", hits)
	}
	if hits, _ = index.Search(Query{Project: "p", Text: "transcript", Vector: unit(9)}); len(hits) != 1 {
		t.Fatalf("keyword hits survive a weak vector: %+v", hits)
	}

	// The last message is reindexed incrementally: its vectors go, the
	// title's stay.
	messages = append(messages, text("m3", "user", "Also keep the position when the window resizes"))
	if result, err = index.IndexCard(card, messages, false); err != nil || result.Full {
		t.Fatalf("incremental index = %+v, %v", result, err)
	}
	missing, _ = index.MissingVectors(card.ID, result.Texts)
	if len(missing) != 2 || missing[0].Message != "m2" || missing[1].Message != "m3" {
		t.Fatalf("missing after an incremental index = %+v", missing)
	}
	card.Title = "Transcript jumps while streaming"
	if result, err = index.IndexCard(card, messages, false); err != nil {
		t.Fatal(err)
	}
	if missing, _ = index.MissingVectors(card.ID, result.Texts[:1]); len(missing) != 1 {
		t.Fatalf("a renamed title must be embedded again: %+v", missing)
	}

	if err = index.ForgetCard(card.ID); err != nil {
		t.Fatal(err)
	}
	if embedded, _ := index.CardsWithVectors("p"); len(embedded) != 0 {
		t.Fatalf("forget kept vectors: %v", embedded)
	}
	if err = index.PutVectors(card.ID, card.Project, result.Texts[:1], [][]float32{unit(0)}); err != nil {
		t.Fatal(err)
	}
	if embedded, _ := index.CardsWithVectors("p"); len(embedded) != 0 {
		t.Fatalf("vectors of a forgotten conversation were stored: %v", embedded)
	}
	if hits, _ = index.Search(Query{Project: "p", Text: "qqqq", Vector: unit(0)}); len(hits) != 0 {
		t.Fatalf("a forgotten conversation was recalled: %+v", hits)
	}
}
