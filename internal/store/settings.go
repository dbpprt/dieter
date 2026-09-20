package store

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
	"gopkg.in/yaml.v3"
)

func defaultSettings() model.Settings {
	return dieterprompt.NormalizeSettings(model.Settings{})
}

func normalizeSettings(value model.Settings) (model.Settings, error) {
	value = dieterprompt.NormalizeSettings(value)
	if err := dieterprompt.ValidateContextTemplate(value.PromptTemplate); err != nil {
		return model.Settings{}, err
	}
	if err := dieterprompt.ValidateSkillTemplate(value.BoardSkillTemplate); err != nil {
		return model.Settings{}, fmt.Errorf("board skill template: %w", err)
	}
	if err := dieterprompt.ValidateSkillTemplate(value.ChatSkillTemplate); err != nil {
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
	// Empty templates inherit the current global templates.
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
