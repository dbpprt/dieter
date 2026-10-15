package settings

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/dbpprt/dieter/internal/store/home"
)

// ClaudeDesignAccess records whether Claude Code turns on this machine may use
// Claude Design. It is deliberately outside the replicated peer store: the
// claude.ai login, the design credential and the agent-access grant belong to
// this host's Claude account.
type ClaudeDesignAccess struct {
	Enabled   bool   `json:"enabled"`
	UpdatedAt string `json:"updatedAt,omitempty"`
}

func (s *Store) claudeDesignAccessPath() string {
	return filepath.Join(s.home.RuntimeDir(), "claude-design.json")
}

func (s *Store) ClaudeDesignAccess() (ClaudeDesignAccess, error) {
	var value ClaudeDesignAccess
	raw, err := os.ReadFile(s.claudeDesignAccessPath())
	if errors.Is(err, os.ErrNotExist) {
		return value, nil
	}
	if err != nil {
		return value, err
	}
	err = json.Unmarshal(raw, &value)
	return value, err
}

func (s *Store) SetClaudeDesignAccess(enabled bool) (ClaudeDesignAccess, error) {
	release, err := s.home.BeginWrite()
	if err != nil {
		return ClaudeDesignAccess{}, err
	}
	defer release()
	value := ClaudeDesignAccess{Enabled: enabled, UpdatedAt: home.Timestamp()}
	return value, home.WriteJSON(s.claudeDesignAccessPath(), value)
}
