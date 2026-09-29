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
	before, _, err := s.SyncEvents(0, 256)
	if err != nil {
		t.Fatal(err)
	}
	files := map[string][]byte{}
	for _, path := range []string{s.syncMetadataPath(), s.syncHighwaterPath(), s.syncEventsPath()} {
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
	after, events, err := s.SyncEvents(before.Sequence, 256)
	if err != nil || after != before || len(events) != 0 || s.SyncMutationPending() {
		t.Fatalf("no-op published a mutation: before=%+v after=%+v events=%+v err=%v", before, after, events, err)
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
	after, events, err = s.SyncEvents(before.Sequence, 256)
	if err != nil || after.Sequence != before.Sequence+1 || len(events) != 1 || events[0].Kind != "store_changed" {
		t.Fatalf("real mutation publication: %+v %+v %v", after, events, err)
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
	event, err := s.prepareSyncMutation()
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
	cursor, _, err := s.SyncEvents(0, 256)
	if err != nil || cursor.Sequence != event.Sequence {
		t.Fatalf("recovery added an empty transaction: %+v %v", cursor, err)
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
