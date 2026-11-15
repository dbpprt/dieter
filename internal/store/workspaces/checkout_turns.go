package workspaces

import (
	"github.com/dbpprt/dieter/internal/model"
)

// ProjectCheckoutTurns lists the conversations whose active turns execute in
// the registered project directory, optionally only those on one checkout.
// Worktree turns in the same project do not share its index or working tree
// and are not listed.
func (s *Store) ProjectCheckoutTurns(projectID, exceptCardID string, checkoutIDs ...string) ([]string, error) {
	activeLeases, err := s.leases.Active()
	if err != nil {
		return nil, err
	}
	var cards []string
	for _, lease := range activeLeases {
		if s.kanban.CanonicalProjectRef(lease.ProjectID) != projectID || lease.CardID == exceptCardID {
			continue
		}
		if len(checkoutIDs) > 0 && checkoutIDs[0] != "" {
			card, e := s.kanban.ResolveCard(lease.CardID)
			if e != nil || card.CheckoutID != checkoutIDs[0] {
				continue
			}
		}
		mode := ""
		if value, workspaceErr := s.ByCardID(lease.CardID); workspaceErr == nil {
			mode = value.Mode
		} else if card, cardErr := s.kanban.ResolveCard(lease.CardID); cardErr == nil {
			mode = card.WorkspaceMode
		}
		canonical, ok := model.CanonicalWorkspaceMode(mode)
		if ok && canonical == model.WorkspaceModeProject {
			cards = append(cards, lease.CardID)
		}
	}
	return cards, nil
}

// ProjectCheckoutActive reports whether ProjectCheckoutTurns lists any turn.
func (s *Store) ProjectCheckoutActive(projectID, exceptCardID string, checkoutIDs ...string) (bool, error) {
	cards, err := s.ProjectCheckoutTurns(projectID, exceptCardID, checkoutIDs...)
	return len(cards) > 0, err
}
