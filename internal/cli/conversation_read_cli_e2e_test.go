package cli

import (
	"bytes"
	"strconv"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestDaemonCLIConversationRead(t *testing.T) {
	client, output, data := daemonCLIForTest(t)
	project, err := data.CreateProject(store.CreateProjectInput{Path: initTestRepository(t, "read"), Name: "Read"})
	if err != nil {
		t.Fatal(err)
	}
	assertConversationReadCLI(t, client, output, data, project.ID)
}

func assertConversationReadCLI(t *testing.T, client *CLI, output *bytes.Buffer, data *store.Store, projectID string) {
	t.Helper()
	board, err := data.CreateBoard(store.CreateBoardInput{Project: projectID, Name: "Read", Workflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	for _, scope := range []string{"card", "chat"} {
		input := store.CreateCardInput{Project: projectID, Board: board.ID, Title: "Reply"}
		card, err := data.CreateCard(input)
		if scope == "chat" {
			card, err = data.CreateChat(input)
		}
		if err != nil {
			t.Fatal(err)
		}
		for _, chunk := range []map[string]string{{"type": "text-start", "id": "text"}, {"type": "text-delta", "id": "text", "delta": "Reply"}, {"type": "finish"}} {
			if _, _, err := data.AppendConversationEvent(card.ID, "ui-chunk", "turn", "response", chunk); err != nil {
				t.Fatal(err)
			}
		}
		card, _ = data.ResolveCard(card.ID)
		for range 2 {
			raw := runDaemonCLI(t, client, output, scope, "read", "--response-seq", strconv.FormatInt(card.ResponseSeq, 10), card.ID)
			var result dieterv1.Card
			if err := protojson.Unmarshal([]byte(raw), &result); err != nil {
				t.Fatal(err)
			}
			if result.SeenResponseSeq != card.ResponseSeq || result.LastActivityAt != card.LastActivityAt {
				t.Fatalf("read receipt: %s", raw)
			}
		}
		raw := runDaemonCLI(t, client, output, scope, "watch", "--after-seq", strconv.FormatInt(card.ResponseSeq, 10), "--count", "1", card.ID)
		var update dieterv1.ConversationUpdate
		if err := protojson.Unmarshal([]byte(raw), &update); err != nil {
			t.Fatal(err)
		}
		if update.GetDetail().GetCard().GetSeenResponseSeq() != card.ResponseSeq {
			t.Fatalf("watch lost receipt: %s", raw)
		}
		if err := client.Run([]string{scope, "comment", card.ID, "--message", "removed"}); err == nil {
			t.Fatal("removed comment command remains available")
		}
	}
}
