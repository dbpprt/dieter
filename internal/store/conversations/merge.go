package conversations

import (
	"fmt"
	"slices"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
)

// MergeCard transfers only the initial request, preserving both conversations.
// A durable intent precedes delivery; the target's event records a receipt so
// retries (including after the queued message was consumed/removed) are safe.
func (s *Store) MergeCard(sourceRef, targetRef string) (model.Card, error) {
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	source, err := s.kanban.ResolveCard(sourceRef)
	if err != nil {
		return model.Card{}, err
	}
	target, err := s.kanban.ResolveCard(targetRef)
	if err != nil {
		return model.Card{}, err
	}
	if err = s.kanban.RequireLocalCard(source); err != nil {
		return model.Card{}, err
	}
	if err = s.kanban.RequireLocalCard(target); err != nil {
		return model.Card{}, err
	}
	if source.ID == target.ID || source.BoardID == "" || source.BoardID != target.BoardID || source.ProjectID != target.ProjectID {
		return model.Card{}, fault.New(fault.Invalid, "merge requires two different cards in the same board")
	}
	if source.MergedIntoCardID != "" && source.MergedIntoCardID != target.ID {
		return model.Card{}, fault.New(fault.Invalid, "card is already merged into another target")
	}
	if source.MergedIntoCardID == target.ID && !source.MergePending {
		return source, nil
	}
	destination, err := s.loadConversation(target.ID)
	if err != nil {
		return model.Card{}, err
	}
	if !source.MergePending {
		if source.Archived || target.Archived || target.MergedIntoCardID != "" {
			return model.Card{}, fault.New(fault.Invalid, "archived or merged cards cannot be merged")
		}
		if target.InitialPromptSentAt == "" {
			return model.Card{}, fault.New(fault.Invalid, "start the target task before merging into it")
		}
		active, err := s.leases.CardActive(source.ID)
		if err != nil {
			return model.Card{}, err
		}
		origin, err := s.loadConversation(source.ID)
		if err != nil {
			return model.Card{}, err
		}
		for _, worker := range origin.Subagents {
			switch strings.ToLower(worker.Status) {
			case "starting", "running", "active", "working", "streaming", "cancelling":
				active = true
			}
		}
		if active || origin.Status == "running" || origin.Status == "starting" || origin.ActiveTurn != nil || len(origin.Queue) != 0 {
			return model.Card{}, fault.New(fault.Invalid, "finish or cancel the source task and clear its queue before merging")
		}
		board, err := s.kanban.ResolveBoard(source.ProjectID, source.BoardID)
		if err != nil {
			return model.Card{}, err
		}
		if !kanban.ValidLane(board, "done") {
			return model.Card{}, fault.New(fault.Invalid, "board has no Done lane")
		}
		parts := []model.UIMessagePart{{Type: "text", Text: fmt.Sprintf("Additional request merged from task %q (%s):\n\n%s", source.Title, source.ID, source.InitialPrompt)}}
		attachments := origin.DraftAttachments
		for _, message := range origin.Messages {
			if message.Role == "user" {
				attachments = message.Parts
				break
			}
		}
		for _, part := range attachments {
			if part.Type == "file" {
				parts = append(parts, part)
			}
		}
		source.MergedIntoCardID, source.MergePending, source.MergeParts = target.ID, true, parts
		if err := s.kanban.WriteCard(source); err != nil {
			return model.Card{}, err
		}
	}
	if !slices.Contains(destination.MergedSourceIDs, source.ID) {
		var texts []string
		for _, part := range source.MergeParts {
			if part.Type == "text" {
				texts = append(texts, part.Text)
			}
		}
		queued := model.QueuedMessage{ID: "merge_" + source.ID, Text: strings.Join(texts, "\n"), Parts: source.MergeParts, CreatedAt: home.Timestamp(), MergeSourceID: source.ID}
		if _, _, err := s.appendConversationEvent(target, destination, "queue-message", "", "", queued); err != nil {
			return model.Card{}, err
		}
	}
	source.MergePending, source.MergeParts = false, nil
	source.Lane, source.DoneArchiveExempt = "done", false
	peers, err := s.kanban.ListCards(kanban.CardFilter{Board: source.BoardID, Lane: "done"})
	if err != nil {
		return model.Card{}, err
	}
	source.Position = int64(len(peers)+1) * 1024
	source.OrderKey, err = s.kanban.MoveOrderKey(source, nil)
	if err != nil {
		return model.Card{}, err
	}
	source.UpdatedAt = home.Timestamp()
	source.PhaseChangedAt = source.UpdatedAt
	return s.kanban.SaveCard(source)
}

// RecoverCardMerges finishes only accepted intents, never resubmitting a receipt.
func (s *Store) RecoverCardMerges() ([]string, error) {
	cards, err := s.kanban.ListCards(kanban.CardFilter{IncludeArchived: true})
	if err != nil {
		return nil, err
	}
	var targets []string
	for _, card := range cards {
		if s.kanban.RequireLocalCard(card) != nil {
			continue
		}
		if card.MergedIntoCardID == "" {
			continue
		}
		if !card.MergePending {
			if !slices.Contains(targets, card.MergedIntoCardID) {
				targets = append(targets, card.MergedIntoCardID)
			}
			continue
		}
		merged, err := s.MergeCard(card.ID, card.MergedIntoCardID)
		if err != nil {
			return targets, err
		}
		targets = append(targets, merged.MergedIntoCardID)
	}
	return targets, nil
}
