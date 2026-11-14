package conversations_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestPresentationReplaysLatestWithStableID(t *testing.T) {
	t.Parallel()
	data, project, board := testkit.BoardStore(t, model.WorkflowReview)
	card, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Present"})
	if err != nil {
		t.Fatal(err)
	}
	first, err := data.Conversations.PresentContent(card.ID, "turn-1", model.ContentPresentation{Path: "first.md"})
	if err != nil {
		t.Fatal(err)
	}
	latest, err := data.Conversations.PresentContent(card.ID, "turn-2", model.ContentPresentation{URL: "https://example.test", Title: "Result"})
	if err != nil || first.ID == latest.ID {
		t.Fatalf("IDs first=%q latest=%q err=%v", first.ID, latest.ID, err)
	}
	if err := os.Remove(filepath.Join(data.Conversations.Path(card.ID), "snapshot.json")); err != nil {
		t.Fatal(err)
	}
	conversation, err := store.New(data.Root).Conversations.Get(card.ID)
	if err != nil || conversation.PresentedContent == nil || *conversation.PresentedContent != latest || conversation.LastSeq != 2 || len(conversation.Messages) != 0 || conversation.Status != "idle" {
		t.Fatalf("replay=%#v err=%v", conversation, err)
	}
}
