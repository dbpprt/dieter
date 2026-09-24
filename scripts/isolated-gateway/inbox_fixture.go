package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"path/filepath"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	boardstore "github.com/dbpprt/dieter/internal/store"
)

// These persisted cards travel through the authenticated sync and conversation
// RPCs. No client-only snapshot or live operator state is used by the Inbox suite.
func seedInboxFixture(ctx context.Context, data *boardstore.Store, project model.Project, board model.Board) error {
	otherPath := filepath.Join(filepath.Dir(project.Path), "inbox-notes")
	if output, err := exec.CommandContext(ctx, "git", "init", "-b", "main", otherPath).CombinedOutput(); err != nil {
		return fmt.Errorf("initialize Inbox fixture repository: %s: %w", output, err)
	}
	other, err := data.CreateProject(boardstore.CreateProjectInput{Name: "Inbox Notes", Path: otherPath})
	if err != nil {
		return err
	}
	fixtures := []struct {
		title, runtime, lane, summary string
		chat, archived, otherProject  bool
	}{
		{"Inbox waiting: confirm the workspace plan", "waiting_for_user", "running", "Choose the workspace approach before implementation continues.", false, false, false},
		{"Inbox review: sidebar navigation improvements", "idle", "review", "The sidebar changes are ready for your review.", false, false, false},
		{"Inbox running: verify native layout", "running", "running", "Checking the compact feed and conversation workspace.", false, false, false},
		{"Inbox recent: document the native workflow", "idle", "done", "Updated the workflow notes and checked the final changes.", false, false, false},
		{"Inbox chat: clarify the release checklist", "waiting_for_user", "", "The release checklist is ready for your input.", true, false, false},
		{"Inbox notes: follow up on the rollout", "idle", "", "Captured the remaining rollout notes.", true, false, true},
		{"Inbox pending: do not show", "pending", "todo", "", false, false, false},
		{"Inbox archived: do not show", "idle", "done", "An archived activity must stay out of the feed.", false, true, false},
	}
	for index, fixture := range fixtures {
		owner := project
		if fixture.otherProject {
			owner = other
		}
		input := boardstore.CreateCardInput{
			Project: owner.ID, Board: board.ID, Lane: "todo", Title: fixture.title,
			Prompt:   "Review the native Inbox implementation and preserve the existing conversation workflow.",
			Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject,
		}
		var card model.Card
		if fixture.chat {
			input.Board, input.Lane = "", ""
			card, err = data.CreateChat(input)
		} else {
			card, err = data.CreateCard(input)
		}
		if err != nil {
			return fmt.Errorf("create Inbox fixture: %w", err)
		}
		if fixture.runtime == "pending" {
			continue
		}
		if _, err = data.MarkPromptSent(card.ID); err != nil {
			return err
		}
		createdAt := time.Now().UTC().Add(-time.Duration(12+index*7) * time.Minute)
		metadata, err := json.Marshal(map[string]string{"createdAt": createdAt.Format(time.RFC3339Nano)})
		if err != nil {
			return err
		}
		replyMetadata, err := json.Marshal(map[string]string{"createdAt": time.Now().UTC().Format(time.RFC3339Nano)})
		if err != nil {
			return err
		}
		messages := []model.UIMessage{
			{ID: fmt.Sprintf("inbox-user-%d", index), Role: "user", Metadata: metadata, Parts: []model.UIMessagePart{{Type: "text", Text: input.Prompt}}},
			{ID: fmt.Sprintf("inbox-assistant-%d", index), Role: "assistant", Metadata: replyMetadata, Parts: []model.UIMessagePart{{Type: "text", Text: "## Native Inbox workspace\n\n" + fixture.summary + "\n\nThe full conversation stays available here, including the composer and workspace tabs."}}},
		}
		if _, err = data.InitializeForkConversation(card.ID, messages); err != nil {
			return err
		}
		if _, err = data.SetConversationStatus(card.ID, "", fixture.runtime); err != nil {
			return err
		}
		if !fixture.chat {
			if _, err = data.MoveCard(card.ID, fixture.lane, nil); err != nil {
				return err
			}
		}
		if _, err = data.UpdateCardCache(card.ID, boardstore.CardCacheInput{Runtime: fixture.runtime, Summary: fixture.summary}); err != nil {
			return err
		}
		if fixture.archived {
			if _, err = data.ArchiveCard(card.ID, true); err != nil {
				return err
			}
		}
	}
	return nil
}
