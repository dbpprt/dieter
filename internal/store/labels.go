package store

import (
	"errors"
	"fmt"
	"github.com/dbpprt/dieter/internal/model"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
	"strings"
)

// Public mutations retain the central Store write lock and journal transaction.
// Unexported projection helpers run within their caller's existing lock boundary.

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func validateCardLabels(board model.Board, requested []string) ([]string, error) {
	result := make([]string, 0, len(requested))
	for _, ref := range requested {
		ref = strings.TrimSpace(ref)
		if ref == "" || containsString(result, ref) {
			continue
		}
		matched := ""
		for _, label := range board.Labels {
			if ref == label.ID || strings.EqualFold(ref, label.Name) {
				matched = label.ID
				break
			}
		}
		if matched == "" {
			return nil, fmt.Errorf("label %q is not defined on board %s", ref, board.Name)
		}
		if !containsString(result, matched) {
			result = append(result, matched)
		}
	}
	return result, nil
}

func (s *Store) CreateBoardLabel(boardRef, name, color string, instructions ...string) (model.Board, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return model.Board{}, errors.New("label name is required")
	}
	if color == "" {
		color = "#6558df"
	}
	if len(color) != 7 || color[0] != '#' {
		return model.Board{}, errors.New("label color must be a hex color such as #6558df")
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Board{}, err
	}
	defer release()
	board, err := s.ResolveBoard("", boardRef)
	if err != nil {
		return model.Board{}, err
	}
	for _, label := range board.Labels {
		if strings.EqualFold(label.Name, name) {
			return model.Board{}, fmt.Errorf("label %q already exists", name)
		}
	}
	prompt := ""
	if len(instructions) > 0 {
		prompt = strings.TrimSpace(instructions[0])
	}
	if len(prompt) > dieterprompt.MaxTemplateBytes {
		return model.Board{}, errors.New("label instructions exceed 32 KiB")
	}
	board.Labels = append(board.Labels, model.Label{ID: newID("label_"), Name: name, Color: color, Instructions: prompt})
	board.UpdatedAt = timestamp()
	err = s.writeBoard(board)
	return hydrateBoard(board), err
}

func (s *Store) UpdateBoardLabel(boardRef, labelID, name, color, instructions string) (model.Board, error) {
	name, color, instructions = strings.TrimSpace(name), strings.TrimSpace(color), strings.TrimSpace(instructions)
	if name == "" {
		return model.Board{}, errors.New("label name is required")
	}
	if len(color) != 7 || color[0] != '#' {
		return model.Board{}, errors.New("label color must be a hex color such as #6558df")
	}
	if len(instructions) > dieterprompt.MaxTemplateBytes {
		return model.Board{}, errors.New("label instructions exceed 32 KiB")
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Board{}, err
	}
	defer release()
	board, err := s.ResolveBoard("", boardRef)
	if err != nil {
		return model.Board{}, err
	}
	found := false
	for index := range board.Labels {
		if board.Labels[index].ID == labelID {
			board.Labels[index].Name, board.Labels[index].Color, board.Labels[index].Instructions = name, color, instructions
			found = true
			continue
		}
		if strings.EqualFold(board.Labels[index].Name, name) {
			return model.Board{}, fmt.Errorf("label %q already exists", name)
		}
	}
	if !found {
		return model.Board{}, fmt.Errorf("label %q: %w", labelID, ErrNotFound)
	}
	board.UpdatedAt = timestamp()
	return s.saveBoard(board)
}

func (s *Store) DeleteBoardLabel(boardRef, labelID string) (model.Board, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.Board{}, err
	}
	defer release()
	board, err := s.ResolveBoard("", boardRef)
	if err != nil {
		return model.Board{}, err
	}
	found := false
	labels := board.Labels[:0]
	for _, label := range board.Labels {
		if label.ID == labelID {
			found = true
			continue
		}
		labels = append(labels, label)
	}
	if !found {
		return model.Board{}, fmt.Errorf("label %q: %w", labelID, ErrNotFound)
	}
	board.Labels = labels
	board.UpdatedAt = timestamp()
	if err := s.writeBoard(board); err != nil {
		return model.Board{}, err
	}
	cards, _ := s.ListCards(CardFilter{Board: board.ID})
	for _, card := range cards {
		if containsString(card.LabelIDs, labelID) {
			next := card.LabelIDs[:0]
			for _, id := range card.LabelIDs {
				if id != labelID {
					next = append(next, id)
				}
			}
			card.LabelIDs, card.UpdatedAt = next, timestamp()
			if err := s.writeCard(card); err != nil {
				return model.Board{}, err
			}
		}
	}
	return hydrateBoard(board), nil
}

func (s *Store) SetCardLabels(cardRef string, requested []string) (model.Card, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	card, err := s.ResolveCard(cardRef)
	if err != nil {
		return model.Card{}, err
	}
	if card.Scope != model.ConversationScopeBoard {
		return model.Card{}, errors.New("labels are only available for board cards")
	}
	board, err := s.ResolveBoard(card.ProjectID, card.BoardID)
	if err != nil {
		return model.Card{}, err
	}
	labels, err := validateCardLabels(board, requested)
	if err != nil {
		return model.Card{}, err
	}
	card.LabelIDs, card.UpdatedAt = labels, timestamp()
	return s.saveCard(card)
}
