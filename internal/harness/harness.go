package harness

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	boardconfig "github.com/dbpprt/dieter/config"
	"gopkg.in/yaml.v3"
)

type Model struct {
	ID            string   `json:"id" yaml:"id"`
	Name          string   `json:"name" yaml:"name"`
	ContextWindow int      `json:"contextWindow,omitempty" yaml:"contextWindow,omitempty"`
	DefaultEffort string   `json:"defaultEffort,omitempty" yaml:"defaultEffort,omitempty"`
	Efforts       []string `json:"efforts,omitempty" yaml:"efforts,omitempty"`
	RuntimeModel  *string  `json:"-" yaml:"runtimeModel,omitempty"`
	Hidden        bool     `json:"-" yaml:"-"`
}

var ErrNoActiveTurn = errors.New("card has no active turn")

type workerRecord struct {
	PID      int    `json:"pid"`
	OwnerPID int    `json:"ownerPid"`
	Token    string `json:"token"`
}

func newWorkerToken() string {
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		return fmt.Sprintf("%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(value)
}

func (model Model) RuntimeID() string {
	if model.RuntimeModel != nil {
		return *model.RuntimeModel
	}
	return model.ID
}

type EffortOption struct {
	ID   string `json:"id" yaml:"id"`
	Name string `json:"name" yaml:"name"`
}

type EffortConfig struct {
	Label   string         `json:"label" yaml:"label"`
	Options []EffortOption `json:"options" yaml:"options"`
}

type ProviderOptionChoice struct {
	Value string `json:"value" yaml:"value"`
	Name  string `json:"name" yaml:"name"`
}

// ProviderOption describes a harness-specific setting without coupling the
// API or UI to one provider. Values are serialized as strings so new option
// definitions do not require protobuf changes.
type ProviderOption struct {
	ID          string                 `json:"id" yaml:"id"`
	Name        string                 `json:"name" yaml:"name"`
	Description string                 `json:"description,omitempty" yaml:"description,omitempty"`
	Type        string                 `json:"type" yaml:"type"`
	Default     string                 `json:"defaultValue,omitempty" yaml:"default,omitempty"`
	Choices     []ProviderOptionChoice `json:"choices,omitempty" yaml:"choices,omitempty"`
}

type Capability struct {
	ID    string `json:"id" yaml:"id"`
	Level string `json:"level" yaml:"level"`
}

type Adapter struct {
	ID           string           `json:"id" yaml:"id"`
	Name         string           `json:"name" yaml:"name"`
	Runtime      string           `json:"-" yaml:"adapter"`
	DefaultModel string           `json:"defaultModel" yaml:"defaultModel"`
	Effort       *EffortConfig    `json:"effort,omitempty" yaml:"effort,omitempty"`
	Options      []ProviderOption `json:"options,omitempty" yaml:"options,omitempty"`
	Capabilities []Capability     `json:"capabilities,omitempty" yaml:"capabilities,omitempty"`
	Models       []Model          `json:"models" yaml:"models"`
}

type registry struct {
	Version   int       `yaml:"version"`
	Harnesses []Adapter `yaml:"harnesses"`
}

var (
	catalogMu               sync.RWMutex
	configuredCatalog       = mustLoadCatalog(boardconfig.HarnessesYAML, "embedded config/harnesses.yaml")
	configuredCatalogSource = "embedded config/harnesses.yaml"
	discoveredCatalog       []Adapter
)

func mustLoadCatalog(data []byte, source string) []Adapter {
	items, err := LoadCatalog(data)
	if err != nil {
		panic("invalid " + source + ": " + err.Error())
	}
	return items
}

// ConfigureCatalog replaces the embedded catalog with a local YAML file. An
// empty path restores the embedded release defaults. Call this once at process
// startup, before serving requests.
func ConfigureCatalog(path string) error {
	data := boardconfig.HarnessesYAML
	source := "embedded config/harnesses.yaml"
	if path = strings.TrimSpace(path); path != "" {
		absolute, err := filepath.Abs(path)
		if err != nil {
			return fmt.Errorf("resolve harness config: %w", err)
		}
		data, err = os.ReadFile(absolute)
		if err != nil {
			return fmt.Errorf("read harness config %q: %w", absolute, err)
		}
		source = absolute
	}
	items, err := LoadCatalog(data)
	if err != nil {
		return fmt.Errorf("invalid harness config %q: %w", source, err)
	}
	catalogMu.Lock()
	configuredCatalog = items
	configuredCatalogSource = source
	discoveredCatalog = nil
	catalogMu.Unlock()
	return nil
}

func CatalogSource() string {
	catalogMu.RLock()
	defer catalogMu.RUnlock()
	return configuredCatalogSource
}

func LoadCatalog(data []byte) ([]Adapter, error) {
	var document registry
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	decoder.KnownFields(true)
	if err := decoder.Decode(&document); err != nil {
		return nil, err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return nil, errors.New("multiple YAML documents are not supported")
		}
		return nil, err
	}
	if document.Version != 1 {
		return nil, fmt.Errorf("unsupported registry version %d", document.Version)
	}
	if len(document.Harnesses) == 0 {
		return nil, errors.New("at least one harness is required")
	}
	seenHarnesses := map[string]bool{}
	for index := range document.Harnesses {
		harness := &document.Harnesses[index]
		harness.ID, harness.Name = strings.TrimSpace(harness.ID), strings.TrimSpace(harness.Name)
		harness.Runtime, harness.DefaultModel = strings.TrimSpace(harness.Runtime), strings.TrimSpace(harness.DefaultModel)
		if harness.ID == "" || harness.Name == "" || harness.Runtime == "" {
			return nil, fmt.Errorf("harness %d requires id, name, and adapter", index)
		}
		if seenHarnesses[harness.ID] {
			return nil, fmt.Errorf("duplicate harness %q", harness.ID)
		}
		seenHarnesses[harness.ID] = true
		seenCapabilities := map[string]bool{}
		for capabilityIndex := range harness.Capabilities {
			capability := &harness.Capabilities[capabilityIndex]
			capability.ID, capability.Level = strings.TrimSpace(capability.ID), strings.TrimSpace(capability.Level)
			if capability.ID == "" || capability.Level == "" || seenCapabilities[capability.ID] {
				return nil, fmt.Errorf("harness %q has invalid capability %d", harness.ID, capabilityIndex)
			}
			seenCapabilities[capability.ID] = true
		}
		seenOptions := map[string]bool{}
		for optionIndex := range harness.Options {
			option := &harness.Options[optionIndex]
			option.ID, option.Name = strings.TrimSpace(option.ID), strings.TrimSpace(option.Name)
			option.Type, option.Default = strings.TrimSpace(option.Type), strings.TrimSpace(option.Default)
			option.Description = strings.TrimSpace(option.Description)
			if option.ID == "" || option.Name == "" || seenOptions[option.ID] {
				return nil, fmt.Errorf("harness %q has invalid provider option %d", harness.ID, optionIndex)
			}
			seenOptions[option.ID] = true
			switch option.Type {
			case "boolean":
				if option.Default == "" {
					option.Default = "false"
				}
				if option.Default != "true" && option.Default != "false" {
					return nil, fmt.Errorf("harness %q option %q has invalid boolean default %q", harness.ID, option.ID, option.Default)
				}
				if len(option.Choices) > 0 {
					return nil, fmt.Errorf("harness %q boolean option %q cannot have choices", harness.ID, option.ID)
				}
			case "enum":
				seenChoices := map[string]bool{}
				for choiceIndex := range option.Choices {
					choice := &option.Choices[choiceIndex]
					choice.Value, choice.Name = strings.TrimSpace(choice.Value), strings.TrimSpace(choice.Name)
					if choice.Value == "" || choice.Name == "" || seenChoices[choice.Value] {
						return nil, fmt.Errorf("harness %q option %q has invalid choice %d", harness.ID, option.ID, choiceIndex)
					}
					seenChoices[choice.Value] = true
				}
				if len(option.Choices) == 0 || (option.Default != "" && !seenChoices[option.Default]) {
					return nil, fmt.Errorf("harness %q enum option %q requires choices and a valid default", harness.ID, option.ID)
				}
			case "string":
				if len(option.Choices) > 0 {
					return nil, fmt.Errorf("harness %q string option %q cannot have choices", harness.ID, option.ID)
				}
			default:
				return nil, fmt.Errorf("harness %q option %q has unsupported type %q", harness.ID, option.ID, option.Type)
			}
		}
		efforts := map[string]bool{}
		if harness.Effort != nil {
			harness.Effort.Label = strings.TrimSpace(harness.Effort.Label)
			if harness.Effort.Label == "" || len(harness.Effort.Options) == 0 {
				return nil, fmt.Errorf("harness %q effort requires a label and options", harness.ID)
			}
			for optionIndex := range harness.Effort.Options {
				option := &harness.Effort.Options[optionIndex]
				option.ID, option.Name = strings.TrimSpace(option.ID), strings.TrimSpace(option.Name)
				if option.ID == "" || option.Name == "" || efforts[option.ID] {
					return nil, fmt.Errorf("harness %q has invalid effort option %d", harness.ID, optionIndex)
				}
				efforts[option.ID] = true
			}
		}
		seenModels := map[string]bool{}
		for modelIndex := range harness.Models {
			model := &harness.Models[modelIndex]
			model.ID, model.Name = strings.TrimSpace(model.ID), strings.TrimSpace(model.Name)
			model.DefaultEffort = strings.TrimSpace(model.DefaultEffort)
			if model.RuntimeModel != nil {
				value := strings.TrimSpace(*model.RuntimeModel)
				model.RuntimeModel = &value
			}
			if model.ID == "" || model.Name == "" || model.ContextWindow < 0 {
				return nil, fmt.Errorf("harness %q has invalid model %d", harness.ID, modelIndex)
			}
			if seenModels[model.ID] {
				return nil, fmt.Errorf("harness %q has duplicate model %q", harness.ID, model.ID)
			}
			seenModels[model.ID] = true
			if model.DefaultEffort != "" && !efforts[model.DefaultEffort] {
				return nil, fmt.Errorf("harness %q model %q has unknown default effort %q", harness.ID, model.ID, model.DefaultEffort)
			}
			seenModelEfforts := map[string]bool{}
			for effortIndex := range model.Efforts {
				model.Efforts[effortIndex] = strings.TrimSpace(model.Efforts[effortIndex])
				if !efforts[model.Efforts[effortIndex]] || seenModelEfforts[model.Efforts[effortIndex]] {
					return nil, fmt.Errorf("harness %q model %q has invalid effort %q", harness.ID, model.ID, model.Efforts[effortIndex])
				}
				seenModelEfforts[model.Efforts[effortIndex]] = true
			}
			if model.DefaultEffort != "" && len(model.Efforts) > 0 && !seenModelEfforts[model.DefaultEffort] {
				return nil, fmt.Errorf("harness %q model %q default effort %q is not allowed", harness.ID, model.ID, model.DefaultEffort)
			}
		}
		if harness.DefaultModel != "" && !seenModels[harness.DefaultModel] {
			return nil, fmt.Errorf("harness %q default model %q is not registered", harness.ID, harness.DefaultModel)
		}
	}
	return document.Harnesses, nil
}

func Catalog(includeMock bool) []Adapter {
	catalogMu.RLock()
	source := configuredCatalog
	if len(discoveredCatalog) > 0 {
		source = discoveredCatalog
	}
	items := make([]Adapter, len(source))
	for index, item := range source {
		items[index] = cloneAdapter(item)
	}
	catalogMu.RUnlock()
	if includeMock {
		items = append(items, Adapter{
			ID: "mock", Name: "Mock", Runtime: "mock", DefaultModel: "mock",
			Effort: &EffortConfig{Label: "Effort", Options: []EffortOption{{ID: "low", Name: "Low"}, {ID: "high", Name: "High"}}},
			Models: []Model{{ID: "mock", Name: "Mock", DefaultEffort: "low", Efforts: []string{"low", "high"}}},
		})
	}
	return items
}

func cloneAdapter(adapter Adapter) Adapter {
	adapter.Capabilities = append([]Capability(nil), adapter.Capabilities...)
	adapter.Options = append([]ProviderOption(nil), adapter.Options...)
	for index := range adapter.Options {
		adapter.Options[index].Choices = append([]ProviderOptionChoice(nil), adapter.Options[index].Choices...)
	}
	adapter.Models = append([]Model(nil), adapter.Models...)
	for index := range adapter.Models {
		adapter.Models[index].Efforts = append([]string(nil), adapter.Models[index].Efforts...)
		if adapter.Models[index].RuntimeModel != nil {
			value := *adapter.Models[index].RuntimeModel
			adapter.Models[index].RuntimeModel = &value
		}
	}
	if adapter.Effort != nil {
		effort := *adapter.Effort
		effort.Options = append([]EffortOption(nil), effort.Options...)
		adapter.Effort = &effort
	}
	return adapter
}

// ResolveOptions validates provider-specific values and materializes defaults.
// The returned map can be persisted with a conversation and passed unchanged
// through the runtime transport.
func ResolveOptions(adapter Adapter, requested map[string]string) (map[string]string, error) {
	definitions := make(map[string]ProviderOption, len(adapter.Options))
	resolved := make(map[string]string, len(adapter.Options))
	for _, option := range adapter.Options {
		definitions[option.ID] = option
		if option.Default != "" {
			resolved[option.ID] = option.Default
		}
	}
	for rawID, rawValue := range requested {
		id, value := strings.TrimSpace(rawID), strings.TrimSpace(rawValue)
		option, ok := definitions[id]
		if !ok {
			return nil, fmt.Errorf("option %q is not supported for harness %q", id, adapter.ID)
		}
		switch option.Type {
		case "boolean":
			if value != "true" && value != "false" {
				return nil, fmt.Errorf("option %q for harness %q must be true or false", id, adapter.ID)
			}
		case "enum":
			valid := false
			for _, choice := range option.Choices {
				valid = valid || choice.Value == value
			}
			if !valid {
				return nil, fmt.Errorf("option %q value %q is not supported for harness %q", id, value, adapter.ID)
			}
		case "string":
		}
		resolved[id] = value
	}
	return resolved, nil
}

func ResolveAdapter(id string, includeMock bool) (Adapter, bool) {
	for _, adapter := range Catalog(includeMock) {
		if adapter.ID == id {
			return adapter, true
		}
	}
	return Adapter{}, false
}

func ResolveSelection(providerID, modelID string, includeMock bool) (Adapter, Model, error) {
	adapter, valid := ResolveAdapter(strings.TrimSpace(providerID), includeMock)
	if !valid {
		return Adapter{}, Model{}, fmt.Errorf("unsupported harness %q", providerID)
	}
	modelID = strings.TrimSpace(modelID)
	if modelID == "" {
		modelID = adapter.DefaultModel
	}
	if modelID == "" && len(adapter.Models) == 0 {
		return adapter, Model{}, nil
	}
	for _, configuredModel := range adapter.Models {
		if configuredModel.ID == modelID {
			return adapter, configuredModel, nil
		}
	}
	return Adapter{}, Model{}, fmt.Errorf("model %q is not registered for harness %q", modelID, adapter.ID)
}

// ResolveEffort validates an explicitly selected effort against the local
// registry. An empty effort deliberately defers to the underlying CLI's
// configured default.
func ResolveEffort(adapter Adapter, configuredModel Model, effort string) (string, error) {
	effort = strings.TrimSpace(effort)
	if effort == "default" {
		return "", nil
	}
	if effort == "" {
		return "", nil
	}
	if adapter.Effort == nil {
		return "", fmt.Errorf("harness %q does not support configurable effort", adapter.ID)
	}
	allowed := map[string]bool{}
	if len(configuredModel.Efforts) > 0 {
		for _, id := range configuredModel.Efforts {
			allowed[id] = true
		}
	} else {
		for _, option := range adapter.Effort.Options {
			allowed[option.ID] = true
		}
	}
	if !allowed[effort] {
		return "", fmt.Errorf("effort %q is not supported for %s/%s", effort, adapter.ID, configuredModel.ID)
	}
	return effort, nil
}

func ValidAdapter(id string, includeMock bool) bool {
	_, valid := ResolveAdapter(id, includeMock)
	return valid
}

type Request struct {
	Harness           string            `json:"harness"`
	Adapter           string            `json:"adapter"`
	Model             string            `json:"model,omitempty"`
	ConfiguredModel   string            `json:"-"`
	ContextWindow     int               `json:"contextWindow,omitempty"`
	Effort            string            `json:"effort,omitempty"`
	Options           map[string]string `json:"options,omitempty"`
	Prompt            string            `json:"prompt"`
	Attachments       []Attachment      `json:"attachments,omitempty"`
	Instructions      string            `json:"instructions,omitempty"`
	SessionID         string            `json:"sessionId"`
	ResponseMessageID string            `json:"responseMessageId"`
	Session           json.RawMessage   `json:"session,omitempty"`
	ProjectPath       string            `json:"projectPath"`
	RuntimeRoot       string            `json:"runtimeRoot"`
	WebSearch         bool              `json:"webSearch,omitempty"`
	Continue          bool              `json:"continue,omitempty"`
}

type Attachment struct {
	MediaType string `json:"mediaType"`
	Filename  string `json:"filename,omitempty"`
	URL       string `json:"url"`
}

type Output struct {
	Type       string          `json:"type"`
	Chunk      json.RawMessage `json:"chunk,omitempty"`
	State      json.RawMessage `json:"state,omitempty"`
	Capability json.RawMessage `json:"capability,omitempty"`
	Message    string          `json:"error,omitempty"`
}

type Runner interface {
	Run(context.Context, Request, func(Output) error) error
}

type Canceller interface {
	Cancel(sessionID, runtimeRoot string) error
}

// Suspender parks a live turn without destroying its provider bridge. The
// worker emits a continuation state before exiting so another Dieter process
// can attach without replaying the prompt.
type Suspender interface {
	Suspend(sessionID, runtimeRoot string) error
}

//go:embed runtime/package.json runtime/package-lock.json runtime/runner.mjs runtime/claude-resilience.mjs runtime/local-attachments.mjs runtime/local-sandbox.mjs runtime/capabilities.mjs runtime/stream-reconciliation.mjs runtime/omp-capabilities-hook.mjs runtime/provider-options.mjs runtime/usage-metadata.mjs
var runtimeAssets embed.FS

type SubprocessRunner struct {
	root string
	mu   sync.Mutex
	dir  string
}

func NewSubprocessRunner(root string) *SubprocessRunner {
	return &SubprocessRunner{root: filepath.Join(root, "runtime", "harness")}
}

func stageRuntimeAssets(dir string) error {
	entries, err := runtimeAssets.ReadDir("runtime")
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		data, readErr := runtimeAssets.ReadFile("runtime/" + entry.Name())
		if readErr != nil {
			return readErr
		}
		if writeErr := os.WriteFile(filepath.Join(dir, entry.Name()), data, 0o600); writeErr != nil {
			return writeErr
		}
	}
	return nil
}

func (r *SubprocessRunner) ensure(ctx context.Context) (string, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.dir != "" {
		return r.dir, nil
	}
	if override := strings.TrimSpace(os.Getenv("DIETER_HARNESS_RUNTIME_DIR")); override != "" {
		absolute, err := filepath.Abs(override)
		if err != nil {
			return "", err
		}
		if _, err := os.Stat(filepath.Join(absolute, "runner.mjs")); err != nil {
			return "", fmt.Errorf("DIETER_HARNESS_RUNTIME_DIR: %w", err)
		}
		r.dir = absolute
		return absolute, nil
	}
	version, err := exec.CommandContext(ctx, "node", "--version").Output()
	if err != nil {
		return "", errors.New("AI SDK harnesses require Node.js 22 or newer on PATH")
	}
	if !supportedNodeVersion(string(version)) {
		return "", fmt.Errorf("AI SDK harnesses require Node.js 22.19 or newer; found %s", strings.TrimSpace(string(version)))
	}
	lock, _ := runtimeAssets.ReadFile("runtime/package-lock.json")
	sum := sha256.Sum256(lock)
	dir := filepath.Join(r.root, hex.EncodeToString(sum[:8]))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	if err := stageRuntimeAssets(dir); err != nil {
		return "", fmt.Errorf("stage AI SDK harness runtime: %w", err)
	}
	marker := filepath.Join(dir, ".installed")
	if _, err := os.Stat(marker); errors.Is(err, os.ErrNotExist) {
		command := exec.CommandContext(ctx, "npm", "ci", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund")
		command.Dir = dir
		output, installErr := command.CombinedOutput()
		if installErr != nil {
			return "", fmt.Errorf("install pinned AI SDK harness runtime: %s: %w", strings.TrimSpace(string(output)), installErr)
		}
		if err := os.WriteFile(marker, []byte("ok\n"), 0o600); err != nil {
			return "", err
		}
	}
	r.dir = dir
	return dir, nil
}

func (r *SubprocessRunner) Run(ctx context.Context, request Request, emit func(Output) error) error {
	dir, err := r.ensure(ctx)
	if err != nil {
		return err
	}
	workerToken := newWorkerToken()
	command := exec.CommandContext(ctx, "node", filepath.Join(dir, "runner.mjs"), "--board-worker-token="+workerToken)
	prepareHarnessCommand(command)
	// A suspended turn may need a few seconds to flush its provider continuation
	// state after SIGINT. Keep this below the service manager's shutdown budget,
	// but do not kill the worker before that state reaches Board.
	// runner.mjs gives a misbehaving adapter eight seconds to unwind its stream
	// and stop locally owned provider processes. Keep exec's hard-kill guard
	// just beyond that window and below Service.CancelCard's timeout.
	command.WaitDelay = 9 * time.Second
	command.Dir = dir
	command.Env = harnessEnvironment()
	stdin, err := command.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		return err
	}
	var stderr bytes.Buffer
	command.Stderr = &stderr
	if err := command.Start(); err != nil {
		return err
	}
	waited := false
	defer func() {
		if waited {
			return
		}
		// Every successfully started child must be waited on, including decode,
		// emit, and setup failures. Signal the worker first so its SDK session
		// can close the provider bridge, then retain SIGKILL as a final guard.
		_ = interruptHarnessProcess(command.Process.Pid)
		done := make(chan struct{})
		go func() {
			_ = command.Wait()
			close(done)
		}()
		select {
		case <-done:
		case <-time.After(9 * time.Second):
			_ = killHarnessProcess(command.Process.Pid)
			<-done
		}
	}()
	workerFile := filepath.Join(request.RuntimeRoot, ".dieter-worker-"+request.SessionID+".pid")
	if err := os.MkdirAll(request.RuntimeRoot, 0o700); err != nil {
		_ = command.Process.Kill()
		return err
	}
	record, _ := json.Marshal(workerRecord{PID: command.Process.Pid, OwnerPID: os.Getpid(), Token: workerToken})
	if err := os.WriteFile(workerFile, append(record, '\n'), 0o600); err != nil {
		_ = command.Process.Kill()
		return err
	}
	defer os.Remove(workerFile)
	encoded, _ := json.Marshal(request)
	if _, err := stdin.Write(append(encoded, '\n')); err != nil {
		_ = stdin.Close()
		_ = command.Process.Kill()
		waitErr := command.Wait()
		waited = true
		message := strings.TrimSpace(stderr.String())
		if message == "" && waitErr != nil {
			message = waitErr.Error()
		}
		if message == "" {
			message = err.Error()
		}
		return fmt.Errorf("start harness worker: %s", message)
	}
	_ = stdin.Close()
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64*1024), 8<<20)
	var workerError string
	var streamError string
	var stdoutDiagnostics strings.Builder
	for scanner.Scan() {
		line := bytes.TrimSpace(scanner.Bytes())
		if len(line) == 0 {
			continue
		}
		var output Output
		if err := json.Unmarshal(line, &output); err != nil {
			// Harness bootstrap commands may write package-manager progress to
			// their inherited stdout before the bridge starts. NDJSON frames
			// always begin with an object; preserve other lines as diagnostics.
			if line[0] != '{' {
				stdoutDiagnostics.Write(line)
				stdoutDiagnostics.WriteByte('\n')
				continue
			}
			_ = command.Process.Kill()
			return fmt.Errorf("decode harness worker output: %w", err)
		}
		if output.Type == "error" {
			workerError = output.Message
		}
		if output.Type == "chunk" {
			var chunk struct {
				Type      string `json:"type"`
				ErrorText string `json:"errorText"`
			}
			if json.Unmarshal(output.Chunk, &chunk) == nil && chunk.Type == "error" {
				streamError = strings.TrimSpace(chunk.ErrorText)
				// The AI SDK emits a generic UI error while the actionable ACP
				// diagnostic is written to stderr. Hold the generic chunk until the
				// process exits so the caller can persist the complete failure once.
				continue
			}
		}
		if err := emit(output); err != nil {
			_ = command.Process.Kill()
			return err
		}
	}
	scanErr := scanner.Err()
	waitErr := command.Wait()
	waited = true
	if scanErr != nil {
		return scanErr
	}
	if workerError != "" {
		if diagnostic := strings.TrimSpace(stderr.String() + "\n" + stdoutDiagnostics.String()); diagnostic != "" {
			return fmt.Errorf("%s: %s", workerError, diagnostic)
		}
		return errors.New(workerError)
	}
	if streamError != "" {
		if diagnostic := strings.TrimSpace(stderr.String() + "\n" + stdoutDiagnostics.String()); diagnostic != "" {
			return fmt.Errorf("%s: %s", streamError, diagnostic)
		}
		return errors.New(streamError)
	}
	if waitErr != nil {
		message := strings.TrimSpace(stderr.String() + "\n" + stdoutDiagnostics.String())
		if message == "" {
			message = waitErr.Error()
		}
		return fmt.Errorf("harness worker: %s", message)
	}
	return nil
}

func (r *SubprocessRunner) Cancel(sessionID, runtimeRoot string) error {
	if strings.ContainsAny(sessionID, `/\\`) {
		return errors.New("invalid harness session ID")
	}
	raw, err := os.ReadFile(filepath.Join(runtimeRoot, ".dieter-worker-"+sessionID+".pid"))
	if errors.Is(err, os.ErrNotExist) {
		return ErrNoActiveTurn
	}
	if err != nil {
		return err
	}
	path := filepath.Join(runtimeRoot, ".dieter-worker-"+sessionID+".pid")
	var record workerRecord
	if json.Unmarshal(raw, &record) != nil {
		// Pre-token worker files cannot be verified safely after PID reuse.
		_ = os.Remove(path)
		return ErrNoActiveTurn
	}
	if record.PID <= 0 || record.Token == "" {
		return errors.New("active harness worker has an invalid PID")
	}
	if !workerProcessMatches(record.PID, record.Token) {
		_ = os.Remove(path)
		return ErrNoActiveTurn
	}
	if err := interruptHarnessProcess(record.PID); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return err
	}
	deadline := time.Now().Add(9 * time.Second)
	for workerProcessMatches(record.PID, record.Token) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if workerProcessMatches(record.PID, record.Token) {
		if err := killHarnessProcess(record.PID); err != nil && !errors.Is(err, os.ErrProcessDone) {
			return err
		}
	}
	_ = os.Remove(path)
	return nil
}

func (r *SubprocessRunner) Suspend(sessionID, runtimeRoot string) error {
	if strings.ContainsAny(sessionID, `/\\`) {
		return errors.New("invalid harness session ID")
	}
	path := filepath.Join(runtimeRoot, ".dieter-worker-"+sessionID+".pid")
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return ErrNoActiveTurn
	}
	if err != nil {
		return err
	}
	var record workerRecord
	if json.Unmarshal(raw, &record) != nil || record.PID <= 0 || record.Token == "" {
		return errors.New("active harness worker has an invalid record")
	}
	if !workerProcessMatches(record.PID, record.Token) {
		_ = os.Remove(path)
		return ErrNoActiveTurn
	}
	if err := suspendHarnessProcess(record.PID); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return err
	}
	deadline := time.Now().Add(4 * time.Second)
	for workerProcessMatches(record.PID, record.Token) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if workerProcessMatches(record.PID, record.Token) {
		return errors.New("timed out waiting for the harness worker to suspend")
	}
	return nil
}

func harnessEnvironment() []string {
	allowed := map[string]bool{
		"PATH": true, "HOME": true, "USER": true, "LOGNAME": true, "TMPDIR": true, "SHELL": true, "LANG": true, "TERM": true,
		"DIETER_HARNESS_ENV": true,
		"OPENAI_API_KEY":     true, "CODEX_API_KEY": true, "OPENAI_BASE_URL": true, "CODEX_HOME": true,
		"AI_GATEWAY_API_KEY": true, "AI_GATEWAY_BASE_URL": true, "VERCEL_OIDC_TOKEN": true,
		"ANTHROPIC_API_KEY": true, "ANTHROPIC_AUTH_TOKEN": true, "ANTHROPIC_BASE_URL": true, "CLAUDE_CODE_OAUTH_TOKEN": true, "CLAUDE_CONFIG_DIR": true,
		"PI_AGENT_DIR": true, "PI_CODING_AGENT_DIR": true, "OMP_PROFILE": true,
		"NODE_EXTRA_CA_CERTS": true, "HTTP_PROXY": true, "HTTPS_PROXY": true, "NO_PROXY": true,
	}
	for _, name := range strings.Split(os.Getenv("DIETER_HARNESS_ENV"), ",") {
		if name = strings.TrimSpace(name); name != "" && !strings.Contains(name, "=") {
			allowed[name] = true
		}
	}
	result := make([]string, 0, len(allowed))
	home := os.Getenv("HOME")
	for _, item := range os.Environ() {
		name, _, _ := strings.Cut(item, "=")
		if allowed[name] {
			if name == "PATH" {
				item = "PATH=" + harnessPath(strings.TrimPrefix(item, "PATH="), home)
			}
			result = append(result, item)
		}
	}
	return result
}

func supportedNodeVersion(raw string) bool {
	parts := strings.Split(strings.TrimPrefix(strings.TrimSpace(raw), "v"), ".")
	if len(parts) < 2 {
		return false
	}
	major, majorErr := strconv.Atoi(parts[0])
	minor, minorErr := strconv.Atoi(parts[1])
	if majorErr != nil || minorErr != nil {
		return false
	}
	return major > 22 || major == 22 && minor >= 19
}

func harnessPath(current, home string) string {
	paths := filepath.SplitList(current)
	seen := make(map[string]bool, len(paths)+2)
	for _, path := range paths {
		seen[path] = true
	}
	for _, path := range []string{filepath.Join(home, ".bun", "bin"), filepath.Join(home, ".local", "bin")} {
		if home == "" || seen[path] {
			continue
		}
		if info, err := os.Stat(path); err == nil && info.IsDir() {
			paths = append([]string{path}, paths...)
			seen[path] = true
		}
	}
	return strings.Join(paths, string(os.PathListSeparator))
}

func RuntimeAssets() fs.FS { return runtimeAssets }
