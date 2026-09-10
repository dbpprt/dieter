package cli

import (
	"bytes"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestDaemonCLICardMerge(t *testing.T) {
	client, output, data := daemonCLIForTest(t)
	project, err := data.CreateProject(store.CreateProjectInput{Path: initTestRepository(t, "merge"), Name: "Merge"})
	if err != nil {
		t.Fatal(err)
	}
	assertCardMergeCLI(t, client, output, data, project.ID)
}

func assertCardMergeCLI(t *testing.T, client *CLI, output *bytes.Buffer, data *store.Store, projectID string) {
	t.Helper()
	board, err := data.CreateBoard(store.CreateBoardInput{Project: projectID, Name: "Merge", Workflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	source, err := data.CreateCard(store.CreateCardInput{Project: projectID, Board: board.ID, Title: "Source", Prompt: "Merged request"})
	if err != nil {
		t.Fatal(err)
	}
	target, err := data.CreateCard(store.CreateCardInput{Project: projectID, Board: board.ID, Title: "Target", Prompt: "Target request"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := data.MarkPromptSent(target.ID); err != nil {
		t.Fatal(err)
	}
	// Hold a real lease so the merge queues behind the target rather than starting a worker.
	lease, err := data.AcquireRuntimeLeaseFor(projectID, board.ID, target.ID, "codex")
	if err != nil {
		t.Fatal(err)
	}
	defer data.ReleaseRuntimeLease(lease)
	for range 2 {
		raw := runDaemonCLI(t, client, output, "card", "merge", "--into", target.ID, source.ID)
		var card dieterv1.Card
		if err := protojson.Unmarshal([]byte(raw), &card); err != nil {
			t.Fatal(err)
		}
		if card.Lane != "done" || card.MergedIntoCardId != target.ID {
			t.Fatalf("merge result: %s", raw)
		}
	}
	conversation, err := data.Conversation(target.ID)
	if err != nil || len(conversation.Queue) != 1 {
		t.Fatalf("merge queue: %#v %v", conversation.Queue, err)
	}
}

func TestDaemonCLIDraftAgentSettings(t *testing.T) {
	client, output, data := daemonCLIForTest(t)
	project, err := data.CreateProject(store.CreateProjectInput{Path: initTestRepository(t, "settings"), Name: "Settings"})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Settings", Workflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateCard(store.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Draft", Prompt: "Request"})
	if err != nil {
		t.Fatal(err)
	}
	runDaemonCLI(t, client, output, "card", "update", "--provider", "codex", "--model", "gpt-5.6-sol", "--effort", "high", "--provider-option", "fast_mode=true", card.ID)
	updated, err := data.ResolveCard(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Model != "gpt-5.6-sol" || updated.Effort != "high" || updated.ProviderOptions["fast_mode"] != "true" {
		t.Fatalf("settings: %#v", updated)
	}
}
