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
	"github.com/dbpprt/dieter/internal/peerstore"
)

var (
	ErrCardActive = errors.New("conversation has an active agent turn")
)

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

func (s *Store) AcquireRuntimeLease(projectID, cardID string) (RuntimeLease, error) {
	return s.AcquireRuntimeLeaseFor(projectID, "", cardID, "")
}

func (s *Store) CardHasRuntimeLease(cardID string) (bool, error) {
	leases, err := activeRuntimeLeases(filepath.Join(s.runtimeDir(), "leases"))
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

func (s *Store) ProjectHasRuntimeLease(projectID, exceptCardID string) (bool, error) {
	leases, err := activeRuntimeLeases(filepath.Join(s.runtimeDir(), "leases"))
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

// ProjectCheckoutHasRuntimeLease reports only turns that execute in the
// registered project directory. Worktree turns in the same project do not
// share its index or working tree and must not block checkout-scoped actions.
func (s *Store) ProjectCheckoutHasRuntimeLease(projectID, exceptCardID string, checkoutIDs ...string) (bool, error) {
	leases, err := activeRuntimeLeases(filepath.Join(s.runtimeDir(), "leases"))
	if err != nil {
		return false, err
	}
	for _, lease := range leases {
		if s.canonicalProjectRef(lease.ProjectID) != projectID || lease.CardID == exceptCardID {
			continue
		}
		if len(checkoutIDs) > 0 && checkoutIDs[0] != "" {
			card, e := s.ResolveCard(lease.CardID)
			if e != nil || card.CheckoutID != checkoutIDs[0] {
				continue
			}
		}
		mode := ""
		if value, workspaceErr := s.WorkspaceByCardID(lease.CardID); workspaceErr == nil {
			mode = value.Mode
		} else if card, cardErr := s.ResolveCard(lease.CardID); cardErr == nil {
			mode = card.WorkspaceMode
		}
		canonical, ok := model.CanonicalWorkspaceMode(mode)
		if ok && canonical == model.WorkspaceModeProject {
			return true, nil
		}
	}
	return false, nil
}

// RuntimeLeaseForCard returns the exact durable lease for a conversation. The
// token lets callers release a lease without racing a newer turn that may have
// acquired the same card after the lookup.
func (s *Store) RuntimeLeaseForCard(cardID string) (RuntimeLease, bool, error) {
	release, err := s.beginWriteLock()
	if err != nil {
		return RuntimeLease{}, false, err
	}
	defer release()
	path, err := runtimeLeasePath(filepath.Join(s.runtimeDir(), "leases"), cardID)
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

func (s *Store) AcquireRuntimeLeaseFor(projectID, boardID, cardID, agent string) (RuntimeLease, error) {
	release, err := s.beginWrite()
	if err != nil {
		return RuntimeLease{}, err
	}
	defer release()
	if card, resolveErr := s.ResolveCard(cardID); resolveErr == nil {
		if err := s.RequireLocalCard(card); err != nil {
			return RuntimeLease{}, err
		}
		if card.MergedIntoCardID != "" {
			return RuntimeLease{}, errors.New("card has been merged into another conversation")
		}
		if len(card.ConflictKeys) > 0 {
			for _, key := range card.ConflictKeys {
				if strings.Contains(key, "identity") {
					return RuntimeLease{}, errors.New("conversation identity conflict")
				}
			}
		}
	}
	if project, err := s.ResolveProject(projectID); err == nil {
		for _, key := range project.ConflictKeys {
			if strings.HasSuffix(key, ".prompt") || strings.HasSuffix(key, ".promptTemplate") || strings.HasSuffix(key, ".archived") || strings.HasSuffix(key, ".consolidatedInto") {
				return RuntimeLease{}, fmt.Errorf("unresolved execution settings: %s", key)
			}
		}
	}
	if boardID != "" {
		if board, err := s.ResolveBoard(projectID, boardID); err == nil {
			for _, key := range board.ConflictKeys {
				if !strings.HasSuffix(key, ".name") && !strings.HasSuffix(key, ".color") && !strings.HasSuffix(key, ".description") {
					return RuntimeLease{}, fmt.Errorf("unresolved execution settings: %s", key)
				}
			}
		}
	}
	dir := filepath.Join(s.runtimeDir(), "leases")
	if err := os.MkdirAll(dir, 0o700); err != nil {
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
	active, err := activeRuntimeLeases(dir)
	if err != nil {
		return RuntimeLease{}, err
	}
	if countLeases(active, func(item RuntimeLease) bool { return item.CardID == cardID }) > 0 {
		return RuntimeLease{}, ErrCardActive
	}
	agent = strings.TrimSpace(agent)
	lease := RuntimeLease{ProjectID: projectID, BoardID: boardID, CardID: cardID, Agent: agent, Token: newID("lease_"), PID: os.Getpid(), CreatedAt: timestamp()}
	if detail, detailErr := s.CardDetail(cardID); detailErr == nil {
		lease.Detail = &detail
		_, data, e := s.sharedData()
		if e != nil {
			return RuntimeLease{}, e
		}
		lease.SettingsRevisions = map[string]string{}
		for _, domain := range []struct{ kind, id string }{{"project", detail.Project.ID}, {"board", detail.Board.ID}, {"item", cardID}} {
			for field := range peerstore.DomainFields[domain.kind] {
				key := peerstore.Key(domain.kind, domain.id+"."+field)
				if record, ok := data.Records[key]; ok {
					lease.SettingsRevisions[key] = record.Revision()
				}
			}
		}
		for _, label := range detail.Card.LabelIDs {
			key := peerstore.Key("label", label+".instructions")
			lease.SettingsRevisions[key] = data.Records[key].Revision()
		}
	}
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
// lease owned by a live Dieter process. Cold directory/status reads happen
// outside writer admission; only lease pruning and final candidate validation
// hold the central lock. An idle maintenance sweep must not block all messages.
func (s *Store) OrphanedTurnCards() ([]model.Card, error) {
	release, err := s.beginWriteLock()
	if err != nil {
		return nil, err
	}
	leases, err := activeRuntimeLeases(filepath.Join(s.runtimeDir(), "leases"))
	release()
	if err != nil {
		return nil, err
	}
	active := make(map[string]bool, len(leases))
	for _, lease := range leases {
		active[lease.CardID] = true
	}
	cards, err := s.listCards(false)
	if err != nil {
		return nil, err
	}
	if len(cards) == 0 {
		return nil, nil
	}
	identity, err := s.PeerIdentity()
	if err != nil {
		return nil, err
	}
	orphaned := make([]model.Card, 0)
	for _, card := range cards {
		if active[card.ID] || card.OwnerDaemonID != identity.DaemonID {
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
	if len(orphaned) == 0 {
		return orphaned, nil
	}
	// A turn may have acquired a lease while the directory was being scanned.
	release, err = s.beginWriteLock()
	if err != nil {
		return nil, err
	}
	defer release()
	leases, err = activeRuntimeLeases(filepath.Join(s.runtimeDir(), "leases"))
	if err != nil {
		return nil, err
	}
	active = make(map[string]bool, len(leases))
	for _, lease := range leases {
		active[lease.CardID] = true
	}
	verified := orphaned[:0]
	for _, card := range orphaned {
		if active[card.ID] {
			continue
		}
		current, err := s.ResolveCard(card.ID)
		if errors.Is(err, ErrNotFound) {
			continue
		}
		if err != nil {
			return nil, err
		}
		status, err := s.conversationStatus(card.ID)
		if err != nil {
			return nil, err
		}
		if current.Runtime == "running" || current.Runtime == "starting" || status == "running" || status == "starting" {
			verified = append(verified, current)
		}
	}
	return verified, nil
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
