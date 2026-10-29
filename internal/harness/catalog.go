package harness

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/harness/catalog"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"gopkg.in/yaml.v3"
)

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

const embeddedCatalogSource = "embedded internal/harness/catalog/harnesses.yaml"

// CatalogOptions configures one daemon's harness catalog.
type CatalogOptions struct {
	// Path is a local registry YAML. Empty uses the embedded release catalog.
	Path string
	// Mock registers the mock harness (DIETER_ENABLE_MOCK_HARNESS) for
	// isolated fixtures and tests.
	Mock bool
	// Static keeps the configured models and never runs provider discovery.
	// Isolated fixtures use it to retain release choices without launching
	// provider CLIs or installing runtimes.
	Static bool
	// Root is DIETER_HOME; discovery prepares pinned runtimes beneath it.
	Root string
	// Environment is the host environment discovery commands inherit.
	Environment Environment
}

// Catalog is one daemon's harness registry: the configured adapters, the
// last-known-good discovered models, and whether the mock harness exists.
// All state is per instance so daemons and tests can coexist in a process.
type Catalog struct {
	mu         sync.RWMutex
	configured []Adapter
	source     string
	discovered []Adapter
	mock       bool
	static     bool
	root       string
	env        Environment

	discoveryMu      sync.Mutex
	discoveryUpdated time.Time
	targetedMu       sync.Mutex
	targetedCalls    map[string]*targetedDiscoveryCall

	// Discovery seams; tests replace them on their own catalog.
	discoverProvider func(context.Context, string) ([]Model, error)
	runDiscovery     func(context.Context, string, ...string) ([]byte, error)
	runOMPDiscovery  func(context.Context) ([]byte, error)
	runDSHDiscovery  func(context.Context) ([]byte, error)
}

// NewCatalog loads the configured registry. An empty options.Path uses the
// embedded release catalog.
func NewCatalog(options CatalogOptions) (*Catalog, error) {
	data := catalog.YAML
	source := embeddedCatalogSource
	if path := strings.TrimSpace(options.Path); path != "" {
		absolute, err := filepath.Abs(path)
		if err != nil {
			return nil, fmt.Errorf("resolve harness config: %w", err)
		}
		data, err = os.ReadFile(absolute)
		if err != nil {
			return nil, fmt.Errorf("read harness config %q: %w", absolute, err)
		}
		source = absolute
	}
	items, err := LoadCatalog(data)
	if err != nil {
		return nil, fmt.Errorf("invalid harness config %q: %w", source, err)
	}
	c := &Catalog{
		configured: items, source: source, mock: options.Mock, static: options.Static,
		root: options.Root, env: options.Environment, targetedCalls: map[string]*targetedDiscoveryCall{},
	}
	c.discoverProvider = c.discoverModels
	c.runDiscovery = c.runDiscoveryCommand
	c.runOMPDiscovery = c.runOMPDiscoveryCommand
	c.runDSHDiscovery = c.runDSHDiscoveryCommand
	return c, nil
}

// DefaultCatalog is the embedded release catalog with discovery under root.
func DefaultCatalog(root string, mock bool) *Catalog {
	c, err := NewCatalog(CatalogOptions{Root: root, Mock: mock})
	if err != nil {
		panic("invalid " + embeddedCatalogSource + ": " + err.Error())
	}
	return c
}

// StaticCatalog is the embedded release catalog without provider discovery.
func StaticCatalog(mock bool) *Catalog {
	c, err := NewCatalog(CatalogOptions{Mock: mock, Static: true})
	if err != nil {
		panic("invalid " + embeddedCatalogSource + ": " + err.Error())
	}
	return c
}

// StaticCatalogOf is a discovery-free catalog of explicit adapters for
// isolated tests and fixtures.
func StaticCatalogOf(adapters []Adapter, mock bool) *Catalog {
	c := StaticCatalog(mock)
	c.configured = make([]Adapter, len(adapters))
	for index, adapter := range adapters {
		c.configured[index] = cloneAdapter(adapter)
	}
	c.source = "static"
	return c
}

// Source is the registry path, or the embedded catalog's description.
func (c *Catalog) Source() string {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.source
}

// Mock reports whether the mock harness is registered.
func (c *Catalog) Mock() bool { return c.mock }

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
			return nil, fault.New(fault.Invalid, "multiple YAML documents are not supported")
		}
		return nil, err
	}
	if document.Version != 1 {
		return nil, fault.Invalidf("unsupported registry version %d", document.Version)
	}
	if len(document.Harnesses) == 0 {
		return nil, fault.New(fault.Invalid, "at least one harness is required")
	}
	seenHarnesses := map[string]bool{}
	for index := range document.Harnesses {
		harness := &document.Harnesses[index]
		harness.ID, harness.Name = strings.TrimSpace(harness.ID), strings.TrimSpace(harness.Name)
		harness.Runtime, harness.DefaultModel = strings.TrimSpace(harness.Runtime), strings.TrimSpace(harness.DefaultModel)
		if harness.ID == "" || harness.Name == "" || harness.Runtime == "" {
			return nil, fault.Invalidf("harness %d requires id, name, and adapter", index)
		}
		if seenHarnesses[harness.ID] {
			return nil, fault.Invalidf("duplicate harness %q", harness.ID)
		}
		seenHarnesses[harness.ID] = true
		seenCapabilities := map[string]bool{}
		for capabilityIndex := range harness.Capabilities {
			capability := &harness.Capabilities[capabilityIndex]
			capability.ID, capability.Level = strings.TrimSpace(capability.ID), strings.TrimSpace(capability.Level)
			if capability.ID == "" || capability.Level == "" || seenCapabilities[capability.ID] {
				return nil, fault.Invalidf("harness %q has invalid capability %d", harness.ID, capabilityIndex)
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
				return nil, fault.Invalidf("harness %q has invalid provider option %d", harness.ID, optionIndex)
			}
			seenOptions[option.ID] = true
			switch option.Type {
			case "boolean":
				if option.Default == "" {
					option.Default = "false"
				}
				if option.Default != "true" && option.Default != "false" {
					return nil, fault.Invalidf("harness %q option %q has invalid boolean default %q", harness.ID, option.ID, option.Default)
				}
				if len(option.Choices) > 0 {
					return nil, fault.Invalidf("harness %q boolean option %q cannot have choices", harness.ID, option.ID)
				}
			case "enum":
				seenChoices := map[string]bool{}
				for choiceIndex := range option.Choices {
					choice := &option.Choices[choiceIndex]
					choice.Value, choice.Name = strings.TrimSpace(choice.Value), strings.TrimSpace(choice.Name)
					if choice.Value == "" || choice.Name == "" || seenChoices[choice.Value] {
						return nil, fault.Invalidf("harness %q option %q has invalid choice %d", harness.ID, option.ID, choiceIndex)
					}
					seenChoices[choice.Value] = true
				}
				if len(option.Choices) == 0 || (option.Default != "" && !seenChoices[option.Default]) {
					return nil, fault.Invalidf("harness %q enum option %q requires choices and a valid default", harness.ID, option.ID)
				}
			case "string":
				if len(option.Choices) > 0 {
					return nil, fault.Invalidf("harness %q string option %q cannot have choices", harness.ID, option.ID)
				}
			default:
				return nil, fault.Invalidf("harness %q option %q has unsupported type %q", harness.ID, option.ID, option.Type)
			}
		}
		efforts := map[string]bool{}
		if harness.Effort != nil {
			harness.Effort.Label = strings.TrimSpace(harness.Effort.Label)
			if harness.Effort.Label == "" || len(harness.Effort.Options) == 0 {
				return nil, fault.Invalidf("harness %q effort requires a label and options", harness.ID)
			}
			for optionIndex := range harness.Effort.Options {
				option := &harness.Effort.Options[optionIndex]
				option.ID, option.Name = strings.TrimSpace(option.ID), strings.TrimSpace(option.Name)
				if option.ID == "" || option.Name == "" || efforts[option.ID] {
					return nil, fault.Invalidf("harness %q has invalid effort option %d", harness.ID, optionIndex)
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
				return nil, fault.Invalidf("harness %q has invalid model %d", harness.ID, modelIndex)
			}
			if seenModels[model.ID] {
				return nil, fault.Invalidf("harness %q has duplicate model %q", harness.ID, model.ID)
			}
			seenModels[model.ID] = true
			if model.DefaultEffort != "" && !efforts[model.DefaultEffort] {
				return nil, fault.Invalidf("harness %q model %q has unknown default effort %q", harness.ID, model.ID, model.DefaultEffort)
			}
			seenModelEfforts := map[string]bool{}
			for effortIndex := range model.Efforts {
				model.Efforts[effortIndex] = strings.TrimSpace(model.Efforts[effortIndex])
				if !efforts[model.Efforts[effortIndex]] || seenModelEfforts[model.Efforts[effortIndex]] {
					return nil, fault.Invalidf("harness %q model %q has invalid effort %q", harness.ID, model.ID, model.Efforts[effortIndex])
				}
				seenModelEfforts[model.Efforts[effortIndex]] = true
			}
			if model.DefaultEffort != "" && len(model.Efforts) > 0 && !seenModelEfforts[model.DefaultEffort] {
				return nil, fault.Invalidf("harness %q model %q default effort %q is not allowed", harness.ID, model.ID, model.DefaultEffort)
			}
		}
		if harness.DefaultModel != "" && !seenModels[harness.DefaultModel] {
			return nil, fault.Invalidf("harness %q default model %q is not registered", harness.ID, harness.DefaultModel)
		}
		for optionIndex := range harness.Options {
			option := &harness.Options[optionIndex]
			seenOptionModels := map[string]bool{}
			for modelIndex := range option.Models {
				option.Models[modelIndex] = strings.TrimSpace(option.Models[modelIndex])
				modelID := option.Models[modelIndex]
				if !seenModels[modelID] || seenOptionModels[modelID] {
					return nil, fault.Invalidf("harness %q option %q has invalid model %q", harness.ID, option.ID, modelID)
				}
				seenOptionModels[modelID] = true
			}
		}
	}
	return document.Harnesses, nil
}

// Adapters returns a copy of the current catalog: discovered models when
// discovery succeeded, otherwise the configured ones, plus the mock harness
// when it is registered.
func (c *Catalog) Adapters() []Adapter {
	c.mu.RLock()
	source := c.configured
	if len(c.discovered) > 0 {
		source = c.discovered
	}
	items := make([]Adapter, len(source))
	for index, item := range source {
		items[index] = cloneAdapter(item)
	}
	c.mu.RUnlock()
	if c.mock {
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
		adapter.Options[index].Models = append([]string(nil), adapter.Options[index].Models...)
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

// ResolveOptions validates provider-specific values for the adapter's default
// model and materializes defaults. Call ResolveOptionsForModel when the model
// has already been resolved.
func ResolveOptions(adapter Adapter, requested map[string]string) (map[string]string, error) {
	return ResolveOptionsForModel(adapter, adapter.DefaultModel, requested)
}

// OptionSupportsModel reports whether an option applies to a model. An empty
// model list means the provider option applies to every model in the adapter.
func OptionSupportsModel(option ProviderOption, modelID string) bool {
	if len(option.Models) == 0 {
		return true
	}
	for _, supportedModel := range option.Models {
		if supportedModel == modelID {
			return true
		}
	}
	return false
}

// ResolveOptionsForModel validates provider-specific values and materializes
// defaults only for options supported by the selected model. A persisted
// unsupported value equal to the option default is ignored for compatibility
// with conversations created before model-scoped options were advertised.
func ResolveOptionsForModel(adapter Adapter, modelID string, requested map[string]string) (map[string]string, error) {
	modelID = strings.TrimSpace(modelID)
	if modelID == "" {
		modelID = adapter.DefaultModel
	}
	definitions := make(map[string]ProviderOption, len(adapter.Options))
	resolved := make(map[string]string, len(adapter.Options))
	for _, option := range adapter.Options {
		definitions[option.ID] = option
		if OptionSupportsModel(option, modelID) && option.Default != "" {
			resolved[option.ID] = option.Default
		}
	}
	for rawID, rawValue := range requested {
		id, value := strings.TrimSpace(rawID), strings.TrimSpace(rawValue)
		option, ok := definitions[id]
		if !ok {
			return nil, fault.Invalidf("option %q is not supported for harness %q", id, adapter.ID)
		}
		if !OptionSupportsModel(option, modelID) {
			if value == strings.TrimSpace(option.Default) {
				continue
			}
			return nil, fault.Invalidf("option %q is not supported for model %q of harness %q", id, modelID, adapter.ID)
		}
		switch option.Type {
		case "boolean":
			if value != "true" && value != "false" {
				return nil, fault.Invalidf("option %q for harness %q must be true or false", id, adapter.ID)
			}
		case "enum":
			valid := false
			for _, choice := range option.Choices {
				valid = valid || choice.Value == value
			}
			if !valid {
				return nil, fault.Invalidf("option %q value %q is not supported for harness %q", id, value, adapter.ID)
			}
		case "string":
		}
		resolved[id] = value
	}
	return resolved, nil
}

// ValidateOptionUpdate permits a provider-defined mutable option to change
// between turns while keeping session-defining options locked. Both maps must
// already have been materialized with ResolveOptions.
func ValidateOptionUpdate(adapter Adapter, current, next map[string]string) error {
	for _, option := range adapter.Options {
		if !option.Mutable && current[option.ID] != next[option.ID] {
			return fault.Invalidf("conversation provider options are locked: %q cannot change", option.ID)
		}
	}
	return nil
}

func (c *Catalog) ResolveAdapter(id string) (Adapter, bool) {
	for _, adapter := range c.Adapters() {
		if adapter.ID == id {
			return adapter, true
		}
	}
	return Adapter{}, false
}

func (c *Catalog) ResolveSelection(providerID, modelID string) (Adapter, Model, error) {
	adapter, valid := c.ResolveAdapter(strings.TrimSpace(providerID))
	if !valid {
		return Adapter{}, Model{}, fault.Invalidf("unsupported harness %q", providerID)
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
	return Adapter{}, Model{}, fault.Invalidf("model %q is not registered for harness %q", modelID, adapter.ID)
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
		return "", fault.Invalidf("harness %q does not support configurable effort", adapter.ID)
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
		return "", fault.Invalidf("effort %q is not supported for %s/%s", effort, adapter.ID, configuredModel.ID)
	}
	return effort, nil
}

func (c *Catalog) Valid(id string) bool {
	_, valid := c.ResolveAdapter(id)
	return valid
}
