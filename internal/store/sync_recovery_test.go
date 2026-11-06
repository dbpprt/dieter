package store_test

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestGlobalStateNeverCachesPreparedDomainMutation(t *testing.T) {
	t.Parallel()
	s, p, b := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, Title: "before"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.GlobalState(); err != nil {
		t.Fatal(err)
	}
	release, err := s.BeginWrite()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	_, err = s.Kanban.GlobalStateContext(ctx)
	if !errors.Is(err, context.DeadlineExceeded) {
		release()
		t.Fatalf("active writer read: %v", err)
	}
	card.Title = "after"
	err = s.Kanban.WriteCard(card)
	release()
	if err != nil {
		t.Fatal(err)
	}
	state, err := s.Kanban.GlobalState()
	if err != nil || state.Cards[0].Title != "after" {
		t.Fatalf("stale state: %+v %v", state, err)
	}
}

func TestPendingMutationRecoveredByReader(t *testing.T) {
	t.Parallel()
	s, p, b := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, Title: "before"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.GlobalState(); err != nil {
		t.Fatal(err)
	}
	release, err := s.BeginWriteLock()
	if err != nil {
		t.Fatal(err)
	}
	pending, err := s.PrepareMutation(home.ConversationChange)
	if err != nil {
		release()
		t.Fatal(err)
	}
	card.Title = "partial crash write"
	err = s.Kanban.WriteCard(card)
	release()
	if err != nil {
		t.Fatal(err)
	}
	state, err := s.Kanban.GlobalStateContext(context.Background())
	if err != nil || state.Cards[0].Title != card.Title {
		t.Fatalf("recovery: %+v %v", state, err)
	}
	// A recovered write counts as metadata even if it started as text.
	if changes, metadata := testkit.ChangeCounters(t, s); changes != pending.Sequence || metadata != pending.Sequence {
		t.Fatalf("recovered counters %d/%d, want %d", changes, metadata, pending.Sequence)
	}
	if s.SyncMutationPending() {
		t.Fatal("pending marker survived successful recovery")
	}
}

func TestKilledWriterRecovery(t *testing.T) {
	t.Parallel()
	if root := os.Getenv("DIETER_TEST_CRASH_STORE"); root != "" {
		data := store.New(root)
		_, err := data.BeginWrite()
		if err != nil {
			os.Exit(2)
		}
		card, err := data.Kanban.ResolveCard(os.Getenv("DIETER_TEST_CRASH_CARD"))
		if err != nil {
			os.Exit(3)
		}
		card.Title = "committed before process death"
		if err := data.Kanban.WriteCard(card); err != nil {
			os.Exit(4)
		}
		// Simulate death after the atomic domain write and before sync publication.
		// No defers run; the kernel releases admission but the owner directory stays.
		os.Exit(0)
	}
	data, p, b := testkit.BoardStore(t, model.WorkflowReview)
	card, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, Title: "before"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := data.Kanban.GlobalState(); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(os.Args[0], "-test.run=^TestKilledWriterRecovery$")
	command.Env = append(os.Environ(), "DIETER_TEST_CRASH_STORE="+data.Root, "DIETER_TEST_CRASH_CARD="+card.ID)
	if raw, err := command.CombinedOutput(); err != nil {
		t.Fatalf("crash fixture: %v %s", err, raw)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	state, err := data.Kanban.GlobalStateContext(ctx)
	if err != nil || state.Cards[0].Title != "committed before process death" {
		t.Fatalf("killed writer lost update: %+v %v", state, err)
	}
	if data.SyncMutationPending() {
		t.Fatal("recovery left pending revision")
	}
}

// A writer that lost its sync publication leaves a pending mutation. A no-op
// conditional write neither publishes nor duplicates it; the recovery sweep
// (and the next real write) commits it without an empty transaction.
func TestRecoverySweepCommitsPendingMutationAfterNoopWrite(t *testing.T) {
	t.Parallel()
	s, project, _ := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "before"})
	if err != nil {
		t.Fatal(err)
	}
	release, err := s.BeginWriteLock()
	if err != nil {
		t.Fatal(err)
	}
	pending, err := s.PrepareMutation(home.MetadataChange)
	if err == nil {
		card.Title = "recovered"
		err = s.Kanban.WriteCard(card)
	}
	release() // simulate a writer that lost its sync publication
	if err != nil {
		t.Fatal(err)
	}
	got, err := s.Kanban.UpdateCardCache(card.ID, kanban.CardCacheInput{Title: card.Title})
	if err != nil || got.Title != card.Title {
		t.Fatalf("no-op write: %+v %v", got, err)
	}
	if err := s.Recover(); err != nil || s.SyncMutationPending() {
		t.Fatalf("recovery sweep left the pending mutation: %v", err)
	}
	if changes, _ := testkit.ChangeCounters(t, s); changes != pending.Sequence {
		t.Fatalf("recovery added an empty transaction: changes=%d want %d", changes, pending.Sequence)
	}
}
