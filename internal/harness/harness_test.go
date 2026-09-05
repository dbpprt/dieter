package harness

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestCancelRejectsUnverifiableLegacyWorkerPID(t *testing.T) {
	runtimeRoot := t.TempDir()
	workerFile := filepath.Join(runtimeRoot, ".dieter-worker-card.pid")
	if err := os.WriteFile(workerFile, []byte("999999\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runner := NewSubprocessRunner(t.TempDir())
	if err := runner.Cancel("card", runtimeRoot); !errors.Is(err, ErrNoActiveTurn) {
		t.Fatalf("cancel error=%v", err)
	}
	if _, err := os.Stat(workerFile); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("legacy worker record still exists: %v", err)
	}
}

func TestEmbeddedRuntimeAssets(t *testing.T) {
	destination := t.TempDir()
	if err := stageRuntimeAssets(destination); err != nil {
		t.Fatal(err)
	}
	entries, err := runtimeAssets.ReadDir("runtime")
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := "runtime/" + entry.Name()
		data, err := runtimeAssets.ReadFile(name)
		if err != nil || len(data) == 0 {
			t.Fatalf("asset %s: %v", name, err)
		}
		staged, err := os.ReadFile(filepath.Join(destination, filepath.Base(name)))
		if err != nil {
			t.Fatalf("staged asset %s: %v", name, err)
		}
		if !bytes.Equal(staged, data) {
			t.Fatalf("staged asset %s does not match its embedded source", name)
		}
	}
	var manifest map[string]any
	data, _ := runtimeAssets.ReadFile("runtime/package.json")
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatal(err)
	}
}

func TestEmbeddedRuntimeContainsLocalModuleClosure(t *testing.T) {
	imports := regexp.MustCompile(`(?:from\s+|import\s*\()\s*['"](\./[^'"]+)['"]`)
	queue := []string{"runtime/runner.mjs", "runtime/dsh-discovery.mjs"}
	seen := map[string]bool{}
	for len(queue) > 0 {
		name := queue[0]
		queue = queue[1:]
		if seen[name] {
			continue
		}
		seen[name] = true
		data, err := runtimeAssets.ReadFile(name)
		if err != nil {
			t.Fatalf("embedded runtime dependency %s: %v", name, err)
		}
		for _, match := range imports.FindAllSubmatch(data, -1) {
			dependency := path.Clean(path.Join(path.Dir(name), string(match[1])))
			if path.Ext(dependency) == "" {
				dependency += ".mjs"
			}
			if _, err := fs.Stat(runtimeAssets, dependency); err != nil {
				t.Errorf("%s imports unstaged local module %s: %v", name, dependency, err)
				continue
			}
			queue = append(queue, dependency)
		}
	}
}

func TestCatalogIncludesEverySupportedHarness(t *testing.T) {
	if got := len(Catalog(false)); got != 5 {
		t.Fatalf("catalog has %d harnesses, want 5", got)
	}
	for _, id := range []string{"codex", "claude-code", "pi", "omp", "dsh"} {
		adapter, found := ResolveAdapter(id, false)
		if !found || adapter.DefaultModel == "" || len(adapter.Models) == 0 {
			t.Errorf("harness %q is incomplete: %#v", id, adapter)
		}
		if !hasCapability(adapter, "task-plan") {
			t.Errorf("harness %q does not advertise task plans: %#v", id, adapter.Capabilities)
		}
	}
}

func TestCatalogIncludesDeepSeekHarnessACPWithConfiguredDefaultFallback(t *testing.T) {
	adapter, valid := ResolveAdapter("dsh", false)
	if !valid || adapter.Runtime != "dsh-acp" || adapter.DefaultModel != "default" || len(adapter.Models) != 1 {
		t.Fatalf("dsh catalog=%#v valid=%v", adapter, valid)
	}
	model := adapter.Models[0]
	if model.ID != "default" || model.RuntimeModel == nil || *model.RuntimeModel != "" {
		t.Fatalf("dsh models=%#v", adapter.Models)
	}
	if adapter.Effort != nil {
		t.Fatalf("dsh effort=%#v", adapter.Effort)
	}
}

func hasCapability(adapter Adapter, id string) bool {
	for _, capability := range adapter.Capabilities {
		if capability.ID == id {
			return true
		}
	}
	return false
}

func TestCatalogIncludesCurrentCodexRegistry(t *testing.T) {
	codex, found := ResolveAdapter("codex", false)
	if !found {
		t.Fatal("codex harness is missing")
	}
	if codex.DefaultModel != "gpt-5.6-sol" || len(codex.Models) != 7 {
		t.Fatalf("codex catalog=%#v", codex)
	}
	want := []string{"gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.3-codex", "gpt-5.3-codex-spark"}
	for index, id := range want {
		if codex.Models[index].ID != id {
			t.Fatalf("model %d=%q want %q", index, codex.Models[index].ID, id)
		}
	}
	if codex.Effort == nil || codex.Effort.Label != "Reasoning" || len(codex.Effort.Options) != 3 || codex.Models[0].DefaultEffort != "low" {
		t.Fatalf("codex effort catalog=%#v", codex)
	}
}

func TestConfiguredEffortValidationIsProviderAndModelAware(t *testing.T) {
	codex, sol, err := ResolveSelection("codex", "gpt-5.6-sol", false)
	if err != nil {
		t.Fatal(err)
	}
	if effort, err := ResolveEffort(codex, sol, "high"); err != nil || effort != "high" {
		t.Fatalf("codex high effort=%q err=%v", effort, err)
	}
	if _, err := ResolveEffort(codex, sol, "xhigh"); err == nil || !strings.Contains(err.Error(), "not supported") {
		t.Fatalf("codex xhigh err=%v", err)
	}
	if _, err := ResolveEffort(codex, sol, "max"); err == nil || !strings.Contains(err.Error(), "not supported") {
		t.Fatalf("codex max err=%v", err)
	}
	claude, sonnet, err := ResolveSelection("claude-code", "claude-sonnet-4-5", false)
	if err != nil {
		t.Fatal(err)
	}
	if effort, err := ResolveEffort(claude, sonnet, "max"); err != nil || effort != "max" {
		t.Fatalf("claude max effort=%q err=%v", effort, err)
	}
	if effort, err := ResolveEffort(claude, sonnet, "default"); err != nil || effort != "" {
		t.Fatalf("default effort=%q err=%v", effort, err)
	}
}

func TestCatalogIncludesConfiguredOMPModels(t *testing.T) {
	adapter, valid := ResolveAdapter("omp", false)
	if !valid || adapter.Runtime != "omp-acp" || adapter.DefaultModel != "default" || len(adapter.Models) != 3 {
		t.Fatalf("omp catalog=%#v valid=%v", adapter, valid)
	}
	if adapter.Models[0].RuntimeID() != "" || adapter.Models[1].ContextWindow != 1048576 || adapter.Models[2].ID != "box/qwen3_6_27b" {
		t.Fatalf("omp models=%#v", adapter.Models)
	}
	if adapter.Effort == nil || len(adapter.Effort.Options) != 8 || len(adapter.Capabilities) != 2 || adapter.Capabilities[0] != (Capability{ID: "subagents", Level: "progress"}) || adapter.Capabilities[1] != (Capability{ID: "task-plan", Level: "phases"}) {
		t.Fatalf("omp capabilities or effort=%#v %#v", adapter.Capabilities, adapter.Effort)
	}
	if len(adapter.Options) != 1 || adapter.Options[0].ID != "advisor" || adapter.Options[0].Type != "boolean" {
		t.Fatalf("omp options=%#v", adapter.Options)
	}
	if options, err := ResolveOptions(adapter, map[string]string{"advisor": "true"}); err != nil || options["advisor"] != "true" {
		t.Fatalf("omp advisor options=%#v err=%v", options, err)
	}
	if options, err := ResolveOptions(adapter, nil); err != nil || options["advisor"] != "false" {
		t.Fatalf("omp default advisor options=%#v err=%v", options, err)
	}
	if _, err := ResolveOptions(adapter, map[string]string{"advisor": "sometimes"}); err == nil {
		t.Fatal("invalid OMP advisor value was accepted")
	}
	if effort, err := ResolveEffort(adapter, adapter.Models[0], "auto"); err != nil || effort != "auto" {
		t.Fatalf("omp auto effort=%q err=%v", effort, err)
	}
}

func TestResolveOptionsSupportsAdapterDefinedTypes(t *testing.T) {
	adapter := Adapter{ID: "custom", Options: []ProviderOption{
		{ID: "enabled", Name: "Enabled", Type: "boolean", Default: "false"},
		{ID: "mode", Name: "Mode", Type: "enum", Default: "quick", Choices: []ProviderOptionChoice{{Value: "quick", Name: "Quick"}, {Value: "thorough", Name: "Thorough"}}},
		{ID: "instructions", Name: "Instructions", Type: "string", Default: "Be concise"},
	}}
	options, err := ResolveOptions(adapter, map[string]string{"enabled": "true", "mode": "thorough", "instructions": "Check tests"})
	if err != nil {
		t.Fatal(err)
	}
	if options["enabled"] != "true" || options["mode"] != "thorough" || options["instructions"] != "Check tests" {
		t.Fatalf("resolved options=%#v", options)
	}
	defaults, err := ResolveOptions(adapter, nil)
	if err != nil || defaults["enabled"] != "false" || defaults["mode"] != "quick" || defaults["instructions"] != "Be concise" {
		t.Fatalf("default options=%#v err=%v", defaults, err)
	}
	if _, err = ResolveOptions(adapter, map[string]string{"mode": "missing"}); err == nil {
		t.Fatal("invalid enum option was accepted")
	}
	if _, err = ResolveOptions(adapter, map[string]string{"unknown": "value"}); err == nil {
		t.Fatal("unknown provider option was accepted")
	}
}

func TestPiUsesConfiguredModelsAndThinkingLevels(t *testing.T) {
	adapter, configuredModel, err := ResolveSelection("pi", "", false)
	if err != nil {
		t.Fatal(err)
	}
	if configuredModel.ID != "default" || configuredModel.RuntimeID() != "" {
		t.Fatalf("pi default model=%#v", configuredModel)
	}
	if effort, err := ResolveEffort(adapter, configuredModel, "minimal"); err != nil || effort != "minimal" {
		t.Fatalf("pi minimal effort=%q err=%v", effort, err)
	}
}

func TestLoadCatalogRejectsInvalidConfiguration(t *testing.T) {
	_, err := LoadCatalog([]byte("version: 1\nharnesses:\n  - id: x\n    name: X\n    adapter: x\n    defaultModel: missing\n    models: []\n"))
	if err == nil || !strings.Contains(err.Error(), "not registered") {
		t.Fatalf("err=%v", err)
	}
}

func TestLoadCatalogRejectsUnknownModelEffort(t *testing.T) {
	_, err := LoadCatalog([]byte("version: 1\nharnesses:\n  - id: x\n    name: X\n    adapter: x\n    defaultModel: one\n    effort:\n      label: Thinking\n      options:\n        - id: low\n          name: Low\n    models:\n      - id: one\n        name: One\n        defaultEffort: max\n"))
	if err == nil || !strings.Contains(err.Error(), "unknown default effort") {
		t.Fatalf("err=%v", err)
	}
}

func TestLoadCatalogRejectsUnknownFields(t *testing.T) {
	_, err := LoadCatalog([]byte("version: 1\nharnesses:\n  - id: x\n    name: X\n    adapter: pi\n    defaultModel: one\n    modles: []\n"))
	if err == nil || !strings.Contains(err.Error(), "field modles not found") {
		t.Fatalf("err=%v", err)
	}
}

func TestConfigureCatalogLoadsLocalOverride(t *testing.T) {
	path := filepath.Join(t.TempDir(), "harnesses.yaml")
	data := []byte("version: 1\nharnesses:\n  - id: local\n    name: Local\n    adapter: pi\n    defaultModel: one\n    models:\n      - id: one\n        name: One\n")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := ConfigureCatalog(path); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := ConfigureCatalog(""); err != nil {
			t.Fatal(err)
		}
	})
	if source := CatalogSource(); source != path {
		t.Fatalf("catalog source=%q want %q", source, path)
	}
	if adapter, found := ResolveAdapter("local", false); !found || adapter.DefaultModel != "one" {
		t.Fatalf("local adapter=%#v found=%v", adapter, found)
	}
}

func TestSupportedNodeVersion(t *testing.T) {
	for version, want := range map[string]bool{"v22.18.0": false, "v22.19.0": true, "v23.0.0": true, "garbage": false} {
		if got := supportedNodeVersion(version); got != want {
			t.Errorf("supportedNodeVersion(%q)=%v want %v", version, got, want)
		}
	}
}

func TestEveryConfiguredProviderAndModelResolves(t *testing.T) {
	for _, provider := range Catalog(false) {
		if _, _, err := ResolveSelection(provider.ID, provider.DefaultModel, false); err != nil {
			t.Errorf("default selection %s/%s: %v", provider.ID, provider.DefaultModel, err)
		}
		for _, model := range provider.Models {
			adapter, resolved, err := ResolveSelection(provider.ID, model.ID, false)
			if err != nil || adapter.Runtime == "" || resolved.ID != model.ID {
				t.Errorf("selection %s/%s: adapter=%#v model=%#v err=%v", provider.ID, model.ID, adapter, resolved, err)
			}
		}
	}
}

func TestHarnessPathAddsUserRuntimeBins(t *testing.T) {
	home := t.TempDir()
	for _, path := range []string{filepath.Join(home, ".bun", "bin"), filepath.Join(home, ".local", "bin")} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	paths := filepath.SplitList(harnessPath("/usr/bin:/bin", home))
	if len(paths) != 4 || paths[0] != filepath.Join(home, ".local", "bin") || paths[1] != filepath.Join(home, ".bun", "bin") {
		t.Fatalf("paths=%#v", paths)
	}
}

func TestHarnessEnvironmentIncludesConfigAndOptInVariables(t *testing.T) {
	t.Setenv("CODEX_HOME", "/tmp/codex-test")
	t.Setenv("DSH_HOME", "/tmp/dsh-test")
	t.Setenv("DEEPSEEK_BASE_URL", "https://deepseek.example.test/v1")
	t.Setenv("DEEPSEEK_API_KEY", "deepseek-test-key")
	t.Setenv("DSH_TELEMETRY_MODE", "DISABLED")
	t.Setenv("NODE_USE_ENV_PROXY", "1")
	t.Setenv("USER", "board-user")
	t.Setenv("LOGNAME", "board-user")
	t.Setenv("DIETER_HARNESS_ENV", "CUSTOM_MODEL_API_KEY,CUSTOM_MODEL_BASE_URL")
	t.Setenv("CUSTOM_MODEL_API_KEY", "test-key")
	t.Setenv("CUSTOM_MODEL_BASE_URL", "https://models.example.test")
	values := map[string]string{}
	for _, item := range harnessEnvironment() {
		name, value, _ := strings.Cut(item, "=")
		values[name] = value
	}
	for name, want := range map[string]string{
		"CODEX_HOME":            "/tmp/codex-test",
		"DSH_HOME":              "/tmp/dsh-test",
		"DEEPSEEK_BASE_URL":     "https://deepseek.example.test/v1",
		"DEEPSEEK_API_KEY":      "deepseek-test-key",
		"DSH_TELEMETRY_MODE":    "DISABLED",
		"NODE_USE_ENV_PROXY":    "1",
		"USER":                  "board-user",
		"LOGNAME":               "board-user",
		"CUSTOM_MODEL_API_KEY":  "test-key",
		"CUSTOM_MODEL_BASE_URL": "https://models.example.test",
	} {
		if values[name] != want {
			t.Errorf("%s=%q want %q", name, values[name], want)
		}
	}
}

func TestSubprocessRunnerDSHACPIntegration(t *testing.T) {
	if os.Getenv("DIETER_TEST_DSH_E2E") != "1" {
		t.Skip("set DIETER_TEST_DSH_E2E=1 to install and run the pinned DSH ACP package")
	}
	cwd, _ := os.Getwd()
	runtimeDir := filepath.Join(cwd, "runtime")
	if _, err := os.Stat(filepath.Join(runtimeDir, "node_modules")); err != nil {
		t.Skip("local harness dependencies are not installed")
	}
	stagedRuntime := t.TempDir()
	if err := stageRuntimeAssets(stagedRuntime); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(runtimeDir, "node_modules"), filepath.Join(stagedRuntime, "node_modules")); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIETER_HARNESS_RUNTIME_DIR", stagedRuntime)

	var apiMu sync.Mutex
	var apiRequests []map[string]any
	var apiAuthorization []string
	api := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/chat/completions" || request.Method != http.MethodPost {
			http.Error(response, "unexpected fixture API operation", http.StatusNotFound)
			return
		}
		var body map[string]any
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			http.Error(response, err.Error(), http.StatusBadRequest)
			return
		}
		apiMu.Lock()
		apiRequests = append(apiRequests, body)
		apiAuthorization = append(apiAuthorization, request.Header.Get("Authorization"))
		requestNumber := len(apiRequests)
		apiMu.Unlock()

		response.Header().Set("Content-Type", "text/event-stream")
		_, _ = response.Write([]byte("data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":null,\"reasoning_content\":\"\"}}]}\n\n"))
		if requestNumber == 1 {
			_, _ = response.Write([]byte("data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_dieter_plan\",\"type\":\"function\",\"function\":{\"name\":\"todo_write\",\"arguments\":\"{\\\"todos\\\":[{\\\"content\\\":\\\"Verify DSH ACP\\\",\\\"status\\\":\\\"in_progress\\\"}]}\"}}]}}]}\n\n"))
			_, _ = response.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"\"},\"finish_reason\":\"tool_calls\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}\n\n"))
		} else {
			text := "DSH_E2E_OK"
			if requestNumber > 2 {
				text = "DSH_RESUME_OK"
			}
			chunk, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{"delta": map[string]any{"content": text}}}})
			_, _ = response.Write([]byte("data: " + string(chunk) + "\n\n"))
			_, _ = response.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2}}\n\n"))
		}
		_, _ = response.Write([]byte("data: [DONE]\n\n"))
	}))
	defer api.Close()

	base := t.TempDir()
	dshHome := filepath.Join(base, "dsh-home")
	dieterHome := filepath.Join(base, "dieter-home")
	runtimeRoot := filepath.Join(dieterHome, "runtime", "harness", "dsh-discovery")
	repo := filepath.Join(base, "repo")
	if err := os.MkdirAll(filepath.Join(repo, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(dshHome, 0o700); err != nil {
		t.Fatal(err)
	}
	profilePatch := `- id: llm-deepseek
  disabled: true

- id: llm-pi-ai
  config:
    providers:
      fixture:
        displayName: Fixture
        apiKeyEnv: DIETER_DSH_E2E_API_KEY
        api: openai-completions
        baseURL: ` + api.URL + `
        reasoning: high
        models:
          - id: test-model
            name: Test Model
            contextWindow: 1000000
            maxTokens: 131072
            reasoningEfforts:
              low: low
              high: high
            compat:
              supportsDeveloperRole: true
              supportsUsageInStreaming: true
              maxTokensField: max_tokens
              thinkingFormat: chat-template
              chatTemplateKwargs:
                enable_thinking:
                  $var: thinking.enabled
                reasoning_effort:
                  $var: thinking.effort
                  omitWhenOff: true

- id: agent-default-model
  config:
    provider: fixture
    model: test-model

- id: acp
  config:
    provider: fixture
    model: test-model
    sessionListPageSize: 100
`
	if err := os.WriteFile(filepath.Join(dshHome, "cordis.patch.yml"), []byte(profilePatch), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIETER_HOME", dieterHome)
	t.Setenv("DSH_HOME", dshHome)
	t.Setenv("DIETER_HARNESS_ENV", "DIETER_DSH_E2E_API_KEY")
	t.Setenv("DIETER_DSH_E2E_API_KEY", "dieter-e2e-key")
	t.Setenv("DSH_TELEMETRY_DISABLED", "1")
	t.Setenv("DSH_PERMISSION_MODE", "workspace-write")
	t.Setenv("NO_PROXY", "127.0.0.1,localhost")
	discoveryCtx, cancelDiscovery := context.WithTimeout(context.Background(), 10*time.Minute)
	discovered, err := discoverDSHModels(discoveryCtx)
	cancelDiscovery()
	if err != nil || len(discovered) != 1 || discovered[0].ID != "fixture/test-model" || discovered[0].RuntimeModel == nil || *discovered[0].RuntimeModel != `["fixture","test-model"]` {
		t.Fatalf("discovered DSH models=%#v err=%v", discovered, err)
	}

	runner := NewSubprocessRunner(t.TempDir())
	run := func(prompt, responseID string, session json.RawMessage) (string, string, json.RawMessage, error) {
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
		defer cancel()
		var chunks []string
		var capabilities []string
		var state json.RawMessage
		err := runner.Run(ctx, Request{
			Harness: "dsh", Adapter: "dsh-acp", Model: *discovered[0].RuntimeModel, ConfiguredModel: discovered[0].ID,
			Prompt: prompt, SessionID: "dsh-e2e", ResponseMessageID: responseID,
			Session: session, ProjectPath: repo, RuntimeRoot: runtimeRoot,
		}, func(output Output) error {
			switch output.Type {
			case "chunk":
				chunks = append(chunks, string(output.Chunk))
			case "capability":
				capabilities = append(capabilities, string(output.Capability))
			case "session":
				state = append(state[:0], output.State...)
			}
			return nil
		})
		return strings.Join(chunks, ""), strings.Join(capabilities, ""), state, err
	}

	firstStream, firstCapabilities, state, err := run("Use todo_write once, then answer.", "assistant_dsh_1", nil)
	if err != nil || !strings.Contains(firstStream, "DSH_E2E_OK") || strings.Contains(firstStream, "tool-input-error") || !strings.Contains(firstCapabilities, "Verify DSH ACP") || !strings.Contains(string(state), `"acpSessionId"`) {
		t.Fatalf("first stream=%q capabilities=%q state=%s err=%v", firstStream, firstCapabilities, state, err)
	}
	secondStream, _, resumedState, err := run("Confirm this resumed session.", "assistant_dsh_2", state)
	if err != nil || !strings.Contains(secondStream, "DSH_RESUME_OK") || !strings.Contains(string(resumedState), `"acpSessionId"`) {
		t.Fatalf("resumed stream=%q state=%s err=%v", secondStream, resumedState, err)
	}

	apiMu.Lock()
	defer apiMu.Unlock()
	if len(apiRequests) != 3 {
		t.Fatalf("fixture API received %d requests: %#v", len(apiRequests), apiRequests)
	}
	for index, body := range apiRequests {
		thinking, ok := body["chat_template_kwargs"].(map[string]any)
		if body["model"] != "test-model" || !ok || thinking["enable_thinking"] != true || thinking["reasoning_effort"] != "high" {
			t.Errorf("request %d model=%v chat_template_kwargs=%v", index+1, body["model"], body["chat_template_kwargs"])
		}
		if apiAuthorization[index] != "Bearer dieter-e2e-key" {
			t.Errorf("request %d authorization=%q", index+1, apiAuthorization[index])
		}
	}
}

func TestSubprocessRunnerMockIntegration(t *testing.T) {
	cwd, _ := os.Getwd()
	runtimeDir := filepath.Join(cwd, "runtime")
	if _, err := os.Stat(filepath.Join(runtimeDir, "node_modules")); err != nil {
		t.Skip("local harness dependencies are not installed")
	}
	stagedRuntime := t.TempDir()
	if err := stageRuntimeAssets(stagedRuntime); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(runtimeDir, "node_modules"), filepath.Join(stagedRuntime, "node_modules")); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIETER_HARNESS_RUNTIME_DIR", stagedRuntime)
	repo := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(repo, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	runner := NewSubprocessRunner(t.TempDir())
	var chunks []string
	var capabilities []string
	heartbeats := 0
	err := runner.Run(context.Background(), Request{Harness: "mock", Prompt: "hello", SessionID: "card", ResponseMessageID: "assistant_1", ProjectPath: repo, RuntimeRoot: filepath.Join(t.TempDir(), "runtime")}, func(output Output) error {
		if output.Type == "heartbeat" {
			heartbeats++
		}
		if output.Type == "chunk" {
			chunks = append(chunks, string(output.Chunk))
		}
		if output.Type == "capability" {
			capabilities = append(capabilities, string(output.Capability))
		}
		return nil
	})
	stream := strings.Join(chunks, "")
	capabilityStream := strings.Join(capabilities, "")
	if err != nil || heartbeats == 0 || !strings.Contains(stream, "Mock harness received: hello") || !strings.Contains(stream, `"messageId":"assistant_1"`) || !strings.Contains(stream, `"type":"message-metadata"`) || !strings.Contains(stream, `"messageMetadata":{"createdAt":`) || !strings.Contains(stream, `"totalTokens":150`) || !strings.Contains(stream, `"contextWindowTokens":1000`) || !strings.Contains(capabilityStream, `"id":"task-plan"`) || !strings.Contains(capabilityStream, `"state":"completed"`) {
		t.Fatalf("chunks=%q capabilities=%q heartbeats=%d err=%v", chunks, capabilities, heartbeats, err)
	}
}

func TestSubprocessRunnerKeepsConcurrentProjectWorkspacesIsolated(t *testing.T) {
	cwd, _ := os.Getwd()
	runtimeDir := filepath.Join(cwd, "runtime")
	if _, err := os.Stat(filepath.Join(runtimeDir, "node_modules")); err != nil {
		t.Skip("local harness dependencies are not installed")
	}
	t.Setenv("DIETER_HARNESS_RUNTIME_DIR", runtimeDir)
	base := t.TempDir()
	projectA := filepath.Join(base, "project-a")
	projectB := filepath.Join(base, "project-b")
	for _, project := range []string{projectA, projectB} {
		if err := os.MkdirAll(project, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	runtimeRoot := filepath.Join(base, "shared-runtime")
	runner := NewSubprocessRunner(t.TempDir())
	type result struct {
		session string
		stream  string
		err     error
	}
	results := make(chan result, 2)
	var wait sync.WaitGroup
	for _, request := range []Request{
		{Harness: "mock", Prompt: "mock-concurrent-workspace-write", SessionID: "card-a", ResponseMessageID: "assistant-a", ProjectPath: projectA, RuntimeRoot: runtimeRoot},
		{Harness: "mock", Prompt: "mock-concurrent-workspace-write", SessionID: "card-b", ResponseMessageID: "assistant-b", ProjectPath: projectB, RuntimeRoot: runtimeRoot},
	} {
		request := request
		wait.Add(1)
		go func() {
			defer wait.Done()
			var chunks []string
			err := runner.Run(context.Background(), request, func(output Output) error {
				if output.Type == "chunk" {
					chunks = append(chunks, string(output.Chunk))
				}
				return nil
			})
			results <- result{session: request.SessionID, stream: strings.Join(chunks, ""), err: err}
		}()
	}
	wait.Wait()
	close(results)
	for result := range results {
		project := projectA
		if result.session == "card-b" {
			project = projectB
		}
		if result.err != nil || !strings.Contains(result.stream, project) {
			t.Fatalf("session=%s stream=%q err=%v", result.session, result.stream, result.err)
		}
	}
	for _, marker := range []string{
		filepath.Join(projectA, ".dieter-mock-card-a"),
		filepath.Join(projectB, ".dieter-mock-card-b"),
	} {
		if _, err := os.Stat(marker); err != nil {
			t.Fatalf("missing marker %s: %v", marker, err)
		}
	}
	for _, marker := range []string{
		filepath.Join(projectA, ".dieter-mock-card-b"),
		filepath.Join(projectB, ".dieter-mock-card-a"),
	} {
		if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("cross-workspace marker %s err=%v", marker, err)
		}
	}
}

func TestSubprocessRunnerRetainsDiagnosticsAfterStructuredError(t *testing.T) {
	runtimeDir := t.TempDir()
	script := `process.stdin.once('data', () => {
  process.stderr.write('provider stderr: context window exceeded\n');
  process.stdout.write(JSON.stringify({type:'error', error:'codex exited 1'}) + '\n');
  process.exitCode = 1;
});`
	if err := os.WriteFile(filepath.Join(runtimeDir, "runner.mjs"), []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIETER_HARNESS_RUNTIME_DIR", runtimeDir)
	runner := NewSubprocessRunner(t.TempDir())
	var reported string
	err := runner.Run(context.Background(), Request{
		Harness: "codex", Prompt: "fail", SessionID: "card", ProjectPath: t.TempDir(), RuntimeRoot: t.TempDir(),
	}, func(output Output) error {
		if output.Type == "error" {
			reported = output.Message
		}
		return nil
	})
	if reported != "codex exited 1" || err == nil || !strings.Contains(err.Error(), "codex exited 1") ||
		!strings.Contains(err.Error(), "provider stderr: context window exceeded") {
		t.Fatalf("reported=%q err=%v", reported, err)
	}
}

func TestSubprocessRunnerRetainsDiagnosticsAfterUIError(t *testing.T) {
	runtimeDir := t.TempDir()
	script := `process.stdin.once('data', () => {
  process.stderr.write('ACP model mapping is required when a model is set.\n');
  process.stdout.write(JSON.stringify({type:'chunk', chunk:{type:'error', errorText:'An error occurred.'}}) + '\n');
});`
	if err := os.WriteFile(filepath.Join(runtimeDir, "runner.mjs"), []byte(script), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIETER_HARNESS_RUNTIME_DIR", runtimeDir)
	runner := NewSubprocessRunner(t.TempDir())
	emittedErrorChunk := false
	err := runner.Run(context.Background(), Request{
		Harness: "omp", Prompt: "fail", SessionID: "card", ProjectPath: t.TempDir(), RuntimeRoot: t.TempDir(),
	}, func(output Output) error {
		if output.Type == "chunk" && strings.Contains(string(output.Chunk), `"type":"error"`) {
			emittedErrorChunk = true
		}
		return nil
	})
	if emittedErrorChunk || err == nil || !strings.Contains(err.Error(), "An error occurred.") ||
		!strings.Contains(err.Error(), "ACP model mapping is required when a model is set.") {
		t.Fatalf("emittedErrorChunk=%v err=%v", emittedErrorChunk, err)
	}
}
