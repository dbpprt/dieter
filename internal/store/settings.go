package store

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/dbpprt/nauclio/internal/model"
	nauclioprompt "github.com/dbpprt/nauclio/internal/prompt"
	"gopkg.in/yaml.v3"
)

func defaultSettings() model.Settings {
	return nauclioprompt.NormalizeSettings(model.Settings{
		AgentParallelLimits: map[string]int{},
		BoardParallelLimits: map[string]int{},
	})
}

func normalizeSettings(value model.Settings) (model.Settings, error) {
	value = nauclioprompt.NormalizeSettings(value)
	if value.GlobalParallelLimit < 0 {
		return model.Settings{}, errors.New("global parallel limit cannot be negative")
	}
	if value.AgentParallelLimits == nil {
		value.AgentParallelLimits = map[string]int{}
	}
	if value.BoardParallelLimits == nil {
		value.BoardParallelLimits = map[string]int{}
	}
	for key, limit := range value.AgentParallelLimits {
		clean := strings.TrimSpace(key)
		if clean == "" || limit < 0 {
			return model.Settings{}, errors.New("agent limits require a non-empty ID and a non-negative value")
		}
		if clean != key {
			delete(value.AgentParallelLimits, key)
			value.AgentParallelLimits[clean] = limit
		}
	}
	for key, limit := range value.BoardParallelLimits {
		clean := strings.TrimSpace(key)
		if clean == "" || limit < 0 {
			return model.Settings{}, errors.New("board limits require a non-empty ID and a non-negative value")
		}
		if clean != key {
			delete(value.BoardParallelLimits, key)
			value.BoardParallelLimits[clean] = limit
		}
	}
	if err := nauclioprompt.ValidateContextTemplate(value.PromptTemplate); err != nil {
		return model.Settings{}, err
	}
	if err := nauclioprompt.ValidateSkillTemplate(value.BoardSkillTemplate); err != nil {
		return model.Settings{}, fmt.Errorf("board skill template: %w", err)
	}
	if err := nauclioprompt.ValidateSkillTemplate(value.ChatSkillTemplate); err != nil {
		return model.Settings{}, fmt.Errorf("chat skill template: %w", err)
	}
	return value, nil
}

func (s *Store) readSettings() (model.Settings, error) {
	data, err := os.ReadFile(s.settingsPath())
	if errors.Is(err, os.ErrNotExist) {
		return defaultSettings(), nil
	}
	if err != nil {
		return model.Settings{}, err
	}
	value := defaultSettings()
	if err := yaml.Unmarshal(data, &value); err != nil {
		return model.Settings{}, err
	}
	return normalizeSettings(value)
}

func (s *Store) Settings() (model.Settings, error) {
	return s.readSettings()
}

func (s *Store) UpdateSettings(value model.Settings) (model.Settings, error) {
	current, err := s.readSettings()
	if err != nil {
		return model.Settings{}, err
	}
	// Older clients only know admission settings. Keep prompt configuration
	// intact when those clients save their view of Settings.
	if strings.TrimSpace(value.PromptTemplate) == "" {
		value.PromptTemplate = current.PromptTemplate
	}
	if strings.TrimSpace(value.BoardSkillTemplate) == "" {
		value.BoardSkillTemplate = current.BoardSkillTemplate
	}
	if strings.TrimSpace(value.ChatSkillTemplate) == "" {
		value.ChatSkillTemplate = current.ChatSkillTemplate
	}
	normalized, err := normalizeSettings(value)
	if err != nil {
		return model.Settings{}, err
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Settings{}, err
	}
	defer release()
	normalized.UpdatedAt = timestamp()
	data, err := yaml.Marshal(normalized)
	if err != nil {
		return model.Settings{}, err
	}
	if err := atomicWrite(s.settingsPath(), data); err != nil {
		return model.Settings{}, err
	}
	return normalized, nil
}

func (s *Store) UpdatePromptSettings(promptTemplate, boardSkillTemplate, chatSkillTemplate string) (model.Settings, error) {
	current, err := s.readSettings()
	if err != nil {
		return model.Settings{}, err
	}
	current.PromptTemplate = promptTemplate
	current.BoardSkillTemplate = boardSkillTemplate
	current.ChatSkillTemplate = chatSkillTemplate
	return s.UpdateSettings(current)
}
