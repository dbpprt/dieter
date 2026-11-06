package home

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestWriterObserverIncludesFailedAdmissionAndRunsAfterUnlock(t *testing.T) {
	t.Parallel()
	s := New(t.TempDir())
	var samples []WriterSample
	s.SetWriterObserver(func(sample WriterSample) {
		if !s.writeMu.TryLock() {
			t.Error("observer ran with writer held")
		} else {
			s.writeMu.Unlock()
		}
		samples = append(samples, sample)
	})
	release, err := s.BeginWriteLock()
	if err != nil {
		t.Fatal(err)
	}
	release()
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := s.BeginWriteLockContext(ctx); !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	if len(samples) != 2 || samples[0].Held <= 0 || samples[0].Err != nil || !errors.Is(samples[1].Err, context.Canceled) {
		t.Fatalf("wrong samples: %+v", samples)
	}
	unlock, err := s.writerAdmission(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	deadline, stop := context.WithTimeout(t.Context(), 20*time.Millisecond)
	defer stop()
	if _, err := s.BeginWriteLockContext(deadline); !errors.Is(err, ErrWriterBusy) {
		t.Fatal(err)
	}
	if len(samples) != 3 || !errors.Is(samples[2].Err, context.DeadlineExceeded) || samples[2].Wait <= 0 || samples[2].Held != 0 {
		t.Fatalf("timeout missing from diagnostics: %+v", samples)
	}
}
