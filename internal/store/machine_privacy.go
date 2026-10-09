package store

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

// MachinePrivacyRequest belongs to this execution host and this boot alone.
// It is deliberately outside the replicated peer store.
type MachinePrivacyRequest struct {
	BootID  string `json:"bootId"`
	Enabled bool   `json:"enabled"`
}

func (s *Store) MachinePrivacyRequest() (MachinePrivacyRequest, error) {
	var value MachinePrivacyRequest
	raw, err := os.ReadFile(filepath.Join(s.Root, "runtime", "machine-privacy.json"))
	if errors.Is(err, os.ErrNotExist) {
		return value, nil
	}
	if err != nil {
		return value, err
	}
	err = json.Unmarshal(raw, &value)
	return value, err
}

func (s *Store) SetMachinePrivacyRequest(value MachinePrivacyRequest) error {
	if value.BootID == "" {
		return errors.New("privacy requires a boot identity")
	}
	release, err := s.beginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	return writeJSON(filepath.Join(s.Root, "runtime", "machine-privacy.json"), value)
}
