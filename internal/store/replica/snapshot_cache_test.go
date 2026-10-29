package replica_test

import (
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/replica"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestSnapshotCacheReusesCardDependenciesAtExactlyOneRevision(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Title: "before warming"})
	if err != nil {
		t.Fatal(err)
	}
	other := store.New(s.Root)
	defer other.Close()
	// Creation reads its post-write projection. Advance the replica through a
	// different instance so the first measured read is genuinely cold.
	if _, err := other.Kanban.RenameCard(card.ID, "original"); err != nil {
		t.Fatal(err)
	}
	projectCard := func() (model.Card, int) {
		t.Helper()
		_, view, err := s.Replica.Snapshot()
		if err != nil {
			t.Fatal(err)
		}
		defer view.Close()
		got, ok, err := kanban.SharedCard(view, card.ID, model.Card{})
		if err != nil || !ok {
			t.Fatalf("projection: %v %v", ok, err)
		}
		return got, view.ViewQueries()
	}
	_, cold := projectCard()
	warm, queries := projectCard()
	if cold <= queries || queries != 1 {
		t.Fatalf("dependency queries cold=%d warm=%d, want only label membership range on warm read", cold, queries)
	}
	t.Logf("card dependency queries cold=%d warm=%d", cold, queries)
	// The returned causal baseline and nested clocks must not alias the cache.
	warm.SharedBase["title"][0] = '!'
	for _, field := range warm.StateFields {
		for _, v := range field.Versions {
			for actor := range v.Clock {
				v.Clock[actor] = 999
			}
		}
	}
	got, _ := projectCard()
	if got.Title != "original" {
		t.Fatal("caller mutated cached projection")
	}
	if _, err := other.Kanban.RenameCard(card.ID, "renamed elsewhere"); err != nil {
		t.Fatal(err)
	}
	got, queries = projectCard()
	if got.Title != "renamed elsewhere" || queries <= 1 {
		t.Fatalf("cache hid cross-process revision: title=%s queries=%d", got.Title, queries)
	}
	_, queries = projectCard()
	if queries != 1 {
		t.Fatalf("new revision not cached: %d", queries)
	}
	// Appending a conversation must preserve another writer's shared fields.
	if _, _, err := s.Conversations.AppendUIChunk(card.ID, "turn", []byte(`{"type":"start","messageId":"assistant"}`)); err != nil {
		t.Fatal(err)
	}
	got, err = s.Kanban.ResolveCard(card.ID)
	if err != nil || got.Title != "renamed elsewhere" {
		t.Fatalf("append reverted shared title: %s %v", got.Title, err)
	}
}

func TestSnapshotCacheIncludesAbsenceAndInvalidatesAfterAnotherWriter(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	defer s.Close()
	id, err := s.Replica.BindPeerAccount("cache", "github:1", "owner", "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	read := func() (bool, int) {
		t.Helper()
		v, err := s.Replica.OpenPeerSnapshot(id.Account)
		if err != nil {
			t.Fatal(err)
		}
		defer v.Close()
		r := v.Record("kv.test/absent")
		if v.Err() != nil {
			t.Fatal(v.Err())
		}
		return len(r.Versions) > 0, v.ViewQueries()
	}
	if exists, q := read(); exists || q != 1 {
		t.Fatalf("cold absence %v %d", exists, q)
	}
	if exists, q := read(); exists || q != 0 {
		t.Fatalf("warm absence %v %d", exists, q)
	}
	other := store.New(s.Root)
	defer other.Close()
	if _, err := other.Replica.PutPeerRecord(id, "kv.test", "absent", "", replica.RawValue(true), false); err != nil {
		t.Fatal(err)
	}
	if exists, q := read(); !exists || q != 1 {
		t.Fatalf("cached absence hid new record %v %d", exists, q)
	}
}
