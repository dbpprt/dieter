package commands

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/platform/fsx"
)

// Result is the recorded outcome of one client command.
type Result struct {
	Kind      string `json:"kind"`
	CardID    string `json:"cardId,omitempty"`
	MessageID string `json:"messageId,omitempty"`
	Sent      bool   `json:"sent,omitempty"`
	Queued    bool   `json:"queued,omitempty"`
}

func commandKey(clientID, commandID string) (string, error) {
	clientID, commandID = strings.TrimSpace(clientID), strings.TrimSpace(commandID)
	if clientID == "" || commandID == "" || len(clientID) > 200 || len(commandID) > 200 {
		return "", fault.New(fault.Invalid, "client_id and command_id are required and must be at most 200 characters")
	}
	digest := sha256.Sum256([]byte(clientID + "\x00" + commandID))
	return hex.EncodeToString(digest[:]), nil
}

// DeterministicID derives a stable entity ID for a client command, so a retry
// creates the same entity.
func DeterministicID(prefix, clientID, commandID string) (string, error) {
	key, err := commandKey(clientID, commandID)
	if err != nil {
		return "", err
	}
	return prefix + key[:24], nil
}

// Load returns the recorded result of a client command, if any.
func (s *Store) Load(clientID, commandID string) (Result, bool, error) {
	key, err := commandKey(clientID, commandID)
	if err != nil {
		return Result{}, false, err
	}
	raw, err := os.ReadFile(filepath.Join(s.home.SyncDir(), "commands", key+".json"))
	if errors.Is(err, os.ErrNotExist) {
		return Result{}, false, nil
	}
	if err != nil {
		return Result{}, false, err
	}
	var result Result
	if err := json.Unmarshal(raw, &result); err != nil {
		return Result{}, false, err
	}
	return result, true, nil
}

// Save records the result of a client command.
func (s *Store) Save(clientID, commandID string, result Result) error {
	key, err := commandKey(clientID, commandID)
	if err != nil {
		return err
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return err
	}
	defer release()
	raw, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return err
	}
	return fsx.WriteFile(filepath.Join(s.home.SyncDir(), "commands", key+".json"), append(raw, '\n'), 0o600)
}
