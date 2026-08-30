package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type clientSession struct {
	AccessToken string `json:"accessToken"`
	ExpiresAt   string `json:"expiresAt"`
	Login       string `json:"login"`
}

type clientConfig struct {
	DefaultGateway string                   `json:"defaultGateway,omitempty"`
	Sessions       map[string]clientSession `json:"sessions,omitempty"`
}

func clientConfigPath(root string) string { return filepath.Join(root, "auth", "client.json") }

func normalizeGatewayURL(value string) (string, error) {
	value = strings.TrimRight(strings.TrimSpace(value), "/")
	if value == "" {
		return "", errors.New("gateway URL is required")
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || (parsed.Path != "" && parsed.Path != "/") || (parsed.Scheme != "https" && parsed.Scheme != "http") {
		return "", errors.New("gateway URL must use https or http")
	}
	return parsed.Scheme + "://" + parsed.Host, nil
}

func loadClientConfig(root string) (clientConfig, error) {
	result := clientConfig{Sessions: map[string]clientSession{}}
	raw, err := os.ReadFile(clientConfigPath(root))
	if errors.Is(err, os.ErrNotExist) {
		return result, nil
	}
	if err != nil {
		return result, err
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return result, fmt.Errorf("decode Dieter CLI credentials: %w", err)
	}
	if result.Sessions == nil {
		result.Sessions = map[string]clientSession{}
	}
	return result, nil
}

func saveClientConfig(root string, value clientConfig) error {
	directory := filepath.Dir(clientConfigPath(root))
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		return err
	}
	lock := filepath.Join(directory, ".client-lock")
	deadline := time.Now().Add(10 * time.Second)
	for {
		err := os.Mkdir(lock, 0o700)
		if err == nil {
			break
		}
		if !errors.Is(err, os.ErrExist) {
			return err
		}
		if info, statErr := os.Stat(lock); statErr == nil && time.Since(info.ModTime()) > 30*time.Second {
			_ = os.Remove(lock)
			continue
		}
		if time.Now().After(deadline) {
			return errors.New("timed out waiting for another Dieter CLI credential writer")
		}
		time.Sleep(20 * time.Millisecond)
	}
	defer os.Remove(lock)
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, ".client-*.json")
	if err != nil {
		return err
	}
	name := temporary.Name()
	defer os.Remove(name)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(append(raw, '\n')); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(name, clientConfigPath(root))
}

func (value clientSession) valid(now time.Time) bool {
	if strings.TrimSpace(value.AccessToken) == "" {
		return false
	}
	expires, err := time.Parse(time.RFC3339Nano, value.ExpiresAt)
	return err == nil && expires.After(now.UTC().Add(30*time.Second))
}
