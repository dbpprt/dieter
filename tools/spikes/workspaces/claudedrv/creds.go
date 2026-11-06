package claudedrv

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

// MinRemaining is how long an access token must stay valid for a turn to
// start with it.
const MinRemaining = 15 * time.Minute

// RefreshDir is the empty scratch directory the operator's real CLI runs in
// when RefreshRealToken asks it to refresh its own OAuth chain.
var RefreshDir = "/Volumes/External/dieter-spike/claudedrv-dev/refresh"

type credentialFile struct {
	ClaudeAiOauth *struct {
		AccessToken string `json:"accessToken"`
		ExpiresAt   int64  `json:"expiresAt"` // ms since epoch
	} `json:"claudeAiOauth"`
}

// AccessToken returns the short-lived OAuth access token and its expiry.
// With credFile == "" it reads the macOS keychain item "Claude Code-credentials"
// on darwin and $HOME/.claude/.credentials.json elsewhere. Only the access
// token leaves this function; the refresh token is never returned or copied.
// A zero expiry means the source did not state one.
func AccessToken(credFile string) (string, time.Time, error) {
	var raw []byte
	var err error
	switch {
	case credFile == "" && runtime.GOOS == "darwin":
		raw, err = keychainCredentials()
	default:
		if credFile == "" {
			home, herr := os.UserHomeDir()
			if herr != nil {
				return "", time.Time{}, herr
			}
			credFile = filepath.Join(home, ".claude", ".credentials.json")
		}
		raw, err = os.ReadFile(credFile)
	}
	if err != nil {
		return "", time.Time{}, err
	}
	var c credentialFile
	if err := json.Unmarshal(bytes.TrimSpace(raw), &c); err != nil {
		// json errors quote at most a character of input, never the token.
		return "", time.Time{}, fmt.Errorf("credentials: %v", err)
	}
	if c.ClaudeAiOauth == nil || c.ClaudeAiOauth.AccessToken == "" {
		return "", time.Time{}, errors.New("credentials: no claudeAiOauth.accessToken")
	}
	var exp time.Time
	if c.ClaudeAiOauth.ExpiresAt > 0 {
		exp = time.UnixMilli(c.ClaudeAiOauth.ExpiresAt)
	}
	return c.ClaudeAiOauth.AccessToken, exp, nil
}

func keychainCredentials() ([]byte, error) {
	u, err := user.Current()
	if err != nil {
		return nil, err
	}
	// perl's alarm bounds a keychain call that would otherwise block on a
	// locked keychain or an access prompt.
	cmd := exec.Command("perl", "-e", "alarm 25; exec @ARGV",
		"security", "find-generic-password", "-s", "Claude Code-credentials", "-a", u.Username, "-w")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("keychain: %v: %s", err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

// RefreshRealToken runs the operator's own Claude Code CLI once, with its own
// configuration, so that it refreshes its OAuth chain in the keychain. This
// process never touches the refresh token itself.
func RefreshRealToken(ctx context.Context) error {
	if err := os.MkdirAll(RefreshDir, 0o700); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, "claude", "-p", "Reply with OK",
		"--model", "claude-haiku-5-5", "--no-session-persistence", "--setting-sources", "")
	cmd.Dir = RefreshDir
	cmd.Env = scrubEnv(os.Environ())
	cmd.Stdin = strings.NewReader("")
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	cmd.WaitDelay = 5 * time.Second
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("refresh via claude CLI: %v: %s", err, tail(out.String(), 400))
	}
	return nil
}

// freshToken reads the access token right before a turn and, on darwin with
// the keychain as source, lets the real CLI refresh it when it is about to
// expire.
func freshToken(ctx context.Context, credFile string) (string, time.Time, bool, error) {
	tok, exp, err := AccessToken(credFile)
	if err != nil {
		return "", time.Time{}, false, err
	}
	if exp.IsZero() || time.Until(exp) >= MinRemaining {
		return tok, exp, false, nil
	}
	if runtime.GOOS != "darwin" || credFile != "" {
		return "", time.Time{}, false, fmt.Errorf("access token expires in %s (< %s); refresh the credentials", time.Until(exp).Round(time.Second), MinRemaining)
	}
	if err := RefreshRealToken(ctx); err != nil {
		return "", time.Time{}, true, err
	}
	tok, exp, err = AccessToken(credFile)
	if err != nil {
		return "", time.Time{}, true, err
	}
	if !exp.IsZero() && time.Until(exp) < MinRemaining {
		return "", time.Time{}, true, fmt.Errorf("access token still expires in %s after a CLI refresh", time.Until(exp).Round(time.Second))
	}
	return tok, exp, true, nil
}

// scrubEnv drops every variable that would point a child Claude Code at
// Dieter, at an API key, at another configuration or at the parent Claude
// Code session this spike may run under.
func scrubEnv(env []string) []string {
	out := env[:0:0]
	for _, kv := range env {
		k, _, _ := strings.Cut(kv, "=")
		switch {
		case strings.HasPrefix(k, "DIETER_"),
			strings.HasPrefix(k, "ANTHROPIC_"),
			strings.HasPrefix(k, "CLAUDE_CODE_"),
			strings.HasPrefix(k, "CLAUDE_AGENT_SDK_"),
			k == "CLAUDECODE", k == "CLAUDE_CONFIG_DIR", k == "CLAUDE_EFFORT", k == "CLAUDE_PID":
			continue
		}
		out = append(out, kv)
	}
	return out
}

func tail(s string, n int) string {
	s = strings.TrimSpace(s)
	if len(s) > n {
		return "…" + s[len(s)-n:]
	}
	return s
}
