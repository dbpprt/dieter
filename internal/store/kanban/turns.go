package kanban

import (
	"errors"
	"fmt"
	"strings"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/leases"
)

func (s *Store) AcquireRuntimeLease(projectID, cardID string) (leases.RuntimeLease, error) {
	return s.AcquireRuntimeLeaseFor(projectID, "", cardID, "")
}

func (s *Store) AcquireRuntimeLeaseFor(projectID, boardID, cardID, agent string) (leases.RuntimeLease, error) {
	release, err := s.home.BeginWrite()
	if err != nil {
		return leases.RuntimeLease{}, err
	}
	defer release()
	if card, resolveErr := s.ResolveCard(cardID); resolveErr == nil {
		if err := s.RequireLocalCard(card); err != nil {
			return leases.RuntimeLease{}, err
		}
		if card.MergedIntoCardID != "" {
			return leases.RuntimeLease{}, fault.New(fault.Invalid, "card has been merged into another conversation")
		}
		if len(card.ConflictKeys) > 0 {
			for _, key := range card.ConflictKeys {
				if strings.Contains(key, "identity") {
					return leases.RuntimeLease{}, fault.New(fault.Invalid, "conversation identity conflict")
				}
			}
		}
	}
	if project, err := s.ResolveProject(projectID); err == nil {
		for _, key := range project.ConflictKeys {
			if strings.HasSuffix(key, ".prompt") || strings.HasSuffix(key, ".promptTemplate") || strings.HasSuffix(key, ".archived") || strings.HasSuffix(key, ".consolidatedInto") {
				return leases.RuntimeLease{}, fault.Invalidf("unresolved execution settings: %s", key)
			}
		}
	}
	if boardID != "" {
		if board, err := s.ResolveBoard(projectID, boardID); err == nil {
			for _, key := range board.ConflictKeys {
				if !strings.HasSuffix(key, ".name") && !strings.HasSuffix(key, ".color") && !strings.HasSuffix(key, ".description") {
					return leases.RuntimeLease{}, fault.Invalidf("unresolved execution settings: %s", key)
				}
			}
		}
	}
	admit := func() error {
		project, projectErr := s.ResolveProjectIncludingArchived(projectID)
		if projectErr == nil && project.Archived {
			return fmt.Errorf("project %q: %w", projectID, home.ErrNotFound)
		}
		if projectErr != nil && !errors.Is(projectErr, home.ErrNotFound) {
			return projectErr
		}
		return nil
	}
	describe := func(lease *leases.RuntimeLease) error {
		detail, detailErr := s.CardDetail(cardID)
		if detailErr != nil {
			return nil
		}
		lease.Detail = &detail
		_, data, e := s.replica.Snapshot()
		defer data.Close()
		if e != nil {
			return e
		}
		lease.SettingsRevisions = map[string]string{}
		for _, domain := range []struct{ kind, id string }{{"project", detail.Project.ID}, {"board", detail.Board.ID}, {"item", cardID}} {
			for field := range schema.DomainFields[domain.kind] {
				key := crdt.Key(domain.kind, domain.id+"."+field)
				if record := data.Record(key); len(record.Versions) > 0 {
					lease.SettingsRevisions[key] = record.Revision()
				}
			}
		}
		for _, label := range detail.Card.LabelIDs {
			key := crdt.Key("label", label+".instructions")
			lease.SettingsRevisions[key] = data.Record(key).Revision()
		}
		return data.Err()
	}
	return s.leases.Acquire(projectID, boardID, cardID, agent, admit, describe)
}
