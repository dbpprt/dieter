package home

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestQueuedWriterAdmissionCancelsWithoutTakingOrLeakingTheLock(t *testing.T) {
	t.Parallel()
	var gate ContextMutex
	if err := gate.LockContext(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() { result <- gate.LockContext(ctx) }()
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("canceled admission: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled waiter blocked behind active writer")
	}
	if gate.TryLock() {
		t.Fatal("canceled waiter released another writer's lock")
	}
	gate.Unlock()
	if !gate.TryLock() {
		t.Fatal("canceled waiter leaked admission")
	}
	gate.Unlock()
}
