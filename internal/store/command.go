package store

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

type CommandResult struct {
	Kind      string `json:"kind"`
	CardID    string `json:"cardId,omitempty"`
	MessageID string `json:"messageId,omitempty"`
	Sent      bool   `json:"sent,omitempty"`
	Queued    bool   `json:"queued,omitempty"`
}

func commandKey(clientID, commandID string) (string, error) {
	clientID, commandID = strings.TrimSpace(clientID), strings.TrimSpace(commandID)
	if clientID == "" || commandID == "" || len(clientID) > 200 || len(commandID) > 200 {
		return "", errors.New("client_id and command_id are required and must be at most 200 characters")
	}
	digest := sha256.Sum256([]byte(clientID + "\x00" + commandID))
	return hex.EncodeToString(digest[:]), nil
}

func DeterministicCommandID(prefix, clientID, commandID string) (string, error) {
	key, err := commandKey(clientID, commandID)
	if err != nil {
		return "", err
	}
	return prefix + key[:24], nil
}

func (s *Store) LoadCommandResult(clientID, commandID string) (CommandResult, bool, error) {
	key, err := commandKey(clientID, commandID)
	if err != nil {
		return CommandResult{}, false, err
	}
	raw, err := os.ReadFile(filepath.Join(s.syncDir(), "commands", key+".json"))
	if errors.Is(err, os.ErrNotExist) {
		return CommandResult{}, false, nil
	}
	if err != nil {
		return CommandResult{}, false, err
	}
	var result CommandResult
	if err := json.Unmarshal(raw, &result); err != nil {
		return CommandResult{}, false, err
	}
	return result, true, nil
}

func (s *Store) SaveCommandResult(clientID, commandID string, result CommandResult) error {
	key, err := commandKey(clientID, commandID)
	if err != nil {
		return err
	}
	release, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer release()
	raw, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return err
	}
	return atomicWriteMode(filepath.Join(s.syncDir(), "commands", key+".json"), append(raw, '\n'), 0o600)
}
