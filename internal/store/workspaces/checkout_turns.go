package workspaces

import (
	"github.com/dbpprt/dieter/internal/model"
)

// ProjectCheckoutActive reports only turns that execute in the
// registered project directory. Worktree turns in the same project do not
// share its index or working tree and must not block checkout-scoped actions.
func (s *Store) ProjectCheckoutActive(projectID, exceptCardID string, checkoutIDs ...string) (bool, error) {
	activeLeases, err := s.leases.Active()
	if err != nil {
		return false, err
	}
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
			return true, nil
		}
	}
	return false, nil
}
