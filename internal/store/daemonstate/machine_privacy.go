package daemonstate

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/home"
)

// Store holds this daemon's local operational state under DIETER_HOME:
// privacy intent for the current boot, the gateway's compatibility policy,
// and the automatic-update receipt. None of it is replicated.
type Store struct {
	store *store.Store

	compatibilityMu     sync.RWMutex
	compatibilityPolicy *GatewayCompatibilityPolicy
}

// New returns the daemon state of data. Share one instance per daemon: it
// caches the compatibility policy the API enforces.
func New(data *store.Store) *Store { return &Store{store: data} }

// MachinePrivacyRequest belongs to this execution host and this boot alone.
// It is deliberately outside the replicated peer store.
type MachinePrivacyRequest struct {
	BootID  string `json:"bootId"`
	Enabled bool   `json:"enabled"`
}

func (s *Store) MachinePrivacyRequest() (MachinePrivacyRequest, error) {
	var value MachinePrivacyRequest
	raw, err := os.ReadFile(filepath.Join(s.store.Root, "runtime", "machine-privacy.json"))
	if errors.Is(err, os.ErrNotExist) {
		return value, nil
	}
	if err != nil {
		return value, err
	}
	err = json.Unmarshal(raw, &value)
	return value, err
}

func (s *Store) SetMachinePrivacyRequest(value MachinePrivacyRequest) error {
	if value.BootID == "" {
		return fault.New(fault.Invalid, "privacy requires a boot identity")
	}
	release, err := s.store.BeginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	return home.WriteJSON(filepath.Join(s.store.Root, "runtime", "machine-privacy.json"), value)
}
