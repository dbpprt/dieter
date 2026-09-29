package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestWriterLockTimeoutIsRetryableBusy(t *testing.T) {
	s := New(t.TempDir())
	// Another Dieter process holds the central storage lock.
	unlock, err := s.writerAdmission(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	release, err := s.beginWriteLockContext(ctx)
	if err == nil {
		release()
		t.Fatal("acquired a held writer lock")
	}
	if !errors.Is(err, ErrWriterBusy) || !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err=%v, want a retryable busy deadline", err)
	}
	canceled, cancelNow := context.WithCancel(context.Background())
	cancelNow()
	if _, err := s.beginWriteLockContext(canceled); errors.Is(err, ErrWriterBusy) || !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled err=%v, want a non-retryable cancellation", err)
	}
}
