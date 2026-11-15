//go:build unix

package accounts

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	must(t, os.MkdirAll(filepath.Dir(path), 0o700))
	must(t, os.WriteFile(path, []byte(content), 0o600))
}

func TestShadowClaudeHomeLinksSharedEntries(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	host := filepath.Join(h.home, ".claude")
	must(t, os.MkdirAll(filepath.Join(host, "projects", "p"), 0o700))
	must(t, os.MkdirAll(filepath.Join(host, "skills"), 0o700))
	writeFile(t, filepath.Join(host, "settings.json"), `{"theme":"dark"}`)
	work := h.create(t, ProviderClaude, "Work", "")
	dir, err := h.svc.prepareClaudeHome(work.ID)
	if err != nil {
		t.Fatal(err)
	}
	if dir != filepath.Join(h.store.Root, "provider-accounts", work.ID, "claude") || dir != filepath.Clean(dir) {
		t.Fatalf("dir = %q", dir)
	}
	if info, err := os.Lstat(dir); err != nil || !info.IsDir() || info.Mode().Perm() != 0o700 {
		t.Fatalf("dir mode = %v, %v", info, err)
	}
	for _, name := range []string{"projects", "skills", "settings.json"} {
		target, err := os.Readlink(filepath.Join(dir, name))
		if err != nil || target != filepath.Join(host, name) {
			t.Errorf("%s -> %q, %v", name, target, err)
		}
	}
	for _, name := range []string{"CLAUDE.md", "agents", "commands", "plugins"} {
		if _, err := os.Lstat(filepath.Join(dir, name)); !os.IsNotExist(err) {
			t.Errorf("%s linked although the host has none: %v", name, err)
		}
	}
	// Claude Code created its own plugins directory; the host gains agents.
	must(t, os.MkdirAll(filepath.Join(dir, "plugins"), 0o700))
	must(t, os.MkdirAll(filepath.Join(host, "plugins"), 0o700))
	must(t, os.MkdirAll(filepath.Join(host, "agents"), 0o700))
	must(t, os.RemoveAll(filepath.Join(host, "skills")))
	if _, err := h.svc.prepareClaudeHome(work.ID); err != nil {
		t.Fatal(err)
	}
	if info, _ := os.Lstat(filepath.Join(dir, "plugins")); info.Mode()&os.ModeSymlink != 0 {
		t.Fatal("a real plugins directory was replaced")
	}
	if _, err := os.Readlink(filepath.Join(dir, "agents")); err != nil {
		t.Fatalf("new host entry not linked: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(dir, "skills")); !os.IsNotExist(err) {
		t.Fatalf("dangling link kept: %v", err)
	}
}

func TestMCPServersAreMirroredAlone(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	writeFile(t, filepath.Join(h.home, ".claude.json"), `{"oauthAccount":{"emailAddress":"host@example.com"},"mcpServers":{"docs":{"command":"docs-mcp"}},"projects":{}}`)
	work := h.create(t, ProviderClaude, "Work", "")
	dir := h.svc.claudeDir(work.ID)
	writeFile(t, filepath.Join(dir, ".claude.json"), `{"userID":"u1","oauthAccount":{"emailAddress":"work@example.com"}}`)
	if _, err := h.svc.prepareClaudeHome(work.ID); err != nil {
		t.Fatal(err)
	}
	read := func() map[string]json.RawMessage {
		raw, err := os.ReadFile(filepath.Join(dir, ".claude.json"))
		if err != nil {
			t.Fatal(err)
		}
		var config map[string]json.RawMessage
		must(t, json.Unmarshal(raw, &config))
		return config
	}
	config := read()
	if string(config["userID"]) != `"u1"` || !strings.Contains(string(config["oauthAccount"]), "work@example.com") || !strings.Contains(string(config["mcpServers"]), "docs-mcp") || config["projects"] != nil {
		t.Fatalf("account config = %s", config)
	}
	info, _ := os.Stat(filepath.Join(dir, ".claude.json"))
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", info.Mode())
	}
	// Unchanged servers are not rewritten.
	before := info.ModTime()
	time.Sleep(20 * time.Millisecond)
	if _, err := h.svc.prepareClaudeHome(work.ID); err != nil {
		t.Fatal(err)
	}
	if after, _ := os.Stat(filepath.Join(dir, ".claude.json")); !after.ModTime().Equal(before) {
		t.Fatal("unchanged mcpServers rewritten")
	}
	// Removing the host's servers removes them from the account.
	writeFile(t, filepath.Join(h.home, ".claude.json"), `{"projects":{}}`)
	if _, err := h.svc.prepareClaudeHome(work.ID); err != nil {
		t.Fatal(err)
	}
	if config := read(); config["mcpServers"] != nil || string(config["userID"]) != `"u1"` {
		t.Fatalf("after removal = %s", config)
	}
}

func TestRemovingAnAccountNeverFollowsLinks(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	host := filepath.Join(h.home, ".claude")
	writeFile(t, filepath.Join(host, "projects", "p", "session.jsonl"), "transcript")
	writeFile(t, filepath.Join(host, "settings.json"), "{}")
	outside := t.TempDir()
	writeFile(t, filepath.Join(outside, "keep.txt"), "keep")
	work := h.create(t, ProviderClaude, "Work", "")
	dir, err := h.svc.prepareClaudeHome(work.ID)
	if err != nil {
		t.Fatal(err)
	}
	// A nested link inside a real directory, too.
	must(t, os.MkdirAll(filepath.Join(dir, "cache"), 0o700))
	must(t, os.Symlink(outside, filepath.Join(dir, "cache", "outside")))
	must(t, h.svc.removeAccountDir(work.ID))
	if _, err := os.Stat(h.svc.accountDir(work.ID)); !os.IsNotExist(err) {
		t.Fatalf("account dir survived: %v", err)
	}
	for _, path := range []string{filepath.Join(host, "projects", "p", "session.jsonl"), filepath.Join(host, "settings.json"), filepath.Join(outside, "keep.txt")} {
		if _, err := os.Stat(path); err != nil {
			t.Errorf("shared entry removed: %s: %v", path, err)
		}
	}
	must(t, h.svc.removeAccountDir(work.ID))
}

func TestCodexConfigRendersTheHostConfigWithDieterProvider(t *testing.T) {
	t.Parallel()
	h := newHarness(t, "d_one")
	source := filepath.Join(h.home, ".codex", "config.toml")
	writeFile(t, source, `model = "gpt-5.5"
model_provider = "openai"
notes = """
[model_providers.agent_bridge_openai]
kept inside a string
"""

[mcp_servers.docs]
command = "docs-mcp"
model_provider = "kept, not top level"

[model_providers.agent_bridge_openai]
name = "stale"
base_url = "https://example.invalid"

[model_providers."agent_bridge_openai".auth]
command = "stale"

[projects."/Users/me/code"]
trust_level = "trusted"
`)
	must(t, h.svc.renderCodexHome())
	target := filepath.Join(h.svc.CodexHome(), "config.toml")
	raw, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	text := string(raw)
	for _, want := range []string{`model = "gpt-5.5"`, "kept inside a string", `[mcp_servers.docs]`, `model_provider = "kept, not top level"`, `trust_level = "trusted"`,
		"model_provider = \"agent_bridge_openai\"\n", "[model_providers.agent_bridge_openai]\nname = \"Agent Bridge OpenAI\"", `base_url = "https://chatgpt.com/backend-api/codex"`, `env_key = "CODEX_API_KEY"`, `wire_api = "responses"`, "supports_websockets = false"} {
		if !strings.Contains(text, want) {
			t.Errorf("rendered config lacks %q:\n%s", want, text)
		}
	}
	for _, unwanted := range []string{`model_provider = "openai"`, `name = "stale"`, "example.invalid", `command = "stale"`} {
		if strings.Contains(text, unwanted) {
			t.Errorf("rendered config keeps %q:\n%s", unwanted, text)
		}
	}
	if strings.Count(text, "[model_providers.agent_bridge_openai]\n") != 2 {
		// One inside the kept string, one Dieter block.
		t.Errorf("provider tables:\n%s", text)
	}
	if strings.Index(text, `model_provider = "agent_bridge_openai"`) > strings.Index(text, "[") {
		t.Error("model_provider is not a top-level key")
	}
	info, _ := os.Stat(target)
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", info.Mode())
	}
	// No source change, no rewrite.
	before := info.ModTime()
	time.Sleep(20 * time.Millisecond)
	must(t, h.svc.renderCodexHome())
	if after, _ := os.Stat(target); !after.ModTime().Equal(before) {
		t.Fatal("unchanged source re-rendered")
	}
	writeFile(t, source, "model = \"gpt-6\"\n")
	must(t, h.svc.renderCodexHome())
	raw, _ = os.ReadFile(target)
	if !strings.Contains(string(raw), `model = "gpt-6"`) || strings.Contains(string(raw), "gpt-5.5") {
		t.Fatalf("re-render = %s", raw)
	}
	// Without a host config only Dieter's provider is declared.
	must(t, os.Remove(source))
	must(t, h.svc.renderCodexHome())
	raw, _ = os.ReadFile(target)
	if strings.Contains(string(raw), "gpt-6") || !strings.Contains(string(raw), "agent_bridge_openai") {
		t.Fatalf("render without source = %s", raw)
	}
}
