package main

import (
	"fmt"

	"github.com/dbpprt/dieter/internal/model"
	boardstore "github.com/dbpprt/dieter/internal/store"
)

// Small, persisted workspace for screenshots of the real mobile clients.
func seedComposeFixture(data *boardstore.Store, project model.Project, board model.Board) error {
	fixtures := []struct{ title, prompt, summary, lane string }{
		{"Design the mobile workspace", "Bring the board and conversation together on phone and tablet.", "A shared canvas for your projects, agents and conversations.", "running"},
		{"Make reconnect feel effortless", "Keep drafts safe while a machine is offline.", "Preserve the conversation and pick up where you left off.", "running"},
		{"Polish the conversation timeline", "Group routine tools and keep the agent’s answer easy to read.", "One readable timeline, from the first idea to the final diff.", "running"},
		{"Ship the new project picker", "Use the shared core to choose the right checkout.", "Ready for a final look at the compact layout.", "review"},
		{"A quieter notification experience", "Summarize updates without interrupting focused work.", "An idea for the next iteration.", "todo"},
	}
	// The board's default order is newest first. Seed in reverse display order.
	for index := len(fixtures) - 1; index >= 0; index-- {
		fixture := fixtures[index]
		card, err := data.CreateCard(boardstore.CreateCardInput{Project: project.ID, Board: board.ID, Lane: "todo", Title: fixture.title, Prompt: fixture.prompt, Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject})
		if err != nil {
			return err
		}
		if fixture.lane == "todo" {
			continue
		}
		if _, err = data.MarkPromptSent(card.ID); err != nil {
			return err
		}
		messages := []model.UIMessage{
			{ID: fmt.Sprintf("compose-user-%d", index), Role: "user", Parts: []model.UIMessagePart{{Type: "text", Text: fixture.prompt}}},
			{ID: fmt.Sprintf("compose-answer-%d", index), Role: "assistant", Parts: []model.UIMessagePart{{Type: "text", Text: fixture.summary + "\n\nYour board stays within reach while you work. Each task keeps its conversation, so you can move between your phone and tablet without losing the thread.\n\nNext, I’ll refine the compact layout and check the keyboard experience."}}},
		}
		if _, err = data.InitializeForkConversation(card.ID, messages); err != nil {
			return err
		}
		if _, err = data.MoveCard(card.ID, fixture.lane, nil); err != nil {
			return err
		}
		if _, err = data.UpdateCardCache(card.ID, boardstore.CardCacheInput{Runtime: "idle", Summary: fixture.summary}); err != nil {
			return err
		}
	}
	return nil
}
