package kanban_test

import (
	"encoding/json"
	"os"
	"reflect"
	"sync"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestUpdateCardCacheNoopDoesNotPublishMutation(t *testing.T) {
	t.Parallel()
	s, project, _ := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "cache"})
	if err != nil {
		t.Fatal(err)
	}
	key, effort := "account", "high"
	input := kanban.CardCacheInput{Provider: "mock", Model: "mock", Runtime: "running", ProviderAccountKey: &key, Effort: &effort, ProviderOptions: map[string]string{"mode": "fast"}}
	card, err = s.Kanban.UpdateCardCache(card.ID, input)
	if err != nil {
		t.Fatal(err)
	}
	beforeChanges, beforeMetadata := testkit.ChangeCounters(t, s)
	files := map[string][]byte{}
	for _, path := range []string{s.SyncMetadataPath(), s.SyncHighwaterPath()} {
		files[path], err = os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
	}
	for range 10 {
		got, err := s.Kanban.UpdateCardCache(card.ID, input)
		if err != nil || !reflect.DeepEqual(got, card) {
			t.Fatalf("unchanged cache: card=%+v err=%v", got, err)
		}
	}
	if changes, metadata := testkit.ChangeCounters(t, s); changes != beforeChanges || metadata != beforeMetadata || s.SyncMutationPending() {
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
	if got, err := s.Kanban.UpdateCardCache(card.ID, kanban.CardCacheInput{}); err != nil || !reflect.DeepEqual(got, card) {
		t.Fatalf("omitted fields changed cache: %+v %v", got, err)
	}
	empty := ""
	changed, err := s.Kanban.UpdateCardCache(card.ID, kanban.CardCacheInput{Title: "renamed", Runtime: "idle", ProviderAccountKey: &empty, ProviderOptions: map[string]string{}})
	if err != nil || changed.TitleRevision != card.TitleRevision+1 || changed.Runtime != "idle" || changed.ProviderAccountKey != "" || len(changed.ProviderOptions) != 0 {
		t.Fatalf("real change lost: %+v %v", changed, err)
	}
	if changes, metadata := testkit.ChangeCounters(t, s); changes != beforeChanges+1 || metadata != changes {
		t.Fatalf("real change recorded %d/%d, want %d/%d", changes, metadata, beforeChanges+1, beforeChanges+1)
	}
}

func TestUpdateCardCacheConcurrentInstancesPreserveIndependentChanges(t *testing.T) {
	t.Parallel()
	s, project, _ := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "before"})
	if err != nil {
		t.Fatal(err)
	}
	other := store.New(s.Root)
	defer other.Close()
	var wg sync.WaitGroup
	for i, input := range []kanban.CardCacheInput{{Title: "after"}, {Runtime: "running"}, {Summary: "kept"}, {Model: "model"}} {
		writer := []*store.Store{s, other}[i%2]
		wg.Go(func() {
			for range 5 {
				if _, err := writer.Kanban.UpdateCardCache(card.ID, input); err != nil {
					t.Error(err)
				}
			}
		})
	}
	wg.Wait()
	got, err := s.Kanban.ResolveCard(card.ID)
	if err != nil || got.Title != "after" || got.Runtime != "running" || got.Summary != "kept" || got.Model != "model" {
		raw, _ := json.Marshal(got)
		t.Fatalf("concurrent changes lost: %s %v", raw, err)
	}
}
