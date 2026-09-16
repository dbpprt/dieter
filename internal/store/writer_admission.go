package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/unix"
)

// The kernel releases this admission lock on process death. Keep the directory
// lock as well for compatibility with older daemons. Admission serializes stale
// owner reclamation, so a competing reader cannot remove a replacement lock.
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
