package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
	boardstore "github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/schedules"
)

// Small, persisted workspace that the Maestro flows of every client share.
func seedE2EFixture(data *boardstore.Store, project model.Project, board model.Board) error {
	var err error
	for _, label := range []struct{ name, color string }{{"Design", "#8b5cf6"}, {"Core", "#22c55e"}} {
		board, err = data.Kanban.CreateBoardLabel(board.ID, label.name, label.color)
		if err != nil {
			return err
		}
	}
	if err = os.WriteFile(filepath.Join(project.Path, "README.md"), []byte("# Mobile workspace\n\nOne durable conversation across Android and iOS.\n\n- Shared Kotlin client rules\n- Adaptive Compose screens\n- Native glass, terminal and GPU surfaces\n"), 0o644); err != nil {
		return err
	}
	// Exercise the real file RPC and native editor with a multi-megabyte document.
	largeMarkdown := strings.Repeat("# Large file viewer\n\nA **formatted** paragraph with a [link](https://example.com).\n\n", 33000)
	if err = os.WriteFile(filepath.Join(project.Path, "large-viewer.md"), []byte(largeMarkdown), 0o644); err != nil {
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
		card, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Lane: "todo", Title: fixture.title, Prompt: fixture.prompt, Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject, LabelIDs: []string{board.Labels[index%len(board.Labels)].ID}})
		if err != nil {
			return err
		}
		if fixture.lane == "todo" {
			continue
		}
		if _, err = data.Kanban.MarkPromptSent(card.ID); err != nil {
			return err
		}
		messages := []model.UIMessage{
			{ID: fmt.Sprintf("compose-user-%d", index), Role: "user", Parts: []model.UIMessagePart{{Type: "text", Text: fixture.prompt}}},
			{ID: fmt.Sprintf("compose-answer-%d", index), Role: "assistant", Parts: []model.UIMessagePart{{Type: "text", Text: fixture.summary + "\n\nYour board stays within reach while you work. Each task keeps its conversation, so you can move between your phone and tablet without losing the thread.\n\nNext, I’ll refine the compact layout and check the keyboard experience."}}},
		}
		if _, err = data.Conversations.InitializeFork(card.ID, messages); err != nil {
			return err
		}
		if index == 0 {
			capability := fmt.Sprintf(`{"id":"subagents","operation":"upsert","subagent":{"id":"compose-scout","provider":"mock","messageId":%q,"name":"Layout scout","status":"completed","activity":"Checked compact and expanded layouts","tokens":12400,"recentOutput":["Compact cards retain labels and workspace badges.","The composer stays above the keyboard."]}}`, messages[1].ID)
			if _, _, err = data.Conversations.AppendCapability(card.ID, "compose-design", []byte(capability)); err != nil {
				return err
			}
			plan := fmt.Sprintf(`{"id":"task-plan","operation":"replace","plan":{"id":"compose-plan","provider":"mock","messageId":%q,"revision":1,"state":"completed","phases":[{"name":"Mobile design","tasks":[{"content":"Audit Android views and cards","status":"completed"},{"content":"Port shared screens and native controls","status":"completed","order":1}]}]}}`, messages[1].ID)
			if _, _, err = data.Conversations.AppendCapability(card.ID, "compose-design", []byte(plan)); err != nil {
				return err
			}
		}
		if _, err = data.Kanban.MoveCard(card.ID, fixture.lane, nil); err != nil {
			return err
		}
		if _, err = data.Kanban.UpdateCardCache(card.ID, kanban.CardCacheInput{Runtime: "idle", Summary: fixture.summary}); err != nil {
			return err
		}
	}
	for _, title := range []string{"Mobile release checklist", "Ideas for the next iteration", "Markdown code fences"} {
		chat, err := data.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: title, Prompt: "Review the mobile design together.", Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject})
		if err != nil {
			return err
		}
		if _, err = data.Kanban.MarkPromptSent(chat.ID); err != nil {
			return err
		}
		text := "## Ready to review\n\nCheck the board, the keyboard and both native layouts.\n\n| Platform | Presentation |\n| --- | --- |\n| Android | Material and Sora |\n| iOS | System type and Liquid Glass |"
		if title == "Markdown code fences" {
			text = "Markdown regression\n\n```text\nfenced line one\nfenced line two\n```\n\nFence complete."
		}
		messages := []model.UIMessage{{ID: "chat-" + chat.ID, Role: "assistant", Parts: []model.UIMessagePart{{Type: "text", Text: text}}}}
		if title == "Ideas for the next iteration" {
			messages = channelMessagesInATurn(project, chat.ID)
		}
		if _, err = data.Conversations.InitializeFork(chat.ID, messages); err != nil {
			return err
		}
		if _, err = data.Kanban.UpdateCardCache(chat.ID, kanban.CardCacheInput{Runtime: "idle", Summary: "Review the shared mobile experience."}); err != nil {
			return err
		}
	}
	_, err = data.Schedules.Create(schedules.Input{Project: project.ID, Board: board.ID, Name: "Daily workspace review", Description: "Review work that needs attention", Cron: "0 9 * * 1-5", Timezone: "Europe/Berlin", Action: "draft", TitleTemplate: "Workspace review {{date}}", PromptTemplate: "Review the mobile workspace and summarize outstanding work.", Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject, Enabled: false})
	if err != nil {
		return err
	}
	return nil
}

// channelMessagesInATurn is a turn that an agent channel message joined and a
// turn that a channel message woke, as the daemon records them.
func channelMessagesInATurn(project model.Project, chatID string) []model.UIMessage {
	notice, _ := json.Marshal(map[string]any{
		"messageId": "m_e2e_notice", "projectId": project.ID, "channel": project.Name, "kind": model.ChannelKindRequest,
		"author": model.ChannelAuthor{Kind: model.ChannelAuthorAgent, CardID: "c_e2e_reviewer", Title: "Review headers", Harness: "codex", Model: "gpt-5"},
		"direct": true, "files": []string{"src/pricing.ts"}, "createdAt": "2026-10-25T09:00:00Z",
	})
	return []model.UIMessage{
		{ID: "chat-" + chatID, Role: "assistant", Parts: []model.UIMessagePart{
			{Type: "text", Text: "I'll sketch the next iteration."},
			{Type: "data-peer-notice", Text: "Please leave src/pricing.ts to me until my review is in.", Data: notice},
			{Type: "text", Text: "Noted: I'll keep away from src/pricing.ts."},
		}},
		{ID: model.ChannelWakeMessagePrefix + "e2e", Role: "user", Parts: []model.UIMessagePart{{Type: "text", Text: "src/pricing.ts is free now: the review is in."}}},
		{ID: "chat-woken-" + chatID, Role: "assistant", Parts: []model.UIMessagePart{{Type: "text", Text: "Picking up src/pricing.ts again."}}},
	}
}
