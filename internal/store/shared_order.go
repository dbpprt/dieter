package store

import (
	"errors"
	"sort"
	"strconv"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
)

const orderAlphabet = "0123456789abcdefghijklmnopqrstuvwxyz"

// orderBetween creates an immutable fractional position. A random operation
// suffix makes simultaneous insertions in the same gap distinct. No lane-wide
// renumbering is replicated, and future moves can address either new neighbor.
func orderBetween(left, right string) (string, error) {
	if right != "" && left >= right {
		return "", errors.New("invalid ordering anchors")
	}
	// Reserve a wide integer prefix for appends/prepends. Repeated end insertion
	// must not consume one fractional digit per few cards on a large board.
	if right == "" {
		value := uint64(3656158440062976) // 36^10, room on both sides
		if len(left) >= 12 {
			if n, e := strconv.ParseUint(left[:12], 36, 64); e == nil {
				value = n + 1
			}
		}
		prefix := strconv.FormatUint(value, 36)
		if len(prefix) <= 12 {
			return strings.Repeat("0", 12-len(prefix)) + prefix + newID("") + "h", nil
		}
	}
	if left == "" && len(right) >= 12 {
		if n, e := strconv.ParseUint(right[:12], 36, 64); e == nil && n > 1 {
			prefix := strconv.FormatUint(n-1, 36)
			return strings.Repeat("0", 12-len(prefix)) + prefix + newID("") + "h", nil
		}
	}
	prefix := ""
	for i := 0; i < 480; i++ {
		lo, hi := 0, len(orderAlphabet)-1
		if i < len(left) {
			lo = strings.IndexByte(orderAlphabet, left[i])
		}
		if i < len(right) {
			hi = strings.IndexByte(orderAlphabet, right[i])
		}
		if lo < 0 || hi < 0 {
			return "", errors.New("invalid position key")
		}
		if hi-lo > 1 {
			return prefix + string(orderAlphabet[(lo+hi)/2]) + newID("") + "h", nil
		}
		prefix += string(orderAlphabet[lo])
		if hi > lo {
			right = ""
		}
	}
	return "", errors.New("position key exhausted; move using wider anchors")
}
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
func (s *Store) moveOrderKey(card model.Card, position *int64) (string, error) {
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
	return orderBetween(left, right)
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
			return "", errors.New("ordering anchor is no longer in the destination lane")
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
	return orderBetween(left, right)
}
