package kanban

import (
	"sort"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/replica"
)

func cardOrderLess(a, b model.Card) bool {
	if a.Lane != b.Lane {
		return a.Lane < b.Lane
	}
	if a.OrderKey != b.OrderKey {
		return a.OrderKey < b.OrderKey
	}
	return a.ID < b.ID
}
func materializeCardPositions(cards []model.Card) {
	sort.SliceStable(cards, func(i, j int) bool { return cardOrderLess(cards[i], cards[j]) })
	for i := range cards {
		cards[i].Position = int64(i+1) * 1024
	}
}
func (s *Store) MoveOrderKey(card model.Card, position *int64) (string, error) {
	peers, err := s.ListCards(CardFilter{Board: card.BoardID, Lane: card.Lane, Scope: card.Scope, Project: card.ProjectID})
	if err != nil {
		return "", err
	}
	left, right := "", ""
	for _, peer := range peers {
		if peer.ID == card.ID {
			continue
		}
		if position != nil && peer.Position >= *position {
			right = peer.OrderKey
			break
		}
		left = peer.OrderKey
	}
	return replica.OrderBetween(left, right)
}

// Visible neighbors are stable IDs. Hidden items between those neighbors retain
// their relative order. A missing side means the start/end of the complete lane.
func (s *Store) orderKeyBetweenItems(item model.Card, after, before string) (string, error) {
	anchor := func(id string) (string, error) {
		if id == "" {
			return "", nil
		}
		card, err := s.ResolveCard(id)
		if err != nil {
			return "", err
		}
		if card.ID == item.ID || card.ProjectID != item.ProjectID || card.BoardID != item.BoardID || card.Lane != item.Lane || card.Archived {
			return "", fault.New(fault.Invalid, "ordering anchor is no longer in the destination lane")
		}
		return card.OrderKey, nil
	}
	left, err := anchor(after)
	if err != nil {
		return "", err
	}
	right, err := anchor(before)
	if err != nil {
		return "", err
	}
	return replica.OrderBetween(left, right)
}
