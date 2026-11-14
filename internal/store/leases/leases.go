package leases

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/platform/fsx"
	"github.com/dbpprt/dieter/internal/store/home"
)

// ErrCardActive reports a conversation whose agent turn holds a live lease.
var ErrCardActive = fault.New(fault.FailedPrecondition, "conversation has an active agent turn")

// RuntimeLease admits one agent turn of a conversation (runtime/leases/<card>.json).
type RuntimeLease struct {
	Detail            *model.CardDetail `json:"-"`
	SettingsRevisions map[string]string `json:"settingsRevisions,omitempty"`
	ProjectID         string
	BoardID           string
	CardID            string
	Agent             string
	Token             string
	PID               int
	CreatedAt         string
}

// CardActive reports whether a live lease holds cardID.
func (s *Store) CardActive(cardID string) (bool, error) {
	leases, err := s.Active()
	if err != nil {
		return false, err
	}
	for _, lease := range leases {
		if lease.CardID == cardID {
			return true, nil
		}
	}
	return false, nil
}

// ProjectActive reports whether a live lease holds a conversation of projectID
// other than exceptCardID.
func (s *Store) ProjectActive(projectID, exceptCardID string) (bool, error) {
	leases, err := s.Active()
	if err != nil {
		return false, err
	}
	for _, lease := range leases {
		if lease.ProjectID == projectID && lease.CardID != exceptCardID {
			return true, nil
		}
	}
	return false, nil
}

// ForCard returns the exact durable lease for a conversation. The
// token lets callers release a lease without racing a newer turn that may have
// acquired the same card after the lookup.
func (s *Store) ForCard(cardID string) (RuntimeLease, bool, error) {
	release, err := s.home.BeginWriteLock()
	if err != nil {
		return RuntimeLease{}, false, err
	}
	defer release()
	path, err := runtimeLeasePath(s.leaseDir(), cardID)
	if err != nil {
		return RuntimeLease{}, false, err
	}
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return RuntimeLease{}, false, nil
	}
	if err != nil {
		return RuntimeLease{}, false, err
	}
	var lease RuntimeLease
	if json.Unmarshal(raw, &lease) != nil || lease.CardID != strings.TrimSpace(cardID) {
		_ = os.Remove(path)
		return RuntimeLease{}, false, nil
	}
	return lease, true, nil
}

// Acquire writes a new lease for cardID unless a live one exists. The
// caller holds the writer lock (BeginWrite). admit runs after the lease path
// is validated and before the live-lease check; describe completes the lease
// before it is written.
func (s *Store) Acquire(projectID, boardID, cardID, agent string, admit func() error, describe func(*RuntimeLease) error) (RuntimeLease, error) {
	dir := s.leaseDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return RuntimeLease{}, err
	}
	path, err := runtimeLeasePath(dir, cardID)
	if err != nil {
		return RuntimeLease{}, err
	}
	if err := admit(); err != nil {
		return RuntimeLease{}, err
	}
	active, err := activeRuntimeLeases(dir)
	if err != nil {
		return RuntimeLease{}, err
	}
	if countLeases(active, func(item RuntimeLease) bool { return item.CardID == cardID }) > 0 {
		return RuntimeLease{}, ErrCardActive
	}
	agent = strings.TrimSpace(agent)
	lease := RuntimeLease{ProjectID: projectID, BoardID: boardID, CardID: cardID, Agent: agent, Token: home.NewID("lease_"), PID: os.Getpid(), CreatedAt: home.Timestamp()}
	if err := describe(&lease); err != nil {
		return RuntimeLease{}, err
	}
	raw, _ := json.MarshalIndent(lease, "", "  ")
	if err := fsx.WriteFile(path, append(raw, '\n'), 0o600); err != nil {
		return RuntimeLease{}, err
	}
	return lease, nil
}

// leaseDir holds one lease file per conversation with an active turn.
func (s *Store) leaseDir() string { return filepath.Join(s.home.RuntimeDir(), "leases") }

// Active returns the leases owned by live processes, removing the rest.
func (s *Store) Active() ([]RuntimeLease, error) { return activeRuntimeLeases(s.leaseDir()) }

func activeRuntimeLeases(dir string) ([]RuntimeLease, error) {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	result := make([]RuntimeLease, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		raw, readErr := os.ReadFile(path)
		if readErr != nil {
			return nil, readErr
		}
		var lease RuntimeLease
		if json.Unmarshal(raw, &lease) != nil || !processAlive(lease.PID) {
			_ = os.Remove(path)
			continue
		}
		result = append(result, lease)
	}
	return result, nil
}

func countLeases(items []RuntimeLease, match func(RuntimeLease) bool) int {
	count := 0
	for _, item := range items {
		if match(item) {
			count++
		}
	}
	return count
}

func runtimeLeasePath(dir, cardID string) (string, error) {
	cardID = strings.TrimSpace(cardID)
	if cardID == "" || filepath.Base(cardID) != cardID || strings.ContainsAny(cardID, `/\\`) {
		return "", fault.New(fault.Invalid, "invalid conversation ID for runtime lease")
	}
	return filepath.Join(dir, cardID+".json"), nil
}

// Release removes lease unless a newer turn of the same card replaced it.
func (s *Store) Release(lease RuntimeLease) error {
	release, err := s.home.BeginWrite()
	if err != nil {
		return err
	}
	defer release()
	path, err := runtimeLeasePath(s.leaseDir(), lease.CardID)
	if err != nil {
		return err
	}
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	var current RuntimeLease
	if json.Unmarshal(raw, &current) == nil && current.Token != lease.Token {
		return nil
	}
	return os.Remove(path)
}

func processAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}
