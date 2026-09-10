package cli

import (
	"bytes"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestDaemonCLIQueuedMessageRemoval(t *testing.T) {
	client, output, data := daemonCLIForTest(t)
	project, err := data.CreateProject(store.CreateProjectInput{Path: initTestRepository(t, "queue"), Name: "Queue"})
	if err != nil {
		t.Fatal(err)
	}
	assertQueueRemovalCLI(t, client, output, data, project.ID)
}

func assertQueueRemovalCLI(t *testing.T, client *CLI, output *bytes.Buffer, data *store.Store, projectID string) {
	t.Helper()
	board, err := data.CreateBoard(store.CreateBoardInput{Project: projectID, Name: "Queue", Workflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateCard(store.CreateCardInput{Project: projectID, Board: board.ID, Title: "Queued task"})
	if err != nil {
		t.Fatal(err)
	}
	queued, _, err := data.QueueConversationMessageParts(card.ID, []model.UIMessagePart{
		{Type: "text", Text: "Keep my attachment"},
		{Type: "file", Filename: "note.txt", MediaType: "text/plain", URL: "data:text/plain;base64,aGk="},
	})
	if err != nil {
		t.Fatal(err)
	}
	raw := runDaemonCLI(t, client, output, "card", "queue", "remove", "--message", queued.ID, card.ID)
	var removed dieterv1.QueuedMessage
	if err := protojson.Unmarshal([]byte(raw), &removed); err != nil {
		t.Fatal(err)
	}
	if removed.Id != queued.ID || removed.Text != queued.Text || len(removed.Parts) != 2 || string(removed.Parts[1].Data) != "hi" || removed.Parts[1].Filename != "note.txt" {
		t.Fatalf("removed payload: %s", raw)
	}
	conversation, err := data.Conversation(card.ID)
	if err != nil || len(conversation.Queue) != 0 {
		t.Fatalf("queue not removed: %#v %v", conversation.Queue, err)
	}
}
