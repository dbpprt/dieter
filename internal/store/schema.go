package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const storageSchema = 2

var ErrUnsupportedStore = errors.New("unsupported Dieter store; use a fresh DIETER_HOME for this pre-release baseline")

func (s *Store) checkStorageSchema() error {
	if _, err := os.Stat(filepath.Join(s.Root, "import-state.json")); err == nil {
		return errors.New("unsupported incomplete store import; use a fresh DIETER_HOME")
	}
	raw, err := os.ReadFile(filepath.Join(s.Root, "storage-schema.json"))
	if err == nil {
		var schema struct {
			Version int `json:"version"`
		}
		if json.Unmarshal(raw, &schema) != nil || schema.Version != storageSchema {
			return fmt.Errorf("unsupported Dieter storage schema; expected %d", storageSchema)
		}
		return nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	paths, err := listMarkdown(filepath.Join(s.Root, "projects"))
	if err != nil {
		return err
	}
	if len(paths) > 0 {
		return ErrUnsupportedStore
	}
	return nil
}
func (s *Store) establishStorageSchema() error {
	if err := s.checkStorageSchema(); err != nil {
		return err
	}
	path := filepath.Join(s.Root, "storage-schema.json")
	if _, err := os.Stat(path); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return atomicWrite(path, []byte(`{"version":2}`))
}
