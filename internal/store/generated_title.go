package store

import (
	"errors"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
)

// ApplyGeneratedCardTitle updates only the originally saved title. It deliberately
// preserves conversation identity, task text, runtime, workflow and workspace.
func (s *Store) ApplyGeneratedCardTitle(ref, expectedTitle string, expectedRevision uint64, title string) (model.Card, error) {
	title = strings.TrimSpace(title)
	if title == "" {
		return model.Card{}, errors.New("title is required")
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	if item.Title != expectedTitle || item.TitleRevision != expectedRevision || item.Title == title {
		return item, nil
	}
	if item.LastActivityAt == "" {
		item.LastActivityAt = item.UpdatedAt
	}
	item.Title, item.UpdatedAt = title, timestamp()
	item.TitleRevision++
	return item, s.writeCard(item)
}
