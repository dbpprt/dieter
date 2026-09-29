package app

import (
	"context"
	"errors"
	"log/slog"
	"time"

	"github.com/dbpprt/dieter/internal/store"
)

// The heartbeat watchdog detects a silent worker. It must not blame the worker
// for time the daemon spends on its own work for that turn: while a worker
// frame is persisted or a background-process call is answered, the daemon does
// not read the worker's pipe, so queued heartbeats cannot be observed.
func (s *Service) beginTurnHostWork(cardID, turnID string) (func(), bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	current := s.active[cardID]
	if current == nil || current.turnID != turnID || current.recoveryErr != nil {
		return func() {}, false
	}
	current.workerObserved = true
	current.lastProgress = time.Now()
	current.hostWork++
	return func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		current.hostWork--
		current.lastProgress = time.Now()
	}, true
}

// Each attempt waits up to the store's writer-lock timeout before failing.
const storeBusyWriteAttempts = 6

// retryWhileStoreBusy retries a turn write that timed out waiting for the
// central writer lock. Nothing was written, so a retry cannot duplicate an
// event; a transient contender must not fail an otherwise healthy turn.
func retryWhileStoreBusy(ctx context.Context, write func() error) error {
	for attempt := 1; ; attempt++ {
		err := write()
		if !errors.Is(err, store.ErrWriterBusy) || attempt >= storeBusyWriteAttempts || ctx.Err() != nil {
			return err
		}
		slog.Warn("retrying agent turn write while storage is busy", "attempt", attempt)
	}
}
