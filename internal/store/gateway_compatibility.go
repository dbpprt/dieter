package store

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

type GatewayCompatibilityPolicy struct {
	GatewayReleaseVersion string `json:"gatewayReleaseVersion"`
	MinimumClientVersion  string `json:"minimumClientVersion"`
	MinimumDaemonVersion  string `json:"minimumDaemonVersion"`
	Revision              string `json:"revision"`
}

func (s *Store) gatewayCompatibilityPath() string {
	return filepath.Join(s.Root, "runtime", "gateway-compatibility.json")
}

func (s *Store) SaveGatewayCompatibilityPolicy(value GatewayCompatibilityPolicy) error {
	if value.MinimumClientVersion == "" || value.MinimumDaemonVersion == "" || value.Revision == "" {
		return errors.New("gateway compatibility policy is incomplete")
	}
	release, err := s.beginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	if err := writeJSON(s.gatewayCompatibilityPath(), value); err != nil {
		return err
	}
	s.compatibilityMu.Lock()
	s.compatibilityPolicy = &value
	s.compatibilityMu.Unlock()
	return nil
}

func (s *Store) GatewayCompatibilityPolicy() (GatewayCompatibilityPolicy, error) {
	s.compatibilityMu.RLock()
	if s.compatibilityPolicy != nil {
		value := *s.compatibilityPolicy
		s.compatibilityMu.RUnlock()
		return value, nil
	}
	s.compatibilityMu.RUnlock()
	raw, err := os.ReadFile(s.gatewayCompatibilityPath())
	if err != nil {
		return GatewayCompatibilityPolicy{}, err
	}
	var value GatewayCompatibilityPolicy
	if err := json.Unmarshal(raw, &value); err != nil {
		return value, err
	}
	if value.MinimumClientVersion == "" || value.MinimumDaemonVersion == "" || value.Revision == "" {
		return value, errors.New("gateway compatibility policy is incomplete")
	}
	s.compatibilityMu.Lock()
	s.compatibilityPolicy = &value
	s.compatibilityMu.Unlock()
	return value, nil
}
