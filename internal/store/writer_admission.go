package store

import (
	"context"
	"errors"
	"fmt"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/platform/fsx"
)

// ErrWriterBusy reports that a write timed out waiting for the central writer
// lock. The timeout happens before any mutation, so the write may be retried.
var ErrWriterBusy = fault.New(fault.Unavailable, "storage writer is busy")

func writerBusy(err error) error {
	if errors.Is(err, context.DeadlineExceeded) {
		return fmt.Errorf("%w: %w", ErrWriterBusy, err)
	}
	return err
}

// The kernel releases this cross-process writer lock on process death. The
// lock file stays at a stable path and is never removed while contenders wait.
func (s *Store) writerAdmission(ctx context.Context) (func(), error) {
	lock, err := fsx.LockHome(ctx, s.Root)
	if err != nil {
		return nil, err
	}
	return func() { _ = lock.Close() }, nil
}
