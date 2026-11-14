package fsx

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestWriteFileReplacesAtomicallyWithMode(t *testing.T) {
	t.Parallel()
	directory := filepath.Join(t.TempDir(), "nested")
	path := filepath.Join(directory, "value.json")
	if err := WriteFile(path, []byte("one"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := WriteFile(path, []byte("two"), 0o640); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(path)
	if err != nil || string(raw) != "two" {
		t.Fatalf("content=%q err=%v", raw, err)
	}
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o640 {
		t.Fatalf("mode=%v err=%v", info.Mode().Perm(), err)
	}
	parent, err := os.Stat(directory)
	if err != nil || parent.Mode().Perm() != 0o700 {
		t.Fatalf("created directory mode=%v err=%v", parent.Mode().Perm(), err)
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 1 {
		t.Fatalf("temporary files remain: %v %v", entries, err)
	}
}

func TestCreateFileNeverReplaces(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "key")
	if err := CreateFile(path, []byte("first"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := CreateFile(path, []byte("second"), 0o600); !errors.Is(err, fs.ErrExist) {
		t.Fatalf("second create err=%v", err)
	}
	raw, err := os.ReadFile(path)
	if err != nil || string(raw) != "first" {
		t.Fatalf("content=%q err=%v", raw, err)
	}
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil || len(entries) != 1 {
		t.Fatalf("temporary files remain: %v %v", entries, err)
	}
}

func TestTryLockExcludesOtherDescriptorsUntilClosed(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "lock")
	first, err := TryLock(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := TryLock(path); !errors.Is(err, ErrLocked) {
		t.Fatalf("second lock err=%v", err)
	}
	if err := TryLockFile(first.File()); err != nil {
		t.Fatalf("relocking the owning descriptor: %v", err)
	}
	if err := first.Close(); err != nil {
		t.Fatal(err)
	}
	if err := first.Close(); err != nil {
		t.Fatalf("second close: %v", err)
	}
	second, err := TryLock(path)
	if err != nil {
		t.Fatal(err)
	}
	_ = second.Close()
}

func TestLockContextWaitsAndHonoursCancellation(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "lock")
	held, err := TryLock(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if _, err := LockContext(ctx, path, time.Millisecond); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("contended wait err=%v", err)
	}
	acquired := make(chan error, 1)
	go func() {
		lock, err := LockContext(context.Background(), path, time.Millisecond)
		if err == nil {
			err = lock.Close()
		}
		acquired <- err
	}()
	time.Sleep(5 * time.Millisecond)
	if err := held.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-acquired:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("waiter did not acquire the released lock")
	}
}
