package harness

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const discoveryTTL = 5 * time.Minute

var (
	discoveryMu      sync.Mutex
	discoveryUpdated time.Time
	runDiscovery     = runDiscoveryCommand
)

// RefreshCatalog asks each installed harness for its current model and
// reasoning capabilities. The YAML registry remains the compatibility and
// provider-options layer; successfully discovered models are what clients see.
func RefreshCatalog(ctx context.Context, includeMock bool) []Adapter {
	discoveryMu.Lock()
	defer discoveryMu.Unlock()
	if time.Since(discoveryUpdated) < discoveryTTL && len(discoveredCatalog) > 0 {
		return Catalog(includeMock)
	}

	catalogMu.RLock()
	base := make([]Adapter, len(configuredCatalog))
	for index, item := range configuredCatalog {
		base[index] = cloneAdapter(item)
	}
	catalogMu.RUnlock()

	type result struct {
		id     string
		models []Model
	}
	results := make(chan result, len(base))
	var wait sync.WaitGroup
	for _, adapter := range base {
		adapter := adapter
		if adapter.ID == "mock" {
			continue
		}
		wait.Add(1)
		go func() {
			defer wait.Done()
			// Pi needs two native RPC rounds (models, then per-model levels), and
			// provider CLIs can contend for startup I/O when refreshed together.
			commandCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
			defer cancel()
			models, err := discoverModels(commandCtx, adapter.ID)
			if err == nil && len(models) > 0 {
				results <- result{id: adapter.ID, models: models}
			}
		}()
	}
	wait.Wait()
	close(results)
	byID := map[string][]Model{}
	for item := range results {
		byID[item.id] = item.models
	}
	for index := range base {
		if models := byID[base[index].ID]; len(models) > 0 {
			base[index] = mergeDiscoveredAdapter(base[index], models)
		}
	}
	catalogMu.Lock()
	discoveredCatalog = base
	discoveryUpdated = time.Now()
	catalogMu.Unlock()
	return Catalog(includeMock)
}

func discoverModels(ctx context.Context, provider string) ([]Model, error) {
	switch provider {
	case "codex":
		return discoverCodexModels()
	case "claude-code":
		output, err := runDiscovery(ctx, "claude", "--help")
		if err != nil {
			return nil, err
		}
		return parseClaudeHelp(output)
	case "pi":
		return discoverPiModels(ctx)
	case "omp":
		return discoverOMPModels(ctx)
	default:
		return nil, fmt.Errorf("no discovery integration for %s", provider)
	}
}

func mergeDiscoveredAdapter(adapter Adapter, visible []Model) Adapter {
	known := make(map[string]bool, len(visible))
	efforts := map[string]bool{}
	for _, model := range visible {
		known[model.ID] = true
		for _, effort := range model.Efforts {
			efforts[effort] = true
		}
	}
	for _, model := range adapter.Models {
		if !known[model.ID] {
			model.Hidden = true
			visible = append(visible, model)
		}
	}
	if !known[adapter.DefaultModel] {
		adapter.DefaultModel = visible[0].ID
	}
	adapter.Models = visible
	if len(efforts) == 0 {
		adapter.Effort = nil
		return adapter
	}
	ids := make([]string, 0, len(efforts))
	for id := range efforts {
		ids = append(ids, id)
	}
	sort.SliceStable(ids, func(i, j int) bool { return effortRank(ids[i]) < effortRank(ids[j]) })
	options := make([]EffortOption, 0, len(ids))
	for _, id := range ids {
		options = append(options, EffortOption{ID: id, Name: effortName(id)})
	}
	label := "Thinking"
	if adapter.ID == "codex" {
		label = "Reasoning"
	}
	adapter.Effort = &EffortConfig{Label: label, Options: options}
	return adapter
}

func runDiscoveryCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, discoveryExecutable(name), args...)
	command.Env = discoveryEnvironment()
	return command.Output()
}

func discoveryExecutable(name string) string {
	if path, err := exec.LookPath(name); err == nil {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return name
	}
	for _, directory := range []string{filepath.Join(home, ".bun", "bin"), filepath.Join(home, ".local", "bin")} {
		candidate := filepath.Join(directory, name)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return candidate
		}
	}
	return name
}

func discoveryEnvironment() []string {
	environment := os.Environ()
	home, err := os.UserHomeDir()
	if err != nil {
		return environment
	}
	path := os.Getenv("PATH")
	prefixes := []string{filepath.Join(home, ".bun", "bin"), filepath.Join(home, ".local", "bin")}
	filtered := environment[:0]
	for _, value := range environment {
		if !strings.HasPrefix(value, "PATH=") {
			filtered = append(filtered, value)
		}
	}
	return append(filtered, "PATH="+strings.Join(append(prefixes, path), string(os.PathListSeparator)))
}

type codexCache struct {
	Models []struct {
		Slug                   string `json:"slug"`
		DisplayName            string `json:"display_name"`
		Visibility             string `json:"visibility"`
		SupportedInAPI         bool   `json:"supported_in_api"`
		ContextWindow          int    `json:"context_window"`
		DefaultReasoningLevel  string `json:"default_reasoning_level"`
		SupportedReasoningList []struct {
			Effort string `json:"effort"`
		} `json:"supported_reasoning_levels"`
	} `json:"models"`
}

func discoverCodexModels() ([]Model, error) {
	root := strings.TrimSpace(os.Getenv("CODEX_HOME"))
	if root == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		root = filepath.Join(home, ".codex")
	}
	data, err := os.ReadFile(filepath.Join(root, "models_cache.json"))
	if err != nil {
		return nil, err
	}
	var cache codexCache
	if err := json.Unmarshal(data, &cache); err != nil {
		return nil, err
	}
	models := make([]Model, 0, len(cache.Models))
	for _, item := range cache.Models {
		if item.Slug == "" || item.Visibility != "list" {
			continue
		}
		model := Model{ID: item.Slug, Name: item.DisplayName, ContextWindow: item.ContextWindow, DefaultEffort: item.DefaultReasoningLevel}
		for _, level := range item.SupportedReasoningList {
			if level.Effort != "" {
				model.Efforts = append(model.Efforts, level.Effort)
			}
		}
		models = append(models, model)
	}
	return models, nil
}

var (
	claudeEffortPattern = regexp.MustCompile(`(?s)--effort <level>.*?\(([^)]+)\)`)
	claudeAliasPattern  = regexp.MustCompile(`(?s)--model <model>.*?\(e\.g\.\s*(.*?)\)\s*or a`)
	quotedValuePattern  = regexp.MustCompile(`'([^']+)'`)
)

func parseClaudeHelp(data []byte) ([]Model, error) {
	text := string(data)
	effortMatch := claudeEffortPattern.FindStringSubmatch(text)
	aliasMatch := claudeAliasPattern.FindStringSubmatch(text)
	if len(aliasMatch) < 2 {
		return nil, fmt.Errorf("claude help did not advertise model aliases")
	}
	efforts := []string{}
	if len(effortMatch) > 1 {
		for _, value := range strings.Split(effortMatch[1], ",") {
			if value = strings.TrimSpace(value); value != "" {
				efforts = append(efforts, value)
			}
		}
	}
	models := []Model{}
	for _, match := range quotedValuePattern.FindAllStringSubmatch(aliasMatch[1], -1) {
		id := match[1]
		models = append(models, Model{ID: id, Name: titleWords(id), Efforts: append([]string(nil), efforts...)})
	}
	return models, nil
}

type ompModelEnvelope struct {
	Models []struct {
		Selector      string   `json:"selector"`
		ID            string   `json:"id"`
		Name          string   `json:"name"`
		Provider      string   `json:"provider"`
		ContextWindow int      `json:"contextWindow"`
		Thinking      []string `json:"thinking"`
	} `json:"models"`
}

func parseOMPModels(data []byte) ([]Model, error) {
	var envelope ompModelEnvelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		return nil, err
	}
	models := make([]Model, 0, len(envelope.Models))
	for _, item := range envelope.Models {
		id := item.Selector
		if id == "" && item.Provider != "" && item.ID != "" {
			id = item.Provider + "/" + item.ID
		}
		if id == "" {
			continue
		}
		name := item.Name
		if name == "" {
			name = id
		}
		models = append(models, Model{ID: id, Name: name, ContextWindow: item.ContextWindow, Efforts: append([]string(nil), item.Thinking...)})
	}
	return models, nil
}

func discoverOMPModels(ctx context.Context) ([]Model, error) {
	output, err := runDiscovery(ctx, "omp", "models", "--json", "--no-extensions")
	if err != nil {
		return nil, err
	}
	models, err := parseOMPModels(output)
	if err != nil {
		return nil, err
	}
	rolesOutput, err := runDiscovery(ctx, "omp", "config", "get", "modelRoles")
	if err != nil {
		return models, nil
	}
	var roles map[string]string
	if json.Unmarshal(rolesOutput, &roles) != nil {
		return models, nil
	}
	configured := roles["default"]
	for index := range models {
		if configured == models[index].ID || strings.HasPrefix(configured, models[index].ID+":") {
			level := strings.TrimPrefix(configured, models[index].ID)
			level = strings.TrimPrefix(level, ":")
			for _, supported := range models[index].Efforts {
				if supported == level {
					models[index].DefaultEffort = level
				}
			}
			if index > 0 {
				models[0], models[index] = models[index], models[0]
			}
			break
		}
	}
	return models, nil
}

type piRPCResponse struct {
	ID      string `json:"id"`
	Success bool   `json:"success"`
	Data    struct {
		Models []struct {
			Provider      string `json:"provider"`
			ID            string `json:"id"`
			Name          string `json:"name"`
			ContextWindow int    `json:"contextWindow"`
		} `json:"models"`
		Levels []string `json:"levels"`
	} `json:"data"`
}

func discoverPiModels(ctx context.Context) ([]Model, error) {
	first, err := runPiRPC(ctx, []map[string]any{{"id": "models", "type": "get_available_models"}})
	if err != nil {
		return nil, err
	}
	var advertised []struct {
		Provider      string
		ID            string
		Name          string
		ContextWindow int
	}
	for _, response := range first {
		if response.ID == "models" && response.Success {
			for _, item := range response.Data.Models {
				advertised = append(advertised, struct {
					Provider      string
					ID            string
					Name          string
					ContextWindow int
				}{item.Provider, item.ID, item.Name, item.ContextWindow})
			}
		}
	}
	if len(advertised) == 0 {
		return nil, fmt.Errorf("pi returned no models")
	}
	commands := make([]map[string]any, 0, len(advertised)*2)
	for index, item := range advertised {
		commands = append(commands,
			map[string]any{"id": fmt.Sprintf("set-%d", index), "type": "set_model", "provider": item.Provider, "modelId": item.ID},
			map[string]any{"id": fmt.Sprintf("levels-%d", index), "type": "get_available_thinking_levels"},
		)
	}
	responses, err := runPiRPC(ctx, commands)
	if err != nil {
		return nil, err
	}
	levels := map[int][]string{}
	for _, response := range responses {
		var index int
		if _, err := fmt.Sscanf(response.ID, "levels-%d", &index); err == nil && response.Success {
			levels[index] = response.Data.Levels
		}
	}
	models := make([]Model, 0, len(advertised))
	for index, item := range advertised {
		id := item.ID
		if item.Provider != "" {
			id = item.Provider + "/" + item.ID
		}
		models = append(models, Model{ID: id, Name: item.Name, ContextWindow: item.ContextWindow, Efforts: levels[index]})
	}
	return models, nil
}

func runPiRPC(ctx context.Context, commands []map[string]any) ([]piRPCResponse, error) {
	var input bytes.Buffer
	for _, command := range commands {
		if err := json.NewEncoder(&input).Encode(command); err != nil {
			return nil, err
		}
	}
	command := exec.CommandContext(ctx, discoveryExecutable("pi"), "--mode", "rpc", "--no-session", "--no-tools", "--no-extensions", "--no-skills", "--no-context-files")
	command.Env = discoveryEnvironment()
	command.Stdin = &input
	output, err := command.Output()
	if err != nil {
		return nil, err
	}
	responses := []piRPCResponse{}
	scanner := bufio.NewScanner(bytes.NewReader(output))
	for scanner.Scan() {
		var response piRPCResponse
		if json.Unmarshal(scanner.Bytes(), &response) == nil && response.ID != "" {
			responses = append(responses, response)
		}
	}
	return responses, scanner.Err()
}

func effortRank(id string) string {
	order := map[string]string{"off": "00", "minimal": "01", "low": "02", "medium": "03", "high": "04", "xhigh": "05", "max": "06", "ultra": "07", "auto": "08"}
	if rank := order[id]; rank != "" {
		return rank
	}
	return "50-" + id
}

func effortName(id string) string {
	if id == "xhigh" {
		return "Extra high"
	}
	return titleWords(id)
}

func titleWords(value string) string {
	value = strings.ReplaceAll(value, "-", " ")
	return strings.Title(value) //nolint:staticcheck -- capability labels are short ASCII identifiers.
}
