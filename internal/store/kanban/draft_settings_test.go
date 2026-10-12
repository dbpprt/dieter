package kanban_test

import (
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestDraftAgentSettingsAreSavedAndLockedAfterStart(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	a, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Source", Prompt: "Implement the new feature"})
	if err != nil {
		t.Fatal(err)
	}
	config := kanban.DraftAgentSettings{Provider: "codex", Model: "model", Effort: "high", ProviderOptions: map[string]string{"fast_mode": "true"}}
	got, err := s.Kanban.UpdateCard(a.ID, a.Title, a.InitialPrompt, config)
	if err != nil {
		t.Fatal(err)
	}
	if got.Model != "model" || got.Effort != "high" || got.ProviderOptions["fast_mode"] != "true" {
		t.Fatalf("settings: %#v", got)
	}
	if _, err := s.Kanban.MarkPromptSent(a.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.UpdateCard(a.ID, a.Title, a.InitialPrompt, config); err == nil {
		t.Fatal("started settings editable")
	}
}
