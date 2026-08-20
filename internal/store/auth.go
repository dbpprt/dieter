package store

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"time"
)

// AuthState contains hashes and short-lived OAuth transaction metadata. Raw
// Board credentials and GitHub access tokens are never persisted.
type AuthState struct {
	Sessions []AuthSession `json:"sessions,omitempty"`
	Pending  []AuthPending `json:"pending,omitempty"`
	Codes    []AuthCode    `json:"codes,omitempty"`
}

type AuthSession struct {
	TokenHash string    `json:"tokenHash"`
	CSRFHash  string    `json:"csrfHash"`
	GitHubID  int64     `json:"githubId"`
	Login     string    `json:"login"`
	CreatedAt time.Time `json:"createdAt"`
	ExpiresAt time.Time `json:"expiresAt"`
	LastSeen  time.Time `json:"lastSeen"`
}

type AuthPending struct {
	StateHash       string    `json:"stateHash"`
	Verifier        string    `json:"verifier"`
	ReturnTo        string    `json:"returnTo"`
	CreatedAt       time.Time `json:"createdAt"`
	ExpiresAt       time.Time `json:"expiresAt"`
	NativeRedirect  string    `json:"nativeRedirect,omitempty"`
	NativeChallenge string    `json:"nativeChallenge,omitempty"`
}

type AuthCode struct {
	CodeHash  string    `json:"codeHash"`
	Challenge string    `json:"challenge"`
	GitHubID  int64     `json:"githubId"`
	Login     string    `json:"login"`
	ExpiresAt time.Time `json:"expiresAt"`
}

func (s *Store) authStatePath() string { return filepath.Join(s.authDir(), "state.json") }

func (s *Store) LoadAuthState() (AuthState, error) {
	data, err := os.ReadFile(s.authStatePath())
	if errors.Is(err, os.ErrNotExist) {
		return AuthState{}, nil
	}
	if err != nil {
		return AuthState{}, err
	}
	var state AuthState
	if err := json.Unmarshal(data, &state); err != nil {
		return AuthState{}, err
	}
	return state, nil
}

func (s *Store) SaveAuthState(state AuthState) error {
	release, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer release()
	if err := os.MkdirAll(s.authDir(), 0o700); err != nil {
		return err
	}
	if err := os.Chmod(s.authDir(), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	return atomicWriteMode(s.authStatePath(), append(data, '\n'), 0o600)
}
