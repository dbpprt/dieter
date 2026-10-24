package codexdrv

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// NeuteredRefreshToken replaces the refresh token in every copied auth.json,
// so a spike CODEX_HOME can never rotate or fork the operator's refresh chain.
const NeuteredRefreshToken = "spike-no-refresh"

// DefaultEffort is the reasoning effort used when Config.Effort is empty.
const DefaultEffort = "low"

// MinTokenLifetime is how long the copied access token must remain valid.
// Codex 0.163 refreshes proactively only minutes before expiry, so a token
// with this much headroom is never refreshed during a spike run.
const MinTokenLifetime = 2 * time.Hour

// OperatorCodexHome is the operator's Codex home. It is only ever read.
func OperatorCodexHome() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".codex"), nil
}

// PrepareHome creates dst as a temporary CODEX_HOME holding a copy of the
// operator's ~/.codex/auth.json (refresh token neutered) and a minimal
// config.toml with the default model and effort. ~/.codex is never written.
func PrepareHome(dst string) error {
	src, err := OperatorCodexHome()
	if err != nil {
		return err
	}
	return PrepareHomeFromFile(dst, filepath.Join(src, "auth.json"))
}

// PrepareHomeFromFile is PrepareHome with an explicit source auth.json (for
// example a pre-neutered copy shipped to a Linux host).
func PrepareHomeFromFile(dst, authJSONPath string) error {
	raw, err := os.ReadFile(authJSONPath)
	if err != nil {
		return fmt.Errorf("read auth source: %w", err)
	}
	out, err := neuterAuth(raw, time.Now())
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dst, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(dst, 0o700); err != nil {
		return err
	}
	if err := writeFileAtomic(filepath.Join(dst, "auth.json"), out, 0o600); err != nil {
		return err
	}
	model, _ := DefaultModel() // a home without a model is still usable when Config.Model is set
	return writeConfig(dst, model, DefaultEffort)
}

// neuterAuth returns auth.json content with tokens.refresh_token replaced and
// everything else kept. It refuses access tokens that expire within
// MinTokenLifetime of now. Errors never contain token material.
func neuterAuth(raw []byte, now time.Time) ([]byte, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var auth map[string]any
	if err := dec.Decode(&auth); err != nil {
		return nil, errors.New("auth source is not a JSON object")
	}
	tokens, ok := auth["tokens"].(map[string]any)
	if !ok {
		return nil, errors.New("auth source has no ChatGPT tokens object")
	}
	access, _ := tokens["access_token"].(string)
	if access == "" {
		return nil, errors.New("auth source has no tokens.access_token")
	}
	exp, err := jwtExpiry(access)
	if err != nil {
		return nil, fmt.Errorf("access token: %w", err)
	}
	if left := exp.Sub(now); left < MinTokenLifetime {
		return nil, fmt.Errorf("access token expires in %s (< %s); refresh it with the real Codex first", left.Round(time.Minute), MinTokenLifetime)
	}
	tokens["refresh_token"] = NeuteredRefreshToken
	out, err := json.MarshalIndent(auth, "", "  ")
	if err != nil {
		return nil, errors.New("encode auth copy")
	}
	return append(out, '\n'), nil
}

// jwtExpiry decodes the exp claim of a JWT without verifying it.
func jwtExpiry(token string) (time.Time, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return time.Time{}, errors.New("not a JWT")
	}
	payload, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil {
		return time.Time{}, errors.New("JWT payload is not base64url")
	}
	var claims struct {
		Exp json.Number `json:"exp"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil || claims.Exp == "" {
		return time.Time{}, errors.New("JWT has no exp claim")
	}
	f, err := claims.Exp.Float64()
	if err != nil {
		return time.Time{}, errors.New("JWT exp is not a number")
	}
	return time.Unix(int64(f), 0), nil
}

var (
	tomlTable      = regexp.MustCompile(`^\s*\[`)
	tomlModelKey   = regexp.MustCompile(`^\s*model\s*=\s*(?:"([^"]*)"|'([^']*)')\s*(?:#.*)?$`)
	safeTOMLString = regexp.MustCompile(`^[A-Za-z0-9._:/+-]+$`)
)

// DefaultModel reads the top-level model key of the operator's
// ~/.codex/config.toml (read-only).
func DefaultModel() (string, error) {
	home, err := OperatorCodexHome()
	if err != nil {
		return "", err
	}
	f, err := os.Open(filepath.Join(home, "config.toml"))
	if err != nil {
		return "", err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		if tomlTable.MatchString(line) {
			break // only top-level keys
		}
		if m := tomlModelKey.FindStringSubmatch(line); m != nil {
			return m[1] + m[2], nil
		}
	}
	if err := sc.Err(); err != nil {
		return "", err
	}
	return "", errors.New("no top-level model in ~/.codex/config.toml")
}

// writeConfig writes the spike config.toml: model, effort, and file-based
// credential storage (Codex must read the copied auth.json and never consult
// the OS keychain, which could prompt interactively). Keys were checked
// against codex 0.163 with --strict-config.
func writeConfig(home, model, effort string) error {
	var b strings.Builder
	for _, kv := range [][2]string{{"model", model}, {"model_reasoning_effort", effort}, {"cli_auth_credentials_store", "file"}} {
		if kv[1] == "" {
			continue
		}
		if !safeTOMLString.MatchString(kv[1]) {
			return fmt.Errorf("refusing unusual %s value %q", kv[0], kv[1])
		}
		fmt.Fprintf(&b, "%s = %q\n", kv[0], kv[1])
	}
	return writeFileAtomic(filepath.Join(home, "config.toml"), []byte(b.String()), 0o600)
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if err := tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}

// homeSecrets returns the token strings of home/auth.json, for redaction.
func homeSecrets(home string) []string {
	raw, err := os.ReadFile(filepath.Join(home, "auth.json"))
	if err != nil {
		return nil
	}
	var auth struct {
		APIKey string         `json:"OPENAI_API_KEY"`
		Tokens map[string]any `json:"tokens"`
	}
	if json.Unmarshal(raw, &auth) != nil {
		return nil
	}
	var out []string
	if len(auth.APIKey) >= 16 {
		out = append(out, auth.APIKey)
	}
	for k, v := range auth.Tokens {
		if s, ok := v.(string); ok && len(s) >= 16 && k != "account_id" {
			out = append(out, s)
		}
	}
	return out
}
