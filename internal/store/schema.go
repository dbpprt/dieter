package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

const storageSchema = 2

var ErrLegacyStore = errors.New("legacy Dieter store: stop the daemon and run dieter daemon import-store --backup PATH; use --apply after reviewing the dry run")

func (s *Store) checkStorageSchema() error {
	if s.importing {
		return nil
	}
	if _, err := os.Stat(filepath.Join(s.Root, "import-state.json")); err == nil {
		return errors.New("store import is incomplete; resume the offline import before starting Dieter")
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
	paths, err := listMarkdown(s.projectDir())
	if err != nil {
		return err
	}
	if len(paths) > 0 {
		return ErrLegacyStore
	}
	return nil
}
func (s *Store) establishStorageSchema() error {
	if err := s.checkStorageSchema(); err != nil {
		return err
	}
	if s.importing {
		return nil
	}
	path := filepath.Join(s.Root, "storage-schema.json")
	if _, err := os.Stat(path); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return atomicWrite(path, []byte(`{"version":2}`))
}
