package leases_test

import (
	"errors"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/leases"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestRuntimeLeaseAllowsParallelProjectTurnsButSerializesCards(t *testing.T) {
	t.Parallel()
	s, project, _ := testkit.BoardStore(t, model.WorkflowReview)
	lease, err := s.Kanban.AcquireRuntimeLease(project.ID, "card_one")
	if err != nil {
		t.Fatal(err)
	}
	next, err := store.New(s.Root).Kanban.AcquireRuntimeLease(project.ID, "card_two")
	if err != nil {
		t.Fatalf("parallel turn in same project: %v", err)
	}
	if _, err := store.New(s.Root).Kanban.AcquireRuntimeLease(project.ID, "card_one"); !errors.Is(err, leases.ErrCardActive) {
		t.Fatalf("same card lease error = %v, want ErrCardActive", err)
	}
	if err := s.Leases.Release(lease); err != nil {
		t.Fatal(err)
	}
	if err := s.Leases.Release(next); err != nil {
		t.Fatal(err)
	}
}

func TestRuntimeLeaseLookupPreservesTokenMatchedRelease(t *testing.T) {
	t.Parallel()
	s, project, _ := testkit.BoardStore(t, model.WorkflowReview)
	first, err := s.Kanban.AcquireRuntimeLease(project.ID, "card_lookup")
	if err != nil {
		t.Fatal(err)
	}
	lookedUp, ok, err := store.New(s.Root).Leases.ForCard("card_lookup")
	if err != nil || !ok || lookedUp.Token != first.Token {
		t.Fatalf("lookup=%#v ok=%v err=%v", lookedUp, ok, err)
	}
	if err := s.Leases.Release(first); err != nil {
		t.Fatal(err)
	}
	replacement, err := s.Kanban.AcquireRuntimeLease(project.ID, "card_lookup")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.Leases.Release(replacement) }()
	if err := s.Leases.Release(first); err != nil {
		t.Fatal(err)
	}
	if active, err := s.Leases.CardActive("card_lookup"); err != nil || !active {
		t.Fatalf("stale token removed replacement: active=%v err=%v", active, err)
	}
}
