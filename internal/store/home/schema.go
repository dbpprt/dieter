package home

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/platform/fsx"
)

const storageSchema = 2

var ErrUnsupportedStore = fault.New(fault.FailedPrecondition, "unsupported Dieter store; use a fresh DIETER_HOME for this pre-release baseline")

func (s *Dir) CheckStorageSchema() error {
	if _, err := os.Stat(filepath.Join(s.Root, "import-state.json")); err == nil {
		return fault.New(fault.Invalid, "unsupported incomplete store import; use a fresh DIETER_HOME")
	}
	raw, err := os.ReadFile(filepath.Join(s.Root, "storage-schema.json"))
	if err == nil {
		var schema struct {
			Version int `json:"version"`
		}
		if json.Unmarshal(raw, &schema) != nil || schema.Version != storageSchema {
			return fault.Invalidf("unsupported Dieter storage schema; expected %d", storageSchema)
		}
		return nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	paths, err := ListMarkdown(filepath.Join(s.Root, "projects"))
	if err != nil {
		return err
	}
	if len(paths) > 0 {
		return ErrUnsupportedStore
	}
	return nil
}
func (s *Dir) establishStorageSchema() error {
	if err := s.CheckStorageSchema(); err != nil {
		return err
	}
	path := filepath.Join(s.Root, "storage-schema.json")
	if _, err := os.Stat(path); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return fsx.WriteFile(path, []byte(`{"version":2}`), 0o600)
}
