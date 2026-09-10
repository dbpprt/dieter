package cli

import (
	"bytes"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

func TestDaemonCLIChangesSelectionForExistingCardsAndChats(t *testing.T) {
	client, output, data := daemonCLIForTest(t)
	project, err := data.CreateProject(store.CreateProjectInput{Path: initTestRepository(t, "turn-selection"), Name: "Selection"})
	if err != nil {
		t.Fatal(err)
	}
	assertConversationSelectionCLI(t, client, output, data, project.ID)
}

func assertConversationSelectionCLI(t *testing.T, client *CLI, output *bytes.Buffer, data *store.Store, projectID string) {
	t.Helper()
	board, err := data.CreateBoard(store.CreateBoardInput{Project: projectID, Name: "Selection", Workflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	for _, scope := range []string{"card", "chat"} {
		input := store.CreateCardInput{Project: projectID, Board: board.ID, Title: "Selection", Provider: "codex", Model: "gpt-5.5", Effort: "low", WorkspaceMode: model.WorkspaceModeProject}
		var card model.Card
		if scope == "chat" {
			card, err = data.CreateChat(input)
		} else {
			card, err = data.CreateCard(input)
		}
		if err != nil {
			t.Fatal(err)
		}
		waitIdle := func() {
			t.Helper()
			deadline := time.Now().Add(10 * time.Second)
			for time.Now().Before(deadline) {
				stored, err := data.ResolveCard(card.ID)
				leased, leaseErr := data.CardHasRuntimeLease(card.ID)
				if err == nil && leaseErr == nil && stored.Runtime == "idle" && !leased {
					return
				}
				time.Sleep(10 * time.Millisecond)
			}
			t.Fatal("isolated selection turn did not finish")
		}
		runDaemonCLI(t, client, output, scope, "send", "--message", "First", card.ID)
		waitIdle()
		before, err := data.Conversation(card.ID)
		if err != nil {
			t.Fatal(err)
		}
		runDaemonCLI(t, client, output, scope, "send", "--message", "Next", "--model", "gpt-5.6-sol", "--effort", "high", "--provider-option", "fast_mode=true", card.ID)
		waitIdle()
		stored, err := data.ResolveCard(card.ID)
		if err != nil || stored.Provider != "codex" || stored.Model != "gpt-5.6-sol" || stored.Effort != "high" || stored.ProviderOptions["fast_mode"] != "true" {
			t.Fatalf("selection=%#v err=%v", stored, err)
		}
		after, err := data.Conversation(card.ID)
		if err != nil || len(before.Session) == 0 || string(after.Session) != string(before.Session) || len(after.Messages) <= len(before.Messages) {
			t.Fatalf("resumed conversation lost session/history: %#v err=%v", after, err)
		}
	}
}
