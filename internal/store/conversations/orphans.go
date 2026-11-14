package conversations

import (
	"errors"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/home"
)

// OrphanedTurnCards returns durable turns that claim to be active but have no
// lease owned by a live Dieter process. Cold directory/status reads happen
// outside writer admission; only lease pruning and final candidate validation
// hold the central lock. An idle maintenance sweep must not block all messages.
func (s *Store) OrphanedTurnCards() ([]model.Card, error) {
	release, err := s.home.BeginWriteLock()
	if err != nil {
		return nil, err
	}
	activeLeases, err := s.leases.Active()
	release()
	if err != nil {
		return nil, err
	}
	active := make(map[string]bool, len(activeLeases))
	for _, lease := range activeLeases {
		active[lease.CardID] = true
	}
	cards, err := s.kanban.ListAllCards(false)
	if err != nil {
		return nil, err
	}
	if len(cards) == 0 {
		return nil, nil
	}
	identity, err := s.replica.PeerIdentity()
	if err != nil {
		return nil, err
	}
	orphaned := make([]model.Card, 0)
	for _, card := range cards {
		if active[card.ID] || card.OwnerDaemonID != identity.DaemonID {
			continue
		}
		status, statusErr := s.Status(card.ID)
		if statusErr != nil {
			return nil, statusErr
		}
		if model.RuntimeHoldsTurn(card.Runtime) || status == "running" || status == "starting" {
			orphaned = append(orphaned, card)
		}
	}
	if len(orphaned) == 0 {
		return orphaned, nil
	}
	// A turn may have acquired a lease while the directory was being scanned.
	release, err = s.home.BeginWriteLock()
	if err != nil {
		return nil, err
	}
	defer release()
	activeLeases, err = s.leases.Active()
	if err != nil {
		return nil, err
	}
	active = make(map[string]bool, len(activeLeases))
	for _, lease := range activeLeases {
		active[lease.CardID] = true
	}
	verified := orphaned[:0]
	for _, card := range orphaned {
		if active[card.ID] {
			continue
		}
		current, err := s.kanban.ResolveCard(card.ID)
		if errors.Is(err, home.ErrNotFound) {
			continue
		}
		if err != nil {
			return nil, err
		}
		status, err := s.Status(card.ID)
		if err != nil {
			return nil, err
		}
		if model.RuntimeHoldsTurn(current.Runtime) || status == "running" || status == "starting" {
			verified = append(verified, current)
		}
	}
	return verified, nil
}
