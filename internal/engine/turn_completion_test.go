package engine

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/testkit"
)

type queuedPreparationRunner struct {
	*channelRunner
	blocked atomic.Bool
	entered chan struct{}
	release chan struct{}
	once    sync.Once
}

func (r *queuedPreparationRunner) PrepareRuntime(ctx context.Context, digest string) (harness.RuntimeReference, error) {
	if r.blocked.Load() {
		r.once.Do(func() { close(r.entered) })
		select {
		case <-r.release:
		case <-ctx.Done():
			return harness.RuntimeReference{}, ctx.Err()
		}
	}
	return harness.RuntimeReference{Digest: digest}, nil
}

func TestWaitForTurnsJoinsQueuedHandoffAfterActiveSlotIsReleased(t *testing.T) {
	t.Parallel()
	service, runner, project, board := channelSetup(t)
	prepared := &queuedPreparationRunner{
		channelRunner: runner,
		entered:       make(chan struct{}),
		release:       make(chan struct{}),
	}
	service.Runner = prepared
	var releaseOnce sync.Once
	releasePreparation := func() { releaseOnce.Do(func() { close(prepared.release) }) }
	t.Cleanup(releasePreparation)
	card := channelCard(t, service, project, board, "Queued handoff")
	releaseFirst := runner.hold(card.ID)
	startChannelTurn(t, service, card, "hold first turn")
	queued, err := service.SubmitCard(card.ID, "second turn", card.Provider, card.Model, "")
	if err != nil || !queued {
		t.Fatalf("queue second turn: queued=%v err=%v", queued, err)
	}
	prepared.blocked.Store(true)
	close(releaseFirst)
	select {
	case <-prepared.entered:
	case <-time.After(testkit.Budget(30 * time.Second)):
		t.Fatal("queued turn did not reach runtime preparation")
	}
	service.mu.Lock()
	active := service.active[card.ID]
	service.mu.Unlock()
	if active != nil {
		t.Fatal("first turn still occupies the active slot during queued preparation")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := service.WaitForTurns(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("completion barrier returned before queued handoff finished: %v", err)
	}
	releasePreparation()
	ctx, cancel = context.WithTimeout(context.Background(), testkit.Budget(30*time.Second))
	defer cancel()
	if err := service.WaitForTurns(ctx); err != nil {
		t.Fatal(err)
	}
	conversation, err := service.Store.Conversations.Get(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(runner.turns(card.ID)) != 2 || len(conversation.Queue) != 0 || conversation.Status != "idle" {
		t.Fatalf("queued successor did not finish: turns=%d queue=%d status=%q", len(runner.turns(card.ID)), len(conversation.Queue), conversation.Status)
	}
}
