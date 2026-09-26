package store

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

type CompatibilityUpdateReceipt struct {
	Key                  string `json:"key"`
	GatewayIssuer        string `json:"gatewayIssuer"`
	PolicyRevision       string `json:"policyRevision"`
	InstalledVersion     string `json:"installedVersion"`
	MinimumDaemonVersion string `json:"minimumDaemonVersion"`
	AttemptedAt          string `json:"attemptedAt"`
	Outcome              string `json:"outcome"`
	Error                string `json:"error,omitempty"`
}

func (s *Store) compatibilityUpdateReceiptPath() string {
	return filepath.Join(s.Root, "runtime", "compatibility-update.json")
}

func (s *Store) BeginCompatibilityUpdate(receipt CompatibilityUpdateReceipt) (bool, error) {
	release, err := s.beginWriteLock()
	if err != nil {
		return false, err
	}
	defer release()
	current, err := s.readCompatibilityUpdateReceipt()
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return false, err
	}
	if current.Key == receipt.Key {
		return false, nil
	}
	receipt.AttemptedAt = time.Now().UTC().Format(time.RFC3339Nano)
	receipt.Outcome = "admitted"
	return true, writeJSON(s.compatibilityUpdateReceiptPath(), receipt)
}

func (s *Store) FinishCompatibilityUpdate(key, outcome, message string) error {
	release, err := s.beginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	receipt, err := s.readCompatibilityUpdateReceipt()
	if err != nil {
		return err
	}
	if receipt.Key != key {
		return errors.New("compatibility update receipt changed")
	}
	receipt.Outcome, receipt.Error = outcome, message
	return writeJSON(s.compatibilityUpdateReceiptPath(), receipt)
}

func (s *Store) CompatibilityUpdateReceipt() (CompatibilityUpdateReceipt, error) {
	return s.readCompatibilityUpdateReceipt()
}

func (s *Store) readCompatibilityUpdateReceipt() (CompatibilityUpdateReceipt, error) {
	var receipt CompatibilityUpdateReceipt
	raw, err := os.ReadFile(s.compatibilityUpdateReceiptPath())
	if err != nil {
		return receipt, err
	}
	if err := json.Unmarshal(raw, &receipt); err != nil {
		return receipt, err
	}
	return receipt, nil
}
