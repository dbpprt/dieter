package kanban

import (
	"errors"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/replica"
)

func (s *Store) WriteCard(item model.Card) error {
	if err := s.RequireLocalCard(item); err != nil {
		if errors.Is(err, ErrRemoteConversation) {
			return s.publishCard(item)
		}
		return err
	}
	raw, err := home.MarshalMarkdown(item, item.InitialPrompt)
	if err != nil {
		return err
	}
	target, stale := "cards/", "archived-cards/"
	if item.Archived {
		target, stale = stale, target
	}
	return s.publishCard(item,
		replica.Effect{Path: target + item.ID + ".md", Value: raw},
		replica.Effect{Path: stale + item.ID + ".md", Remove: true})
}
