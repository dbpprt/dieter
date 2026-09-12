package cli

import (
	"bytes"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestDaemonCLIContentPresentation(t *testing.T) {
	client, output, data := daemonCLIForTest(t)
	project, err := data.CreateProject(store.CreateProjectInput{Path: initTestRepository(t, "presentation"), Name: "Presentation"})
	if err != nil {
		t.Fatal(err)
	}
	assertContentPresentationCLI(t, client, output, data, project.ID)
}

// The same assertions run against loopback, verified direct TLS, and relay.
func assertContentPresentationCLI(t *testing.T, client *CLI, output *bytes.Buffer, data *store.Store, projectID string) {
	t.Helper()
	board, err := data.CreateBoard(store.CreateBoardInput{Project: projectID, Name: "Present", Workflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	for _, scope := range []string{"card", "chat"} {
		input := store.CreateCardInput{Project: projectID, Board: board.ID, Title: "Present", WorkspaceMode: model.WorkspaceModeProject}
		var card model.Card
		if scope == "chat" {
			card, err = data.CreateChat(input)
		} else {
			card, err = data.CreateCard(input)
		}
		if err != nil {
			t.Fatal(err)
		}
		raw := runDaemonCLI(t, client, output, scope, "present", card.ID, "--path", "README.md", "--line", "2", "--title", "Deliverable")
		var file dieterv1.ContentPresentation
		if err := protojson.Unmarshal([]byte(raw), &file); err != nil {
			t.Fatal(err)
		}
		if file.GetId() == "" || file.GetPath() != "README.md" || file.GetLine() != 2 || file.GetTitle() != "Deliverable" {
			t.Fatalf("presentation: %s", raw)
		}
		conversation, err := data.Conversation(card.ID)
		if err != nil || conversation.PresentedContent == nil || conversation.PresentedContent.ID != file.Id || len(conversation.Messages) != 0 || conversation.Status != "idle" {
			t.Fatalf("presentation changed conversation: %#v %v", conversation, err)
		}
		raw = runDaemonCLI(t, client, output, scope, "present", "--url", "https://example.test/results", card.ID)
		var browser dieterv1.ContentPresentation
		if err := protojson.Unmarshal([]byte(raw), &browser); err != nil {
			t.Fatal(err)
		}
		if browser.GetId() == file.GetId() || browser.GetUrl() != "https://example.test/results" {
			t.Fatalf("browser presentation: %s", raw)
		}
		raw = runDaemonCLI(t, client, output, scope, "poll", card.ID)
		var update dieterv1.ConversationUpdate
		if err := protojson.Unmarshal([]byte(raw), &update); err != nil {
			t.Fatal(err)
		}
		if update.GetSnapshot().GetConversation().GetPresentedContent().GetId() != browser.GetId() {
			t.Fatalf("poll lost presentation: %s", raw)
		}
		output.Reset()
		if err := client.Run([]string{scope, "present", "--path", "../outside.md", card.ID}); err == nil {
			t.Fatal("accepted an outside-workspace path")
		}
		unchanged, err := data.Conversation(card.ID)
		if err != nil || unchanged.PresentedContent.ID != browser.Id {
			t.Fatalf("invalid presentation replaced latest: %#v %v", unchanged, err)
		}
	}
}
