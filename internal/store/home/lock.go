package home

import (
	"context"
	"log/slog"
	"os"
	"time"
)

// WriterSample describes one admission attempt. Held excludes post-release
// work such as checkpoint encoding. Err is non-nil when admission failed.
type WriterSample struct {
	Wait, Held time.Duration
	Err        error
}

// SetWriterObserver configures bounded diagnostics before the store is used.
// The observer runs after release (or failed admission), may run concurrently,
// and must not block. It must not call back into the writer.
func (s *Dir) SetWriterObserver(observer func(WriterSample)) { s.writerObserver = observer }

// BeginWriteLock serializes access both within the process and across CLI/server
// processes without recording a change. Conditional writers use it to
// revalidate that a domain change is still necessary before advancing the change
// counter. Kernel file locking releases the cross-process lock on process exit.
func (s *Dir) BeginWriteLock() (func(), error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return s.BeginWriteLockContext(ctx)
}

// BeginWriteLockContext is BeginWriteLock bounded by ctx. A timeout before
// admission is ErrWriterBusy and may be retried.
func (s *Dir) BeginWriteLockContext(ctx context.Context) (release func(), err error) {
	requestedAt := time.Now()
	defer func() {
		if err != nil {
			wait := time.Since(requestedAt)
			slog.Debug("store writer admission failed", "waitMs", wait.Milliseconds(), "error", err)
			if s.writerObserver != nil {
				s.writerObserver(WriterSample{Wait: wait, Err: err})
			}
		}
	}()
	if err := s.writeMu.LockContext(ctx); err != nil {
		return nil, writerBusy(err)
	}
	releaseProcess := true
	defer func() {
		if releaseProcess {
			s.writeMu.Unlock()
		}
	}()
	if err := os.MkdirAll(s.Root, 0o700); err != nil {
		return nil, err
	}
	unlockAdmission, err := s.writerAdmission(ctx)
	if err != nil {
		return nil, writerBusy(err)
	}
	defer func() {
		if releaseProcess {
			unlockAdmission()
		}
	}()
	if err := s.establishStorageSchema(); err != nil {
		return nil, err
	}
	acquiredAt := time.Now()
	releaseProcess = false
	return func() {
		held := time.Since(acquiredAt)
		if held > 100*time.Millisecond || acquiredAt.Sub(requestedAt) > 100*time.Millisecond {
			slog.Debug("store writer lock", "waitMs", acquiredAt.Sub(requestedAt).Milliseconds(), "heldMs", held.Milliseconds())
		}
		unlockAdmission()
		s.writeMu.Unlock()
		if s.writerObserver != nil {
			s.writerObserver(WriterSample{Wait: acquiredAt.Sub(requestedAt), Held: held})
		}
	}, nil
}

// WriterQueued reports whether a writer of this process holds or awaits the
// writer lock. It is a point-in-time diagnostic.
func (s *Dir) WriterQueued() bool {
	if !s.writeMu.TryLock() {
		return true
	}
	s.writeMu.Unlock()
	return false
}

// BeginWrite acquires the central writer lock and records a durable pending
// change before the caller changes domain files.
func (s *Dir) BeginWrite() (func(), error) {
	return s.BeginWriteKind(MetadataChange)
}

// BeginWriteKind is BeginWrite for a change of kind (MetadataChange or
// ConversationChange).
func (s *Dir) BeginWriteKind(kind string) (func(), error) {
	write, err := s.BeginConditionalWrite()
	if err != nil {
		return nil, err
	}
	if err := write.Prepare(kind); err != nil {
		write.release()
		return nil, err
	}
	return write.Finish, nil
}

// Write is a conditional writer: it compares under the same lock as ordinary
// writers, but publishes a new mutation only when domain data changes (Prepare).
type Write struct {
	store   *Dir
	release func()
	pending *PendingMutation
}

// BeginConditionalWrite acquires the writer lock; call Prepare before changing
// domain files and Finish (always) to commit and release.
func (s *Dir) BeginConditionalWrite() (*Write, error) {
	release, err := s.BeginWriteLock()
	if err != nil {
		return nil, err
	}
	return &Write{store: s, release: release}, nil
}

func (w *Write) Prepare(kind string) error {
	var err error
	w.pending, err = w.store.PrepareMutation(kind)
	return err
}

func (w *Write) Finish() {
	s := w.store
	if s.hooks.BeforeCommit != nil {
		s.hooks.BeforeCommit()
	}
	// A failed commit leaves the durable pending marker for reader/next
	// writer recovery. Domain data is already durable; never hide a partial write.
	if err := s.CommitMutation(w.pending); err != nil {
		slog.Error("change commit deferred to recovery", "error", err)
	}
	w.release()
	// Recovery may have changed domain data even when the requested update was
	// a no-op. Waking is a hint; readers compare the counters and send nothing
	// when nothing changed.
	s.NotifyChanges()
	if s.hooks.AfterRelease != nil {
		s.hooks.AfterRelease()
	}
}

// Hooks run around every committed write. The composition root sets them once,
// before the store is used.
type Hooks struct {
	// BeforeCommit runs under the writer lock before the change commits.
	BeforeCommit func()
	// AfterRelease runs after the writer lock is released.
	AfterRelease func()
}

// SetHooks installs the write hooks. Call it before the store is used.
func (s *Dir) SetHooks(hooks Hooks) { s.hooks = hooks }
