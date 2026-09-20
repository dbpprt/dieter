package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/unix"
)

// The kernel releases this cross-process writer lock on process death. The
// lock file stays at a stable path and is never removed while contenders wait.
func (s *Store) writerAdmission(ctx context.Context) (func(), error) {
	file, err := os.OpenFile(filepath.Join(s.Root, ".writer-admission"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	for {
		err = unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB)
		if err == nil {
			return func() { _ = unix.Flock(int(file.Fd()), unix.LOCK_UN); _ = file.Close() }, nil
		}
		if !errors.Is(err, unix.EWOULDBLOCK) {
			file.Close()
			return nil, err
		}
		select {
		case <-ctx.Done():
			file.Close()
			return nil, ctx.Err()
		case <-time.After(5 * time.Millisecond):
		}
	}
}
