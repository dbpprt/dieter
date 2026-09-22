package server

import (
	"context"
	"time"

	"github.com/dbpprt/dieter/internal/store"
)

// Subscribed before the initial read so a commit during projection is never
// lost. A bounded coalescing window prevents token bursts from building one
// projection per event; idle subscriptions wake only for recovery.
type changeWait struct {
	changes         <-chan struct{}
	unsubscribe     func()
	recovery        *time.Ticker
	last            time.Time
	minimumInterval time.Duration
}

func newChangeWait(s *store.Store) *changeWait {
	changes, unsubscribe := s.SubscribeChanges()
	return &changeWait{changes: changes, unsubscribe: unsubscribe, recovery: time.NewTicker(2 * time.Second), minimumInterval: 25 * time.Millisecond}
}

func (w *changeWait) close() { w.recovery.Stop(); w.unsubscribe() }

func (w *changeWait) wait(ctx context.Context) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-w.recovery.C:
	case <-w.changes:
	}
	if delay := time.Until(w.last.Add(w.minimumInterval)); delay > 0 {
		timer := time.NewTimer(delay)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
		}
	}
	// The following read covers everything committed before this drain.
	select {
	case <-w.changes:
	default:
	}
	w.last = time.Now()
	return nil
}
