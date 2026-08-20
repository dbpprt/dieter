package envfile

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Load imports a private .env file without replacing values explicitly
// supplied by the process environment.
func Load(root, explicit string) error {
	path := strings.TrimSpace(explicit)
	required := path != ""
	if path == "" {
		path = filepath.Join(root, ".env")
	}
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) && !required {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect environment file: %w", err)
	}
	if info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("environment file %q must have mode 0600", path)
	}
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open environment file: %w", err)
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for line := 1; scanner.Scan(); line++ {
		text := strings.TrimSpace(scanner.Text())
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		text = strings.TrimSpace(strings.TrimPrefix(text, "export "))
		key, value, ok := strings.Cut(text, "=")
		key = strings.TrimSpace(key)
		if !ok || key == "" {
			return fmt.Errorf("parse environment file %q line %d", path, line)
		}
		value = strings.TrimSpace(value)
		if len(value) >= 2 && ((value[0] == '\'' && value[len(value)-1] == '\'') || (value[0] == '"' && value[len(value)-1] == '"')) {
			if value[0] == '"' {
				decoded, decodeErr := strconv.Unquote(value)
				if decodeErr != nil {
					return fmt.Errorf("parse environment file %q line %d: %w", path, line, decodeErr)
				}
				value = decoded
			} else {
				value = value[1 : len(value)-1]
			}
		}
		if _, exists := os.LookupEnv(key); !exists {
			if err := os.Setenv(key, value); err != nil {
				return err
			}
		}
	}
	return scanner.Err()
}
