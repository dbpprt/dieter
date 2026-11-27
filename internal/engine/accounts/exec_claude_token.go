package accounts

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// claudeCredentialsService is the Keychain item Claude Code keeps its login
// in on macOS, suffixed with sha256(CLAUDE_CONFIG_DIR)[:8] when one is set.
const claudeCredentialsService = "Claude Code-credentials"

// claudeStoredLogin is the part of Claude Code's credential JSON Oh My Pi
// turns need. The refresh token is deliberately not decoded.
type claudeStoredLogin struct {
	ClaudeAiOauth struct {
		AccessToken string `json:"accessToken"`
		ExpiresAt   int64  `json:"expiresAt"`
	} `json:"claudeAiOauth"`
}

// ClaudeCredentialsService is the Keychain service name of the Claude Code
// login under configDir, named after the exact string Claude Code was given.
func ClaudeCredentialsService(configDir string) string {
	if configDir == "" {
		return claudeCredentialsService
	}
	sum := sha256.Sum256([]byte(configDir))
	return claudeCredentialsService + "-" + hex.EncodeToString(sum[:])[:8]
}

func (b *execBackend) ReadClaudeToken(ctx context.Context, configDir string) (ClaudeToken, error) {
	var raw []byte
	if runtime.GOOS == "darwin" {
		keychain := filepath.Join(b.hostHome, "Library", "Keychains", "login.keychain-db")
		output, err := runCapped(ctx, "/usr/bin/security", []string{"find-generic-password", "-s", ClaudeCredentialsService(configDir), "-w", keychain}, b.baseEnv(), b.hostHome)
		if err != nil {
			return ClaudeToken{}, errors.New("Claude Code has no login in the Keychain for this account")
		}
		raw = output
	} else {
		dir := configDir
		if dir == "" {
			dir = filepath.Join(b.hostHome, ".claude")
		}
		data, err := os.ReadFile(filepath.Join(dir, ".credentials.json"))
		if err != nil {
			return ClaudeToken{}, errors.New("Claude Code has no login file for this account")
		}
		raw = data
	}
	return parseClaudeToken(raw)
}

func parseClaudeToken(raw []byte) (ClaudeToken, error) {
	var stored claudeStoredLogin
	if err := json.Unmarshal([]byte(strings.TrimSpace(string(raw))), &stored); err != nil {
		return ClaudeToken{}, errors.New("Claude Code's login is unreadable")
	}
	login := stored.ClaudeAiOauth
	if login.AccessToken == "" {
		return ClaudeToken{}, errors.New("Claude Code's login has no access token")
	}
	token := ClaudeToken{AccessToken: login.AccessToken}
	if login.ExpiresAt > 0 {
		token.ExpiresAt = time.UnixMilli(login.ExpiresAt)
	}
	return token, nil
}
