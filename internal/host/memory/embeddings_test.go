package memory

import (
	"context"
	"testing"

	storememory "github.com/dbpprt/dieter/internal/store/memory"
)

// TestSemanticRecallFindsParaphrasesAndBackfills: recall finds a
// conversation and a saved memory by meaning when the question shares no
// words with them, and conversations indexed without vectors (before
// embeddings, or by another model) are embedded again by reconciliation.
func TestSemanticRecallFindsParaphrasesAndBackfills(t *testing.T) {
	t.Parallel()
	data, project := memoryStore(t, "dm_alpha")
	service := newService(t, data, nil, "alpha")
	auth := storeCard(t, data, project, "Claude turns fail", true)
	seedTurn(t, data, auth.ID, "Claude turns fail with HTTP 401 roughly every eight hours", "internal/harness/runtime/claude-resilience.mjs",
		"Two processes refreshed the same OAuth token at once; Claude Code must be the only refresher, and the runner now resumes the session once after a 401.")
	scroll := storeCard(t, data, project, "Transcript jumps", true)
	seedTurn(t, data, scroll.ID, "The Mac transcript jumps to the top while chunks stream in", "apps/apple/mac/TranscriptScrollController.swift",
		"Scroll position is now owned by a native NSScrollView controller instead of SwiftUI.")
	for _, card := range []string{auth.ID, scroll.ID} {
		if err := service.IndexNow(card); err != nil {
			t.Fatal(err)
		}
	}
	question := "the assistant keeps getting logged out and rejected"
	keyword, err := service.Index().Search(storememory.Query{Project: project.ID, Text: question})
	if err != nil {
		t.Fatal(err)
	}
	for _, hit := range keyword {
		if hit.CardID == auth.ID {
			t.Fatalf("the question must not match by keywords: %+v", keyword)
		}
	}
	recall := func() SearchResult {
		t.Helper()
		result, err := service.Search(context.Background(), SearchInput{Project: project.ID, Query: question, LocalOnly: true})
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	if result := recall(); len(result.Hits) == 0 || result.Hits[0].CardID != auth.ID || len(result.Hits[0].Snippets) == 0 {
		t.Fatalf("semantic recall = %+v", result.Hits)
	}

	// Vectors from another model are discarded when the index opens; the
	// conversations are then reindexed and embedded again.
	if err = service.Index().SetMeta("vector_model", "another-model"); err != nil {
		t.Fatal(err)
	}
	if err = service.Index().Close(); err != nil {
		t.Fatal(err)
	}
	if embedded, _ := service.Index().CardsWithVectors(project.ID); len(embedded) != 0 {
		t.Fatalf("vectors of another model survived: %v", embedded)
	}
	service.reconcile()
	for {
		select {
		case id := <-service.queue:
			service.mu.Lock()
			delete(service.pending, id)
			service.mu.Unlock()
			if err := service.IndexNow(id); err != nil {
				t.Fatal(err)
			}
			continue
		default:
		}
		break
	}
	if embedded, _ := service.Index().CardsWithVectors(project.ID); !embedded[auth.ID] || !embedded[scroll.ID] {
		t.Fatalf("reconcile did not embed the conversations again: %v", embedded)
	}
	if result := recall(); len(result.Hits) == 0 || result.Hits[0].CardID != auth.ID {
		t.Fatalf("semantic recall after the backfill = %+v", result.Hits)
	}

	saved, err := service.Save(SaveInput{Project: project.ID, Kind: "lesson", Content: "Release builds must be signed with the Developer ID certificate in CI, never on a laptop."})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = service.Save(SaveInput{Project: project.ID, Kind: "fact", Content: "The warm Android emulator is borrowed by device flows."}); err != nil {
		t.Fatal(err)
	}
	result, err := service.Search(context.Background(), SearchInput{Project: project.ID, Query: "who may notarize the shipped app", LocalOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Memories) == 0 || result.Memories[0].ID != saved.Memory.ID {
		t.Fatalf("semantic memory recall = %+v", result.Memories)
	}
}
