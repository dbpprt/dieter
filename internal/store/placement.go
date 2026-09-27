package store

import (
	"errors"
	"fmt"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/peerstore"
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
	release, err := s.beginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	if item.Scope != model.ConversationScopeBoard {
		return model.Card{}, errors.New("chat conversations do not belong to board lanes")
	}
	if expected != "" && item.PlacementRevision != expected {
		return model.Card{}, peerstore.ErrConflict
	}

	board, err := s.ResolveBoard(item.ProjectID, item.BoardID)
	if err != nil {
		return model.Card{}, err
	}
	if !validLane(board, lane) {
		return model.Card{}, fmt.Errorf("lane %q is not part of the %s workflow", lane, board.Workflow)
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
		item.OrderKey, err = s.moveOrderKey(item, position)
	}
	if err != nil {
		return model.Card{}, err
	}
	item.UpdatedAt = timestamp()
	if laneChanged {
		item.PhaseChangedAt = item.UpdatedAt
	}
	return s.saveCard(item)
}
