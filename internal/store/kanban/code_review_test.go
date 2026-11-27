package kanban_test

import (
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestCodeReviewIsSetAtCreationAndSwitchable(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Reviewed", CodeReview: true})
	if err != nil || !card.CodeReview {
		t.Fatalf("created=%#v err=%v", card, err)
	}
	chat, err := s.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "Plain chat"})
	if err != nil || chat.CodeReview {
		t.Fatalf("chat=%#v err=%v", chat, err)
	}
	switched, err := s.Kanban.SetCodeReview(chat.ID, true)
	if err != nil || !switched.CodeReview {
		t.Fatalf("switched=%#v err=%v", switched, err)
	}
	again, err := s.Kanban.SetCodeReview(chat.ID, true)
	if err != nil || again.UpdatedAt != switched.UpdatedAt {
		t.Fatalf("an unchanged switch rewrote the card: %#v err=%v", again, err)
	}
	if _, err := s.Kanban.SetCodeReview(card.ID, false); err != nil {
		t.Fatal(err)
	}
	reloaded := store.New(s.Root)
	for id, want := range map[string]bool{card.ID: false, chat.ID: true} {
		value, err := reloaded.Kanban.ResolveCard(id)
		if err != nil || value.CodeReview != want {
			t.Fatalf("reloaded %s code review=%v err=%v, want %v", id, value.CodeReview, err, want)
		}
	}
	if _, err := s.Kanban.SetCodeReview("c_missing", true); err == nil {
		t.Fatal("switched a missing card")
	}
}
