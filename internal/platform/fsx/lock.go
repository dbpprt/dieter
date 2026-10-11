package fsx

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"time"

	"golang.org/x/sys/unix"
)

// ErrLocked reports that another open file description holds a lock.
var ErrLocked = errors.New("file is locked by another owner")

// Lock is an exclusive advisory lock (flock) on a stable lock file. The
// kernel releases it when its owner exits, so a crashed process never leaves
// a stale lock behind. Lock files are never removed while contenders wait.
type Lock struct{ file *os.File }

// OpenLockFile opens or creates a private lock file without following a
// symlink. Its descriptor is close-on-exec.
func OpenLockFile(path string) (*os.File, error) {
	fd, err := unix.Open(path, unix.O_CREAT|unix.O_RDWR|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), path), nil
}

// TryLock acquires the lock at path without waiting. It returns an error
// wrapping ErrLocked when another owner holds it.
func TryLock(path string) (*Lock, error) {
	file, err := OpenLockFile(path)
	if err != nil {
		return nil, err
	}
	if err := TryLockFile(file); err != nil {
		_ = file.Close()
		return nil, err
	}
	return &Lock{file: file}, nil
}

// TryLockFile acquires an exclusive lock on an already open file without
// waiting. Locking a descriptor that already holds the lock succeeds.
func TryLockFile(file *os.File) error {
	err := unix.Flock(int(file.Fd()), unix.LOCK_EX|unix.LOCK_NB)
	if errors.Is(err, unix.EWOULDBLOCK) || errors.Is(err, unix.EAGAIN) {
		return ErrLocked
	}
	return err
}

// LockContext waits for the lock at path, retrying every poll interval until
// ctx ends. Polling, rather than a blocking flock, keeps waits cancellable.
func LockContext(ctx context.Context, path string, poll time.Duration) (*Lock, error) {
	file, err := OpenLockFile(path)
	if err != nil {
		return nil, err
	}
	timer := time.NewTimer(poll)
	timer.Stop()
	defer timer.Stop()
	for {
		err := TryLockFile(file)
		if err == nil {
			return &Lock{file: file}, nil
		}
		if !errors.Is(err, ErrLocked) {
			_ = file.Close()
			return nil, err
		}
		timer.Reset(poll)
		select {
		case <-ctx.Done():
			_ = file.Close()
			return nil, ctx.Err()
		case <-timer.C:
		}
	}
}

// File is the locked descriptor, for handing the lock to an exec'd process.
func (l *Lock) File() *os.File { return l.file }

// Close releases the lock. It is safe to call more than once.
func (l *Lock) Close() error {
	if l == nil || l.file == nil {
		return nil
	}
	err := unix.Flock(int(l.file.Fd()), unix.LOCK_UN)
	err = errors.Join(err, l.file.Close())
	l.file = nil
	return err
}

// HomeLockName is the central cross-process writer lock of a DIETER_HOME.
// Every mutation of central storage holds it.
const HomeLockName = ".writer-admission"

// LockHome waits for the central writer lock of the DIETER_HOME root,
// creating root with 0700 when it does not exist yet.
func LockHome(ctx context.Context, root string) (*Lock, error) {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	return LockContext(ctx, filepath.Join(root, HomeLockName), 5*time.Millisecond)
}
