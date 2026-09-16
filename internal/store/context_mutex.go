package store

import (
	"context"
	"sync"
)

// A buffered channel queues blocked admissions instead of repeatedly racing
// TryLock. That matters when continuous writers compete with sync readers:
// polling can starve an otherwise cheap committed read for many seconds.
type contextMutex struct {
	once sync.Once
	gate chan struct{}
}

func (m *contextMutex) init() { m.once.Do(func() { m.gate = make(chan struct{}, 1) }) }

func (m *contextMutex) LockContext(ctx context.Context) error {
	m.init()
	if err := ctx.Err(); err != nil {
		return err
	}
	select {
	case m.gate <- struct{}{}:
		if err := ctx.Err(); err != nil {
			m.Unlock()
			return err
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (m *contextMutex) TryLock() bool {
	m.init()
	select {
	case m.gate <- struct{}{}:
		return true
	default:
		return false
	}
}

func (m *contextMutex) Unlock() { <-m.gate }
