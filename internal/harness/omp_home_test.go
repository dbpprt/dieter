package harness

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

type renderedOMPModels struct {
	Providers map[string]struct {
		BaseURL string `yaml:"baseUrl"`
		APIKey  string `yaml:"apiKey"`
	} `yaml:"providers"`
}

func parseOMPModels(t *testing.T, content []byte) renderedOMPModels {
	t.Helper()
	var models renderedOMPModels
	if err := yaml.Unmarshal(content, &models); err != nil {
		t.Fatalf("models.yml does not parse: %v\n%s", err, content)
	}
	return models
}

// OMP runs a `!command` key with /bin/sh. The executable path is quoted for
// the shell, so spaces and quotes in it reach the helper intact.
func TestRenderOMPModelsQuotesTheTokenHelperForTheShell(t *testing.T) {
	t.Parallel()
	dir := filepath.Join(t.TempDir(), "Dieter Apps", "it's \"here\" $HOME")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	helper := filepath.Join(dir, "dieter")
	if err := os.WriteFile(helper, []byte("#!/bin/sh\nprintf '%s|' \"$@\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	content := renderOMPModels(helper, nil)
	if !strings.HasPrefix(string(content), "# Rendered by Dieter") || strings.Contains(string(content), "baseUrl") {
		t.Fatalf("models.yml:\n%s", content)
	}
	models := parseOMPModels(t, content)
	if len(models.Providers) != 2 {
		t.Fatalf("providers = %+v", models.Providers)
	}
	for provider, want := range map[string]string{"anthropic": "claude", "openai-codex": "chatgpt"} {
		key := models.Providers[provider].APIKey
		command, ok := strings.CutPrefix(key, "!")
		if !ok {
			t.Fatalf("%s apiKey %q is not a command", provider, key)
		}
		output, err := exec.Command("/bin/sh", "-c", command).CombinedOutput()
		if err != nil || string(output) != "provider|token|--turn|--provider|"+want+"|" {
			t.Fatalf("%s helper ran as %q: %v", provider, output, err)
		}
	}
}

func TestRenderOMPModelsPointsProvidersAtTestEndpoints(t *testing.T) {
	t.Parallel()
	models := parseOMPModels(t, renderOMPModels("/usr/local/bin/dieter", map[string]string{
		"anthropic": "http://127.0.0.1:9/", "openai-codex": "http://127.0.0.1:9/backend-api", "google": "http://ignored",
	}))
	if len(models.Providers) != 2 || models.Providers["anthropic"].BaseURL != "http://127.0.0.1:9/" || models.Providers["openai-codex"].BaseURL != "http://127.0.0.1:9/backend-api" {
		t.Fatalf("providers = %+v", models.Providers)
	}
	if key := models.Providers["openai-codex"].APIKey; key != "!'/usr/local/bin/dieter' provider token --turn --provider chatgpt" {
		t.Fatalf("Codex apiKey = %q", key)
	}
}

func TestEnsureManagedOMPHomeWritesModelsOnlyWhenTheyChange(t *testing.T) {
	t.Parallel()
	home := t.TempDir()
	if _, err := ensureManagedOMPHome("", "/bin/dieter", nil); err == nil {
		t.Fatal("an OMP home without a Dieter home")
	}
	dir, err := ensureManagedOMPHome(home, "/opt/dieter/bin/dieter", nil)
	if err != nil {
		t.Fatal(err)
	}
	if dir != filepath.Join(home, "omp", "agent") || dir != OMPAgentDir(home) {
		t.Fatalf("agent dir = %q", dir)
	}
	if info, err := os.Stat(dir); err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("agent dir mode = %v, %v", info, err)
	}
	path := filepath.Join(dir, "models.yml")
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("models.yml mode = %v, %v", info, err)
	}
	content, _ := os.ReadFile(path)
	if string(content) != string(renderOMPModels("/opt/dieter/bin/dieter", nil)) {
		t.Fatalf("models.yml:\n%s", content)
	}
	// The same content is left alone: no write, no new modification time.
	past := time.Now().Add(-time.Hour).Truncate(time.Second)
	if err := os.Chtimes(path, past, past); err != nil {
		t.Fatal(err)
	}
	if _, err := ensureManagedOMPHome(home, "/opt/dieter/bin/dieter", nil); err != nil {
		t.Fatal(err)
	}
	if info, _ := os.Stat(path); !info.ModTime().Equal(past) {
		t.Fatalf("an unchanged models.yml was rewritten at %v", info.ModTime())
	}
	// Another executable (an update moved Dieter) or endpoint rewrites it.
	if _, err := ensureManagedOMPHome(home, "/Applications/Dieter.app/Contents/MacOS/dieter", map[string]string{"anthropic": "http://127.0.0.1:9"}); err != nil {
		t.Fatal(err)
	}
	info, _ = os.Stat(path)
	content, _ = os.ReadFile(path)
	if info.ModTime().Equal(past) || info.Mode().Perm() != 0o600 || !strings.Contains(string(content), "/Applications/Dieter.app") || !strings.Contains(string(content), `baseUrl: "http://127.0.0.1:9"`) {
		t.Fatalf("rewritten models.yml (%v, %v):\n%s", info.ModTime(), info.Mode(), content)
	}
	// Without an explicit helper, the running executable answers.
	if _, err := ensureManagedOMPHome(home, "", nil); err != nil {
		t.Fatal(err)
	}
	executable, _ := os.Executable()
	if content, _ := os.ReadFile(path); !strings.Contains(string(content), shellQuote(executable)) {
		t.Fatalf("models.yml without a helper:\n%s", content)
	}
}

func TestOMPHarnessEnvironmentMasksHostCredentialsAndProfiles(t *testing.T) {
	t.Parallel()
	env := Environment{
		Variables: []string{
			"PATH=/usr/bin:/bin", "HOME=/Users/me", "USER=me", "LANG=C.UTF-8",
			"OMP_PROFILE=work", "PI_AGENT_DIR=/Users/me/.pi/agent", "PI_CODING_AGENT_DIR=/Users/me/.omp/agent", "CLAUDE_CONFIG_DIR=/Users/me/.claude-work",
			"ANTHROPIC_API_KEY=sk-ant-host", "ANTHROPIC_AUTH_TOKEN=host", "ANTHROPIC_BASE_URL=https://proxy", "ANTHROPIC_CUSTOM_HEADERS=x: y", "CLAUDE_CODE_OAUTH_TOKEN=oauth",
			"OPENAI_API_KEY=sk-openai", "OPENAI_BASE_URL=https://proxy", "OPENAI_ORG_ID=org", "CODEX_API_KEY=codex", "CODEX_HOME=/Users/me/.codex",
			"AI_GATEWAY_API_KEY=gateway", "VERCEL_OIDC_TOKEN=oidc",
			"DEEPSEEK_API_KEY=deepseek", "PI_CODEX_WEBSOCKET=0", "UNLISTED=secret",
		},
		// A forwarded name of a provider family stays masked too.
		PassThrough: []string{"ANTHROPIC_CUSTOM_HEADERS", "OPENAI_ORG_ID", "PI_CODEX_WEBSOCKET"},
	}
	values := map[string]string{}
	for _, item := range env.ompHarnessEnvironment("/dieter/omp/agent", "/dieter/runtime/tools/bun/bin") {
		name, value, _ := strings.Cut(item, "=")
		if _, seen := values[name]; seen {
			t.Errorf("%s appears twice", name)
		}
		values[name] = value
	}
	for _, name := range []string{
		"OMP_PROFILE", "PI_AGENT_DIR", "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS",
		"CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_ORG_ID", "CODEX_API_KEY", "CODEX_HOME", "AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN", "UNLISTED",
	} {
		if value, ok := values[name]; ok {
			t.Errorf("%s=%q reaches the OMP worker", name, value)
		}
	}
	if values["PI_CODING_AGENT_DIR"] != "/dieter/omp/agent" {
		t.Errorf("PI_CODING_AGENT_DIR=%q", values["PI_CODING_AGENT_DIR"])
	}
	for name, want := range map[string]string{"HOME": "/Users/me", "USER": "me", "LANG": "C.UTF-8", "DEEPSEEK_API_KEY": "deepseek", "PI_CODEX_WEBSOCKET": "0"} {
		if values[name] != want {
			t.Errorf("%s=%q want %q", name, values[name], want)
		}
	}
	if !strings.HasPrefix(values["PATH"], "/dieter/runtime/tools/bun/bin") {
		t.Errorf("PATH=%q does not start with the managed Bun", values["PATH"])
	}
}
