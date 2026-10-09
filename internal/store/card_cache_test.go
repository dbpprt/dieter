package store

import (
	"encoding/json"
	"os"
	"reflect"
	"sync"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func TestUpdateCardCacheNoopDoesNotPublishMutation(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowReview)
	card, err := s.CreateChat(CreateCardInput{Project: project.ID, Title: "cache"})
	if err != nil {
		t.Fatal(err)
	}
	key, effort := "account", "high"
	input := CardCacheInput{Provider: "mock", Model: "mock", Runtime: "running", ProviderAccountKey: &key, Effort: &effort, ProviderOptions: map[string]string{"mode": "fast"}}
	card, err = s.UpdateCardCache(card.ID, input)
	if err != nil {
		t.Fatal(err)
	}
	beforeChanges, beforeMetadata := changeCounters(t, s)
	files := map[string][]byte{}
	for _, path := range []string{s.syncMetadataPath(), s.syncHighwaterPath()} {
		files[path], err = os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
	}
	for range 10 {
		got, err := s.UpdateCardCache(card.ID, input)
		if err != nil || !reflect.DeepEqual(got, card) {
			t.Fatalf("unchanged cache: card=%+v err=%v", got, err)
		}
	}
	if changes, metadata := changeCounters(t, s); changes != beforeChanges || metadata != beforeMetadata || s.SyncMutationPending() {
		t.Fatalf("no-op recorded a change: before=%d/%d after=%d/%d", beforeChanges, beforeMetadata, changes, metadata)
	}
	for path, want := range files {
		got, err := os.ReadFile(path)
		if err != nil || string(got) != string(want) {
			t.Fatalf("no-op rewrote %s: %v", path, err)
		}
	}
	// Omitted options preserve them, while explicit empty options and account
	// selection clear them. A real transition must still publish exactly once.
	if got, err := s.UpdateCardCache(card.ID, CardCacheInput{}); err != nil || !reflect.DeepEqual(got, card) {
		t.Fatalf("omitted fields changed cache: %+v %v", got, err)
	}
	empty := ""
	changed, err := s.UpdateCardCache(card.ID, CardCacheInput{Title: "renamed", Runtime: "idle", ProviderAccountKey: &empty, ProviderOptions: map[string]string{}})
	if err != nil || changed.TitleRevision != card.TitleRevision+1 || changed.Runtime != "idle" || changed.ProviderAccountKey != "" || len(changed.ProviderOptions) != 0 {
		t.Fatalf("real change lost: %+v %v", changed, err)
	}
	if changes, metadata := changeCounters(t, s); changes != beforeChanges+1 || metadata != changes {
		t.Fatalf("real change recorded %d/%d, want %d/%d", changes, metadata, beforeChanges+1, beforeChanges+1)
	}
}

func TestUpdateCardCacheNoopRecoversPendingMutation(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowReview)
	card, err := s.CreateChat(CreateCardInput{Project: project.ID, Title: "before"})
	if err != nil {
		t.Fatal(err)
	}
	release, err := s.beginWriteLock()
	if err != nil {
		t.Fatal(err)
	}
	pending, err := s.prepareSyncMutation(metadataChange)
	if err == nil {
		card.Title = "recovered"
		err = s.writeCard(card)
	}
	release() // simulate a writer that lost its sync publication
	if err != nil {
		t.Fatal(err)
	}
	got, err := s.UpdateCardCache(card.ID, CardCacheInput{Title: card.Title})
	if err != nil || got.Title != card.Title || s.SyncMutationPending() {
		t.Fatalf("no-op skipped recovery: %+v %v", got, err)
	}
	if changes, _ := changeCounters(t, s); changes != pending.Sequence {
		t.Fatalf("recovery added an empty transaction: changes=%d want %d", changes, pending.Sequence)
	}
}

func TestUpdateCardCacheConcurrentInstancesPreserveIndependentChanges(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowReview)
	card, err := s.CreateChat(CreateCardInput{Project: project.ID, Title: "before"})
	if err != nil {
		t.Fatal(err)
	}
	other := New(s.Root)
	defer other.Close()
	var wg sync.WaitGroup
	for i, input := range []CardCacheInput{{Title: "after"}, {Runtime: "running"}, {Summary: "kept"}, {Model: "model"}} {
		writer := []*Store{s, other}[i%2]
		wg.Go(func() {
			for range 5 {
				if _, err := writer.UpdateCardCache(card.ID, input); err != nil {
					t.Error(err)
				}
			}
		})
	}
	wg.Wait()
	got, err := s.ResolveCard(card.ID)
	if err != nil || got.Title != "after" || got.Runtime != "running" || got.Summary != "kept" || got.Model != "model" {
		raw, _ := json.Marshal(got)
		t.Fatalf("concurrent changes lost: %s %v", raw, err)
	}
}
