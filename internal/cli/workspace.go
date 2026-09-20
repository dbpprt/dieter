package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
)

func readValidationCommands(path string) ([]model.ValidationCommand, error) {
	if strings.TrimSpace(path) == "" {
		return nil, nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var values []model.ValidationCommand
	if err := json.Unmarshal(raw, &values); err != nil {
		return nil, fmt.Errorf("decode validation commands: %w", err)
	}
	for _, value := range values {
		if strings.TrimSpace(value.Executable) == "" {
			return nil, errors.New("every validation command requires an executable")
		}
	}
	return values, nil
}

type parameterFlags map[string]string

func (values *parameterFlags) String() string {
	parts := make([]string, 0, len(*values))
	for key, value := range *values {
		parts = append(parts, key+"="+value)
	}
	return strings.Join(parts, ",")
}

func (values *parameterFlags) Set(value string) error {
	key, item, found := strings.Cut(value, "=")
	if !found || strings.TrimSpace(key) == "" {
		return errors.New("operation parameters must be KEY=VALUE")
	}
	if *values == nil {
		*values = map[string]string{}
	}
	(*values)[strings.TrimSpace(key)] = item
	return nil
}

func cloneStringMap(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	result := make(map[string]string, len(values))
	for key, value := range values {
		result[key] = value
	}
	return result
}
