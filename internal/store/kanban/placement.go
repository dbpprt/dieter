package kanban

import (
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/store/home"
)

// Public mutations retain the central Store write lock and journal transaction.
// Unexported projection helpers run within their caller's existing lock boundary.

func (s *Store) MoveCard(ref, lane string, position *int64) (model.Card, error) {
	return s.moveCard(ref, lane, position, "", "", "")
}

func (s *Store) MoveCardBetween(ref, lane, after, before, expected string) (model.Card, error) {
	return s.moveCard(ref, lane, nil, after, before, expected)
}

func (s *Store) moveCard(ref, lane string, position *int64, after, before, expected string) (model.Card, error) {
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	if item.Scope != model.ConversationScopeBoard {
		return model.Card{}, fault.New(fault.Invalid, "chat conversations do not belong to board lanes")
	}
	if expected != "" && item.PlacementRevision != expected {
		return model.Card{}, crdt.ErrConflict
	}

	board, err := s.ResolveBoard(item.ProjectID, item.BoardID)
	if err != nil {
		return model.Card{}, err
	}
	if !ValidLane(board, lane) {
		return model.Card{}, fault.Invalidf("lane %q is not part of the %s workflow", lane, board.Workflow)
	}
	nextLane := canonicalLane(board, lane)
	laneChanged := item.Lane != nextLane
	item.Lane = nextLane
	if laneChanged {
		item.DoneArchiveExempt = false
	}
	if after != "" || before != "" {
		item.OrderKey, err = s.orderKeyBetweenItems(item, after, before)
	} else {
		item.OrderKey, err = s.MoveOrderKey(item, position)
	}
	if err != nil {
		return model.Card{}, err
	}
	item.UpdatedAt = home.Timestamp()
	if laneChanged {
		item.PhaseChangedAt = item.UpdatedAt
	}
	return s.SaveCard(item)
}
