package app

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
)

func selectionFromCard(card model.Card) model.HarnessSelection {
	return model.HarnessSelection{Provider: card.Provider, Model: card.Model, Effort: card.Effort, ProviderOptions: card.ProviderOptions}
}

func supportsTurnSelection(adapter harness.Adapter, setting string) bool {
	for _, capability := range adapter.Capabilities {
		if capability.ID == setting+"-selection" && capability.Level == "between-turns" {
			return true
		}
	}
	return false
}

func resolveTurnSelection(card model.Card, provider, modelName, effort string, options map[string]string) (harness.Adapter, harness.Model, model.HarnessSelection, error) {
	provider, modelName, effort = strings.TrimSpace(provider), strings.TrimSpace(modelName), strings.TrimSpace(effort)
	started := card.InitialPromptSentAt != ""
	if started && provider != "" && provider != card.Provider {
		return harness.Adapter{}, harness.Model{}, model.HarnessSelection{}, fmt.Errorf("conversation harness is locked to %q", card.Provider)
	}
	if provider == "" {
		provider = card.Provider
	}
	if provider == "" {
		provider = "codex"
	}
	if modelName == "" {
		modelName = card.Model
	}
	adapter, configuredModel, err := harness.ResolveSelectionWithRefresh(context.Background(), provider, modelName, os.Getenv("DIETER_ENABLE_MOCK_HARNESS") == "1")
	if err != nil {
		return adapter, configuredModel, model.HarnessSelection{}, err
	}
	modelChanged := configuredModel.ID != card.Model
	if started && modelChanged && !supportsTurnSelection(adapter, "model") {
		return adapter, configuredModel, model.HarnessSelection{}, fmt.Errorf("conversation model is locked for harness %q", adapter.ID)
	}
	if effort == "" && (!modelChanged || !supportsTurnSelection(adapter, "effort")) {
		effort = card.Effort
	} else if effort == "" && modelChanged {
		effort = configuredModel.DefaultEffort
	}
	effort, err = harness.ResolveEffort(adapter, configuredModel, effort)
	if err != nil {
		return adapter, configuredModel, model.HarnessSelection{}, err
	}
	if started && effort != card.Effort && !supportsTurnSelection(adapter, "effort") {
		return adapter, configuredModel, model.HarnessSelection{}, fmt.Errorf("conversation effort is locked for harness %q", adapter.ID)
	}
	if options == nil {
		options = make(map[string]string, len(card.ProviderOptions))
		for _, option := range adapter.Options {
			if value, exists := card.ProviderOptions[option.ID]; exists && (!modelChanged || harness.OptionSupportsModel(option, configuredModel.ID)) {
				options[option.ID] = value
			}
		}
	}
	resolvedOptions, err := harness.ResolveOptionsForModel(adapter, configuredModel.ID, options)
	if err != nil {
		return adapter, configuredModel, model.HarnessSelection{}, err
	}
	if started {
		previous, resolveErr := harness.ResolveOptionsForModel(adapter, card.Model, card.ProviderOptions)
		if resolveErr != nil {
			return adapter, configuredModel, model.HarnessSelection{}, resolveErr
		}
		if err := harness.ValidateOptionUpdate(adapter, previous, resolvedOptions); err != nil {
			return adapter, configuredModel, model.HarnessSelection{}, err
		}
	}
	return adapter, configuredModel, model.HarnessSelection{Provider: adapter.ID, Model: configuredModel.ID, Effort: effort, ProviderOptions: resolvedOptions}, nil
}

func selectionEffort(selection model.HarnessSelection) string {
	if selection.Effort == "" {
		return "default"
	}
	return selection.Effort
}
