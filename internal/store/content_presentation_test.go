package store

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func TestPresentationReplaysLatestWithStableID(t *testing.T) {
	data, project, board := setup(t, model.WorkflowReview)
	card, err := data.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, Title: "Present"})
	if err != nil {
		t.Fatal(err)
	}
	first, err := data.PresentConversationContent(card.ID, "turn-1", model.ContentPresentation{Path: "first.md"})
	if err != nil {
		t.Fatal(err)
	}
	latest, err := data.PresentConversationContent(card.ID, "turn-2", model.ContentPresentation{URL: "https://example.test", Title: "Result"})
	if err != nil || first.ID == latest.ID {
		t.Fatalf("IDs first=%q latest=%q err=%v", first.ID, latest.ID, err)
	}
	if err := os.Remove(filepath.Join(data.conversationPath(card.ID), "snapshot.json")); err != nil {
		t.Fatal(err)
	}
	conversation, err := New(data.Root).Conversation(card.ID)
	if err != nil || conversation.PresentedContent == nil || *conversation.PresentedContent != latest || conversation.LastSeq != 2 || len(conversation.Messages) != 0 || conversation.Status != "idle" {
		t.Fatalf("replay=%#v err=%v", conversation, err)
	}
}
