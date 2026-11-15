package accounts

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// shadowEntries are the parts of ~/.claude every account directory shares by
// symlink: sessions (so a chat can change account between turns), settings,
// instructions, skills, agents, commands and plugins. Credentials, caches and
// .claude.json stay per account.
var shadowEntries = []string{"projects", "settings.json", "CLAUDE.md", "skills", "agents", "commands", "plugins"}

// hostClaudeDir is the operator's Claude Code config directory.
func (s *Service) hostClaudeDir() string {
	if dir := s.opts.Environment["CLAUDE_CONFIG_DIR"]; dir != "" && filepath.IsAbs(dir) {
		return filepath.Clean(dir)
	}
	if s.opts.HostHome == "" {
		return ""
	}
	return filepath.Join(s.opts.HostHome, ".claude")
}

// hostClaudeConfig is the operator's Claude Code global config file, which
// holds the user-scope MCP servers.
func (s *Service) hostClaudeConfig() string {
	if dir := s.opts.Environment["CLAUDE_CONFIG_DIR"]; dir != "" && filepath.IsAbs(dir) {
		return filepath.Join(filepath.Clean(dir), ".claude.json")
	}
	if s.opts.HostHome == "" {
		return ""
	}
	return filepath.Join(s.opts.HostHome, ".claude.json")
}

// hostCodexHome is the operator's own Codex home.
func (s *Service) hostCodexHome() string {
	if dir := s.opts.Environment["CODEX_HOME"]; dir != "" && filepath.IsAbs(dir) {
		return filepath.Clean(dir)
	}
	if s.opts.HostHome == "" {
		return ""
	}
	return filepath.Join(s.opts.HostHome, ".codex")
}

// prepareClaudeHome makes an account's Claude config directory ready for a
// login or a turn: the directory itself, the shadow links to the host's
// shared entries and the mirrored user-scope MCP servers.
func (s *Service) prepareClaudeHome(id string) (string, error) {
	dir := s.claudeDir(id)
	if err := s.ensureShadow(dir); err != nil {
		return "", err
	}
	if err := s.mirrorMCPServers(dir); err != nil {
		return "", err
	}
	return dir, nil
}

// ensureShadow creates dir (0700, never a symlink) and links each shared
// entry that exists on the host. An entry Claude Code created for real is
// left alone; a link whose host target disappeared is removed.
func (s *Service) ensureShadow(dir string) error {
	if info, err := os.Lstat(dir); err == nil && !info.IsDir() {
		return fmt.Errorf("%s is not a directory", dir)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	host := s.hostClaudeDir()
	if host == "" {
		return nil
	}
	for _, name := range shadowEntries {
		target := filepath.Join(host, name)
		link := filepath.Join(dir, name)
		_, targetErr := os.Stat(target)
		info, linkErr := os.Lstat(link)
		switch {
		case linkErr == nil && info.Mode()&os.ModeSymlink == 0:
			continue
		case linkErr == nil:
			current, err := os.Readlink(link)
			if err == nil && current == target && targetErr == nil {
				continue
			}
			if err := os.Remove(link); err != nil {
				return err
			}
		case !errors.Is(linkErr, fs.ErrNotExist):
			return linkErr
		}
		if targetErr != nil {
			continue
		}
		if err := os.Symlink(target, link); err != nil && !errors.Is(err, fs.ErrExist) {
			return err
		}
	}
	return nil
}

// mirrorMCPServers copies the host's user-scope mcpServers into the account's
// .claude.json, changing only that key and writing only on a change.
func (s *Service) mirrorMCPServers(dir string) error {
	var servers json.RawMessage
	if source := s.hostClaudeConfig(); source != "" {
		raw, err := os.ReadFile(source)
		switch {
		case err == nil:
			var host map[string]json.RawMessage
			if json.Unmarshal(raw, &host) == nil {
				servers = host["mcpServers"]
			}
		case !errors.Is(err, fs.ErrNotExist):
			return err
		}
	}
	path := filepath.Join(dir, ".claude.json")
	account := map[string]json.RawMessage{}
	raw, err := os.ReadFile(path)
	switch {
	case err == nil:
		if json.Unmarshal(raw, &account) != nil {
			// Claude Code owns this file; never replace one it may be writing.
			return nil
		}
	case !errors.Is(err, fs.ErrNotExist):
		return err
	}
	current, had := account["mcpServers"]
	if len(servers) == 0 || string(servers) == "null" {
		if !had {
			return nil
		}
		delete(account, "mcpServers")
	} else {
		if had && jsonEqual(current, servers) {
			return nil
		}
		account["mcpServers"] = servers
	}
	next, err := json.MarshalIndent(account, "", "  ")
	if err != nil {
		return err
	}
	return s.writePrivate(path, append(next, '\n'))
}

func jsonEqual(a, b json.RawMessage) bool {
	var left, right any
	if json.Unmarshal(a, &left) != nil || json.Unmarshal(b, &right) != nil {
		return bytes.Equal(a, b)
	}
	l, _ := json.Marshal(left)
	r, _ := json.Marshal(right)
	return bytes.Equal(l, r)
}

// removeAccountDir deletes an account's local directory. Shadow links are
// unlinked first and nothing is ever followed through a link, so the host's
// shared ~/.claude entries survive.
func (s *Service) removeAccountDir(id string) error {
	dir := s.accountDir(id)
	if filepath.Dir(dir) != s.store.ProviderAccountsDir() {
		return fmt.Errorf("refusing to remove %s outside the provider accounts directory", dir)
	}
	info, err := os.Lstat(dir)
	if errors.Is(err, fs.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return os.Remove(dir)
	}
	release, err := s.store.BeginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	if err := unlinkSymlinks(dir); err != nil {
		return err
	}
	return os.RemoveAll(dir)
}

// unlinkSymlinks removes every symlink below dir without following any.
func unlinkSymlinks(dir string) error {
	return filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			if errors.Is(err, fs.ErrNotExist) {
				return nil
			}
			return err
		}
		if entry.Type()&fs.ModeSymlink != 0 {
			return os.Remove(path)
		}
		return nil
	})
}

// codexProviderBlock declares the bridge's provider globally. Without it,
// Codex refuses a thread that uses agent_bridge_openai while the configured
// provider is openai (proposal P0.4).
const codexProviderBlock = `
[model_providers.agent_bridge_openai]
name = "Agent Bridge OpenAI"
base_url = "https://chatgpt.com/backend-api/codex"
env_key = "CODEX_API_KEY"
wire_api = "responses"
supports_websockets = false
`

const codexConfigHeader = "# Rendered by Dieter from the host's Codex config.toml; edits here are replaced.\n" +
	"model_provider = \"agent_bridge_openai\"\n"

// renderCodexHome writes DIETER_HOME/codex/config.toml: the host's Codex
// config.toml (MCP servers, features, trust) without its top-level
// model_provider and its agent_bridge_openai provider, plus Dieter's
// provider block. It rewrites only when the source or the output changed.
func (s *Service) renderCodexHome() error {
	s.renderMu.Lock()
	defer s.renderMu.Unlock()
	target := filepath.Join(s.CodexHome(), "config.toml")
	var source []byte
	stamp := "none"
	if home := s.hostCodexHome(); home != "" {
		path := filepath.Join(home, "config.toml")
		info, err := os.Stat(path)
		switch {
		case err == nil:
			stamp = fmt.Sprintf("%s|%d|%d", path, info.Size(), info.ModTime().UnixNano())
			if source, err = os.ReadFile(path); err != nil {
				return err
			}
		case !errors.Is(err, fs.ErrNotExist):
			return err
		}
	}
	if stamp == s.renderedFrom {
		if _, err := os.Stat(target); err == nil {
			return nil
		}
	}
	rendered := renderCodexConfig(source)
	if current, err := os.ReadFile(target); err == nil && bytes.Equal(current, rendered) {
		s.renderedFrom = stamp
		return nil
	}
	if err := os.MkdirAll(s.CodexHome(), 0o700); err != nil {
		return err
	}
	if err := s.writePrivate(target, rendered); err != nil {
		return err
	}
	s.renderedFrom = stamp
	return nil
}

// renderCodexConfig edits TOML by lines, without a TOML dependency: drop
// top-level model_provider assignments (before the first table header) and
// every [model_providers.agent_bridge_openai] table and subtable, then
// declare Dieter's provider. Multi-line strings are skipped intact.
func renderCodexConfig(source []byte) []byte {
	var out strings.Builder
	out.WriteString(codexConfigHeader)
	inTable, dropping := false, false
	multiline := ""
	for _, line := range strings.SplitAfter(string(source), "\n") {
		if line == "" {
			continue
		}
		trimmed := strings.TrimSpace(line)
		if multiline != "" {
			if strings.Count(line, multiline)%2 == 1 {
				multiline = ""
			}
			if !dropping {
				out.WriteString(line)
			}
			continue
		}
		if strings.HasPrefix(trimmed, "[") {
			inTable = true
			dropping = bridgeTable(trimmed)
		} else if !inTable && topLevelKey(trimmed) == "model_provider" {
			continue
		}
		for _, quote := range []string{`"""`, `'''`} {
			if strings.Count(line, quote)%2 == 1 {
				multiline = quote
				break
			}
		}
		if dropping {
			continue
		}
		out.WriteString(line)
	}
	text := out.String()
	if !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	return []byte(text + codexProviderBlock)
}

// bridgeTable reports whether a table header names agent_bridge_openai's
// provider table or one of its subtables.
func bridgeTable(header string) bool {
	name := strings.TrimSpace(strings.Trim(strings.SplitN(header, "#", 2)[0], " \t[]"))
	parts := strings.Split(name, ".")
	if len(parts) < 2 {
		return false
	}
	for i := range parts {
		parts[i] = strings.Trim(strings.TrimSpace(parts[i]), `"'`)
	}
	return parts[0] == "model_providers" && parts[1] == "agent_bridge_openai"
}

// topLevelKey is the bare key a line assigns, or "".
func topLevelKey(line string) string {
	key, _, found := strings.Cut(line, "=")
	if !found || strings.HasPrefix(line, "#") {
		return ""
	}
	return strings.Trim(strings.TrimSpace(key), `"'`)
}
