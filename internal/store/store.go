package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	md "github.com/dbpprt/dieter/internal/markdown"
	"github.com/dbpprt/dieter/internal/model"
)

var (
	ErrNotFound = errors.New("not found")
	writeMu     contextMutex
)

type Store struct {
	peerWakeOnce     sync.Once
	peerWake         chan struct{}
	importing        bool
	peerCacheMu      sync.Mutex
	peerCacheAccount string
	peerDBMu         sync.Mutex
	peerDBs          map[string]*sql.DB
	peerCacheData    PeerData
	Root             string

	conversations conversationCache
	statuses      conversationStatusCache
	checkpoints   conversationCheckpoints
	syncJournal   syncJournalCache

	usageMu    sync.Mutex
	usageCache map[string]cardUsageCacheEntry

	scheduleDBMu           sync.Mutex
	scheduleDB             *sql.DB
	globalStateMu          contextMutex
	globalStateCursor      SyncCursor
	globalStateSnapshot    *model.State
	globalStateMetadataKey string
}

func DefaultRoot() string {
	if value := os.Getenv("DIETER_HOME"); value != "" {
		return value
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".dieter"
	}
	return filepath.Join(home, ".dieter")
}

func New(root string) *Store {
	if root == "" {
		root = DefaultRoot()
	}
	if !filepath.IsAbs(root) {
		if absolute, err := filepath.Abs(root); err == nil {
			root = absolute
		}
	}
	return &Store{Root: root}
}

func (s *Store) Ensure() error {
	if err := s.checkStorageSchema(); err != nil {
		return err
	}
	if err := os.MkdirAll(s.Root, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(s.Root, 0o700); err != nil {
		return err
	}
	for _, dir := range []string{
		s.projectDir(), s.boardDir(), s.cardDir(), s.archivedCardDir(), s.commentDir(), s.conversationDir(), s.runtimeDir(), s.scheduleDir(), s.scheduleRunDir(), s.authDir(), s.syncDir(),
		s.workspaceDir(), s.gitOperationDir(), s.pullRequestDir(), s.changeCommentDir(), s.recoveryDir(), filepath.Join(s.Root, "logs"), filepath.Join(s.runtimeDir(), "leases"),
	} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			return err
		}
	}
	if err := s.migratePrivateMetadataPermissions(); err != nil {
		return err
	}
	if _, err := s.ensureSyncEpoch(); err != nil {
		return err
	}
	release, err := s.beginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	return s.recoverCardWrites()
}

// beginWriteLock serializes access both within the process and across CLI/server
// processes without publishing a sync mutation. Conditional writers use it to
// revalidate that a domain change is still necessary before advancing the sync
// journal. Directory creation also coordinates older daemons; a stale lock is
// reclaimed only after its recorded process has died.
func (s *Store) beginWriteLock() (func(), error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return s.beginWriteLockContext(ctx)
}

func (s *Store) beginWriteLockContext(ctx context.Context) (func(), error) {
	requestedAt := time.Now()
	if err := writeMu.LockContext(ctx); err != nil {
		return nil, err
	}
	releaseProcess := true
	defer func() {
		if releaseProcess {
			writeMu.Unlock()
		}
	}()
	if err := os.MkdirAll(s.Root, 0o700); err != nil {
		return nil, err
	}
	unlockAdmission, err := s.writerAdmission(ctx)
	if err != nil {
		return nil, err
	}
	defer func() {
		if releaseProcess {
			unlockAdmission()
		}
	}()
	lockPath := filepath.Join(s.Root, ".write-lock")
	for {
		err := os.Mkdir(lockPath, 0o700)
		if err == nil {
			if err := os.WriteFile(filepath.Join(lockPath, "owner"), []byte(strconv.Itoa(os.Getpid())), 0o600); err != nil {
				_ = os.Remove(lockPath)
				return nil, err
			}
			if err := s.establishStorageSchema(); err != nil {
				_ = os.Remove(filepath.Join(lockPath, "owner"))
				_ = os.Remove(lockPath)
				return nil, err
			}
			acquiredAt := time.Now()
			releaseProcess = false
			return func() {
				held := time.Since(acquiredAt)
				if held > 100*time.Millisecond || acquiredAt.Sub(requestedAt) > 100*time.Millisecond {
					slog.Debug("store writer lock", "waitMs", acquiredAt.Sub(requestedAt).Milliseconds(), "heldMs", held.Milliseconds())
				}
				_ = os.Remove(filepath.Join(lockPath, "owner"))
				_ = os.Remove(lockPath)
				unlockAdmission()
				writeMu.Unlock()
			}, nil
		}
		if !errors.Is(err, os.ErrExist) {
			return nil, err
		}
		if reclaimDeadWriter(lockPath) {
			continue
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(5 * time.Millisecond):
		}

	}
}

// beginWrite acquires the central writer lock and publishes a durable sync
// invalidation before the caller changes domain files.
func (s *Store) beginWrite() (func(), error) {
	return s.beginWriteKind("store_changed")
}

func (s *Store) beginWriteKind(kind string) (func(), error) {
	release, err := s.beginWriteLock()
	if err != nil {
		return nil, err
	}
	if err := s.flushScheduleOutbox(); err != nil {
		release()
		return nil, err
	}
	if err := s.recoverCardWrites(); err != nil {
		release()
		return nil, err
	}
	event, err := s.prepareSyncMutation(kind)
	if err != nil {
		release()
		return nil, err
	}
	return func() {
		if err := s.flushScheduleOutbox(); err != nil {
			slog.Error("schedule publication deferred to recovery", "error", err)
		}
		// A failed publication leaves the durable pending marker for reader/next
		// writer recovery. Domain data is already durable; never hide a partial write.
		if err := s.commitSyncMutation(event); err != nil {
			slog.Error("sync commit deferred to recovery", "error", err)
		}
		release()
		s.flushConversationCheckpoints()
	}, nil
}

func (s *Store) projectDir() string           { return filepath.Join(s.Root, "projects") }
func (s *Store) boardDir() string             { return filepath.Join(s.Root, "boards") }
func (s *Store) cardDir() string              { return filepath.Join(s.Root, "cards") }
func (s *Store) archivedCardDir() string      { return filepath.Join(s.Root, "archived-cards") }
func (s *Store) commentDir() string           { return filepath.Join(s.Root, "comments") }
func (s *Store) conversationDir() string      { return filepath.Join(s.Root, "conversations") }
func (s *Store) runtimeDir() string           { return filepath.Join(s.Root, "runtime") }
func (s *Store) scheduleDir() string          { return filepath.Join(s.Root, "schedules") }
func (s *Store) scheduleRunDir() string       { return filepath.Join(s.Root, "schedule-runs") }
func (s *Store) scheduleDatabasePath() string { return filepath.Join(s.Root, "schedules.db") }
func (s *Store) authDir() string              { return filepath.Join(s.Root, "auth") }
func (s *Store) workspaceDir() string         { return filepath.Join(s.Root, "workspaces") }
func (s *Store) gitOperationDir() string      { return filepath.Join(s.Root, "git-operations") }
func (s *Store) pullRequestDir() string       { return filepath.Join(s.Root, "pull-requests") }
func (s *Store) changeCommentDir() string     { return filepath.Join(s.Root, "change-comments") }
func (s *Store) recoveryDir() string          { return filepath.Join(s.Root, "recovery") }

func (s *Store) settingsPath() string { return filepath.Join(s.Root, "settings.yaml") }

func (s *Store) RuntimeDir() string { return s.runtimeDir() }

func (s *Store) WorktreeRoot() string { return filepath.Join(s.Root, "worktrees") }

func (s *Store) RecoveryDir() string { return s.recoveryDir() }

func timestamp() string { return time.Now().UTC().Format(time.RFC3339Nano) }

func newID(prefix string) string {
	buffer := make([]byte, 6)
	if _, err := rand.Read(buffer); err != nil {
		return fmt.Sprintf("%s%x", prefix, time.Now().UnixNano())
	}
	return prefix + hex.EncodeToString(buffer)
}

func atomicWrite(path string, data []byte) error {
	return atomicWriteMode(path, data, 0o600)
}

func atomicWriteMode(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".dieter-write-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName)
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(path))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}

func writeMarkdown(path string, value any, body string) error {
	data, err := md.Marshal(value, body)
	if err != nil {
		return err
	}
	return atomicWrite(path, data)
}

func readMarkdown(path string, value any) (string, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	return md.Unmarshal(data, value)
}

func listMarkdown(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return []string{}, nil
	}
	if err != nil {
		return nil, err
	}
	paths := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".md") {
			paths = append(paths, filepath.Join(dir, entry.Name()))
		}
	}
	sort.Strings(paths)
	return paths, nil
}

func hasGitDirectory(path string) bool {
	info, err := os.Stat(filepath.Join(path, ".git"))
	return err == nil && (info.IsDir() || info.Mode().IsRegular())
}

func normalizePath(path string) (string, error) {
	if path == "" {
		return "", errors.New("project path is required")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(abs)
	if err == nil {
		abs = resolved
	}
	info, err := os.Stat(abs)
	if err != nil {
		return "", fmt.Errorf("project path: %w", err)
	}
	if !info.IsDir() {
		return "", errors.New("project path must be a directory")
	}
	if !hasGitDirectory(abs) {
		return "", errors.New("project path must be a Git working tree (missing .git)")
	}
	return abs, nil
}

func matchRef(ref, id, name string) bool {
	return ref == id || strings.EqualFold(ref, name)
}

func containsFold(value, query string) bool {
	return strings.Contains(strings.ToLower(value), strings.ToLower(query))
}

// Age is not proof that a writer died: large writes or a suspended daemon may
// hold the lock for longer than thirty seconds. Only reclaim a known dead PID.
func reclaimDeadWriter(path string) bool {
	raw, err := os.ReadFile(filepath.Join(path, "owner"))
	if err != nil {
		return false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 0 {
		return false
	}
	process, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	signalErr := process.Signal(syscall.Signal(0))
	if !errors.Is(signalErr, os.ErrProcessDone) && !errors.Is(signalErr, syscall.ESRCH) {
		return false
	}
	// Rename claims this exact abandoned directory; competing reclaimers cannot
	// delete a new owner's lock.
	abandoned := path + ".abandoned-" + newID("")
	if err := os.Rename(path, abandoned); err != nil {
		return false
	}
	_ = os.RemoveAll(abandoned)
	return true
}
