package store

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	md "github.com/dbpprt/nauclio/internal/markdown"
)

var (
	ErrNotFound = errors.New("not found")
	writeMu     sync.Mutex
)

type Store struct {
	Root string
}

func DefaultRoot() string {
	if value := os.Getenv("NAUCLIO_HOME"); value != "" {
		return value
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".nauclio"
	}
	return filepath.Join(home, ".nauclio")
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
	for _, dir := range []string{
		s.projectDir(), s.boardDir(), s.cardDir(), s.commentDir(), s.conversationDir(), s.runtimeDir(), s.scheduleDir(), s.scheduleRunDir(), s.authDir(), s.syncDir(),
	} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	if err := os.Chmod(s.authDir(), 0o700); err != nil {
		return err
	}
	if _, err := s.ensureSyncEpoch(); err != nil {
		return err
	}
	return nil
}

// beginWrite serializes mutations both within the process and across CLI/server
// processes. Directory creation is the portable atomic primitive; a stale lock
// is reclaimed after 30 seconds so a killed process cannot wedge the store.
func (s *Store) beginWrite() (func(), error) {
	writeMu.Lock()
	releaseProcess := true
	defer func() {
		if releaseProcess {
			writeMu.Unlock()
		}
	}()
	if err := os.MkdirAll(s.Root, 0o755); err != nil {
		return nil, err
	}
	lockPath := filepath.Join(s.Root, ".write-lock")
	deadline := time.Now().Add(10 * time.Second)
	for {
		err := os.Mkdir(lockPath, 0o700)
		if err == nil {
			_, prepareErr := s.prepareSyncMutation()
			if prepareErr != nil {
				_ = os.Remove(lockPath)
				return nil, prepareErr
			}
			releaseProcess = false
			return func() {
				_ = os.Remove(lockPath)
				writeMu.Unlock()
			}, nil
		}
		if !errors.Is(err, os.ErrExist) {
			return nil, err
		}
		if info, statErr := os.Stat(lockPath); statErr == nil && time.Since(info.ModTime()) > 30*time.Second {
			_ = os.Remove(lockPath)
			continue
		}
		if time.Now().After(deadline) {
			return nil, errors.New("timed out waiting for another Nauclio writer")
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func (s *Store) projectDir() string      { return filepath.Join(s.Root, "projects") }
func (s *Store) boardDir() string        { return filepath.Join(s.Root, "boards") }
func (s *Store) cardDir() string         { return filepath.Join(s.Root, "cards") }
func (s *Store) commentDir() string      { return filepath.Join(s.Root, "comments") }
func (s *Store) conversationDir() string { return filepath.Join(s.Root, "conversations") }
func (s *Store) runtimeDir() string      { return filepath.Join(s.Root, "runtime") }
func (s *Store) scheduleDir() string     { return filepath.Join(s.Root, "schedules") }
func (s *Store) scheduleRunDir() string  { return filepath.Join(s.Root, "schedule-runs") }
func (s *Store) authDir() string         { return filepath.Join(s.Root, "auth") }

func (s *Store) settingsPath() string { return filepath.Join(s.Root, "settings.yaml") }

func (s *Store) RuntimeDir() string { return s.runtimeDir() }

func timestamp() string { return time.Now().UTC().Format(time.RFC3339Nano) }

func newID(prefix string) string {
	buffer := make([]byte, 6)
	if _, err := rand.Read(buffer); err != nil {
		return fmt.Sprintf("%s%x", prefix, time.Now().UnixNano())
	}
	return prefix + hex.EncodeToString(buffer)
}

func atomicWrite(path string, data []byte) error {
	return atomicWriteMode(path, data, 0o644)
}

func atomicWriteMode(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), ".nauclio-write-*")
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
	return os.Rename(tmpName, path)
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
