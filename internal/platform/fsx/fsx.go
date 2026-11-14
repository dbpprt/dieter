// Package fsx holds Dieter's filesystem primitives: crash-safe atomic file
// replacement and exclusive advisory locks. Every durable write and every
// cross-process lock in the daemon goes through it.
package fsx

import (
	"errors"
	"os"
	"path/filepath"
)

// WriteFile atomically replaces path with data. It writes a temporary file
// with mode in the same directory (creating the directory with 0700 when it is
// missing), fsyncs it, renames it over path and fsyncs the directory. Readers
// observe either the previous or the new content, also after a crash.
func WriteFile(path string, data []byte, mode os.FileMode) error {
	staged, err := Stage(path, data, mode)
	if err != nil {
		return err
	}
	defer staged.Discard()
	return staged.Publish()
}

// Staged is a written and fsynced temporary file beside its destination.
// Staging is invisible to readers, so the slow write and fsync can run before
// taking the central lock; only Publish, the rename, is a mutation.
type Staged struct{ temporary, path string }

// Stage writes data to a temporary file in path's directory and fsyncs it.
func Stage(path string, data []byte, mode os.FileMode) (*Staged, error) {
	temporary, err := writeTemporary(path, data, mode)
	if err != nil {
		return nil, err
	}
	return &Staged{temporary: temporary, path: path}, nil
}

// Publish atomically replaces the destination and fsyncs its directory.
func (s *Staged) Publish() error {
	if err := os.Rename(s.temporary, s.path); err != nil {
		return err
	}
	s.temporary = ""
	return SyncDir(filepath.Dir(s.path))
}

// Discard removes an unpublished staged file; it is a no-op after Publish.
func (s *Staged) Discard() {
	if s.temporary != "" {
		_ = os.Remove(s.temporary)
		s.temporary = ""
	}
}

// CreateFile atomically publishes data at path only when path does not exist
// yet. It fails with an fs.ErrExist error instead of replacing a file another
// writer created first; no partially written file is ever visible.
func CreateFile(path string, data []byte, mode os.FileMode) error {
	temporary, err := writeTemporary(path, data, mode)
	if err != nil {
		return err
	}
	defer os.Remove(temporary)
	// Linking the fully written temporary file is atomic and fails on EEXIST.
	if err := os.Link(temporary, path); err != nil {
		return err
	}
	return SyncDir(filepath.Dir(path))
}

// SyncDir fsyncs a directory so a rename or link inside it is durable.
func SyncDir(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	return errors.Join(directory.Sync(), directory.Close())
}

func writeTemporary(path string, data []byte, mode os.FileMode) (string, error) {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return "", err
	}
	file, err := os.CreateTemp(directory, ".dieter-write-*")
	if err != nil {
		return "", err
	}
	name := file.Name()
	if err := writeAndSync(file, data, mode); err != nil {
		_ = os.Remove(name)
		return "", err
	}
	return name, nil
}

func writeAndSync(file *os.File, data []byte, mode os.FileMode) error {
	if err := file.Chmod(mode); err != nil {
		_ = file.Close()
		return err
	}
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		return err
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return err
	}
	return file.Close()
}
