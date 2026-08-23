package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/dbpprt/dieter/internal/model"
)

var (
	ErrCapacity   = errors.New("parallel session limit reached")
	ErrCardActive = errors.New("conversation has an active agent turn")
)

type RuntimeLease struct {
	ProjectID string
	BoardID   string
	CardID    string
	Agent     string
	Token     string
	PID       int
	CreatedAt string
}

func (s *Store) AcquireRuntimeLease(projectID, cardID string) (RuntimeLease, error) {
	return s.AcquireRuntimeLeaseFor(projectID, "", cardID, "")
}

func (s *Store) AcquireRuntimeLeaseFor(projectID, boardID, cardID, agent string) (RuntimeLease, error) {
	release, err := s.beginWrite()
	if err != nil {
		return RuntimeLease{}, err
	}
	defer release()
	dir := filepath.Join(s.runtimeDir(), "leases")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return RuntimeLease{}, err
	}
	path, err := runtimeLeasePath(dir, cardID)
	if err != nil {
		return RuntimeLease{}, err
	}
	project, projectErr := s.ResolveProjectIncludingArchived(projectID)
	if projectErr == nil && project.Archived {
		return RuntimeLease{}, fmt.Errorf("project %q: %w", projectID, ErrNotFound)
	}
	if projectErr != nil && !errors.Is(projectErr, ErrNotFound) {
		return RuntimeLease{}, projectErr
	}
	settings, err := s.readSettings()
	if err != nil {
		return RuntimeLease{}, err
	}
	active, err := activeRuntimeLeases(dir)
	if err != nil {
		return RuntimeLease{}, err
	}
	if countLeases(active, func(item RuntimeLease) bool { return item.CardID == cardID }) > 0 {
		return RuntimeLease{}, ErrCardActive
	}
	if settings.GlobalParallelLimit > 0 && len(active) >= settings.GlobalParallelLimit {
		return RuntimeLease{}, fmt.Errorf("%w: global limit is %d", ErrCapacity, settings.GlobalParallelLimit)
	}
	agent = strings.TrimSpace(agent)
	if limit := settings.AgentParallelLimits[agent]; agent != "" && limit > 0 && countLeases(active, func(item RuntimeLease) bool { return item.Agent == agent }) >= limit {
		return RuntimeLease{}, fmt.Errorf("%w: %s limit is %d", ErrCapacity, agent, limit)
	}
	if limit := settings.BoardParallelLimits[boardID]; boardID != "" && limit > 0 && countLeases(active, func(item RuntimeLease) bool { return item.BoardID == boardID }) >= limit {
		return RuntimeLease{}, fmt.Errorf("%w: board limit is %d", ErrCapacity, limit)
	}
	lease := RuntimeLease{ProjectID: projectID, BoardID: boardID, CardID: cardID, Agent: agent, Token: newID("lease_"), PID: os.Getpid(), CreatedAt: timestamp()}
	raw, _ := json.MarshalIndent(lease, "", "  ")
	if err := atomicWrite(path, append(raw, '\n')); err != nil {
		return RuntimeLease{}, err
	}
	return lease, nil
}

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
		return "", errors.New("invalid conversation ID for runtime lease")
	}
	return filepath.Join(dir, cardID+".json"), nil
}

// OrphanedTurnCards returns durable turns that claim to be active but have no
// lease owned by a live Dieter process. It also prunes dead-process leases via
// activeRuntimeLeases while holding the central mutation lock.
func (s *Store) OrphanedTurnCards() ([]model.Card, error) {
	release, err := s.beginWrite()
	if err != nil {
		return nil, err
	}
	defer release()
	leases, err := activeRuntimeLeases(filepath.Join(s.runtimeDir(), "leases"))
	if err != nil {
		return nil, err
	}
	active := make(map[string]bool, len(leases))
	for _, lease := range leases {
		active[lease.CardID] = true
	}
	cards, err := s.listCards()
	if err != nil {
		return nil, err
	}
	orphaned := make([]model.Card, 0)
	for _, card := range cards {
		if active[card.ID] {
			continue
		}
		status, statusErr := s.conversationStatus(card.ID)
		if statusErr != nil {
			return nil, statusErr
		}
		if card.Runtime == "running" || card.Runtime == "starting" || status == "running" || status == "starting" {
			orphaned = append(orphaned, card)
		}
	}
	return orphaned, nil
}

func (s *Store) ReleaseRuntimeLease(lease RuntimeLease) error {
	release, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer release()
	path, err := runtimeLeasePath(filepath.Join(s.runtimeDir(), "leases"), lease.CardID)
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
