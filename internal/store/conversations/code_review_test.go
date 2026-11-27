package conversations_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/conversations"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestCodeReviewPartsAttachAndUpdateInPlace(t *testing.T) {
	t.Parallel()
	data, project, board := testkit.BoardStore(t, model.WorkflowReview)
	card, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Review"})
	if err != nil {
		t.Fatal(err)
	}
	// An agent review joins the turn's assistant message, created under the
	// response ID when the stream has not started it yet.
	agent := model.CodeReview{ID: "rev_agent", CardID: card.ID, Status: model.CodeReviewRunning, Trigger: model.CodeReviewTriggerAgent, StartedAt: "2026-11-27T10:00:00Z"}
	if _, err := data.Conversations.AppendCodeReview(card.ID, "turn-1", "msg_response", agent); err != nil {
		t.Fatal(err)
	}
	// A user review gets an assistant message of its own.
	user := model.CodeReview{ID: "rev_user", CardID: card.ID, Status: model.CodeReviewRunning, Trigger: model.CodeReviewTriggerUser, StartedAt: "2026-11-27T10:05:00Z"}
	if _, err := data.Conversations.AppendCodeReview(card.ID, "", "", user); err != nil {
		t.Fatal(err)
	}
	agent.Status, agent.Findings = model.CodeReviewCompleted, []model.CodeReviewFinding{{ID: "f1", File: "a.go", StartLine: 3, Severity: "high", Title: "Leak", Body: "It leaks."}}
	conversation, err := data.Conversations.AppendCodeReview(card.ID, "turn-1", "msg_response", agent)
	if err != nil {
		t.Fatal(err)
	}
	check := func(conversation model.Conversation) {
		t.Helper()
		if len(conversation.Messages) != 2 {
			t.Fatalf("messages=%#v", conversation.Messages)
		}
		first, second := conversation.Messages[0], conversation.Messages[1]
		if first.ID != "msg_response" || first.Role != "assistant" || len(first.Parts) != 1 || first.Parts[0].Type != model.CodeReviewPartType {
			t.Fatalf("agent message=%#v", first)
		}
		if second.ID != "msg_review_rev_user" || second.Role != "assistant" || len(second.Parts) != 1 {
			t.Fatalf("user message=%#v", second)
		}
		var stored model.CodeReview
		if err := json.Unmarshal(first.Parts[0].Data, &stored); err != nil || stored.Status != model.CodeReviewCompleted || len(stored.Findings) != 1 {
			t.Fatalf("agent review was not replaced in place: %#v err=%v", stored, err)
		}
		reviews := conversations.CodeReviews(conversation)
		if len(reviews) != 2 || reviews[0].ID != "rev_agent" || reviews[0].MessageID != "msg_response" || reviews[1].ID != "rev_user" || reviews[1].MessageID != "msg_review_rev_user" {
			t.Fatalf("reviews=%#v", reviews)
		}
	}
	check(conversation)
	if err := os.Remove(filepath.Join(data.Conversations.Path(card.ID), "snapshot.json")); err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	replayed, err := store.New(data.Root).Conversations.Get(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	check(replayed)
}
