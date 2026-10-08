package main

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/dbpprt/dieter/internal/model"
	boardstore "github.com/dbpprt/dieter/internal/store"
)

// Small, persisted workspace for screenshots of the real mobile clients.
func seedComposeFixture(data *boardstore.Store, project model.Project, board model.Board) error {
	var err error
	for _, label := range []struct{ name, color string }{{"Design", "#8b5cf6"}, {"Core", "#22c55e"}} {
		board, err = data.CreateBoardLabel(board.ID, label.name, label.color)
		if err != nil {
			return err
		}
	}
	if err = os.WriteFile(filepath.Join(project.Path, "README.md"), []byte("# Mobile workspace\n\nOne durable conversation across Android and iOS.\n\n- Shared Kotlin client rules\n- Adaptive Compose screens\n- Native glass, terminal and GPU surfaces\n"), 0o644); err != nil {
		return err
	}
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
		card, err := data.CreateCard(boardstore.CreateCardInput{Project: project.ID, Board: board.ID, Lane: "todo", Title: fixture.title, Prompt: fixture.prompt, Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject, LabelIDs: []string{board.Labels[index%len(board.Labels)].ID}})
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
		if index == 0 {
			capability := fmt.Sprintf(`{"id":"subagents","operation":"upsert","subagent":{"id":"compose-scout","provider":"mock","messageId":%q,"name":"Layout scout","status":"completed","activity":"Checked compact and expanded layouts","tokens":12400,"recentOutput":["Compact cards retain labels and workspace badges.","The composer stays above the keyboard."]}}`, messages[1].ID)
			if _, _, err = data.AppendCapability(card.ID, "compose-design", []byte(capability)); err != nil {
				return err
			}
			plan := fmt.Sprintf(`{"id":"task-plan","operation":"replace","plan":{"id":"compose-plan","provider":"mock","messageId":%q,"revision":1,"state":"completed","phases":[{"name":"Mobile design","tasks":[{"content":"Audit Android views and cards","status":"completed"},{"content":"Port shared screens and native controls","status":"completed","order":1}]}]}}`, messages[1].ID)
			if _, _, err = data.AppendCapability(card.ID, "compose-design", []byte(plan)); err != nil {
				return err
			}
		}
		if _, err = data.MoveCard(card.ID, fixture.lane, nil); err != nil {
			return err
		}
		if _, err = data.UpdateCardCache(card.ID, boardstore.CardCacheInput{Runtime: "idle", Summary: fixture.summary}); err != nil {
			return err
		}
	}
	for _, title := range []string{"Mobile release checklist", "Ideas for the next iteration"} {
		chat, err := data.CreateChat(boardstore.CreateCardInput{Project: project.ID, Title: title, Prompt: "Review the mobile design together.", Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject})
		if err != nil {
			return err
		}
		if _, err = data.MarkPromptSent(chat.ID); err != nil {
			return err
		}
		if _, err = data.InitializeForkConversation(chat.ID, []model.UIMessage{{ID: "chat-" + chat.ID, Role: "assistant", Parts: []model.UIMessagePart{{Type: "text", Text: "## Ready to review\n\nCheck the board, the keyboard and both native layouts.\n\n| Platform | Presentation |\n| --- | --- |\n| Android | Material and Sora |\n| iOS | System type and Liquid Glass |"}}}}); err != nil {
			return err
		}
		if _, err = data.UpdateCardCache(chat.ID, boardstore.CardCacheInput{Runtime: "idle", Summary: "Review the shared mobile experience."}); err != nil {
			return err
		}
	}
	_, err = data.CreateSchedule(boardstore.ScheduleInput{Project: project.ID, Board: board.ID, Name: "Daily workspace review", Description: "Review work that needs attention", Cron: "0 9 * * 1-5", Timezone: "Europe/Berlin", Action: "draft", TitleTemplate: "Workspace review {{date}}", PromptTemplate: "Review the mobile workspace and summarize outstanding work.", Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject, Enabled: false})
	if err != nil {
		return err
	}
	return nil
}
