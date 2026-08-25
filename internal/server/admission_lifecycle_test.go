package server

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

func TestSendMessageRequestContextDoesNotOwnAdmittedTurn(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Admission", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateCard(store.CreateCardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneTodo,
		Title: "Daemon owned", Prompt: "Wait", Provider: "mock", Model: "mock",
	})
	if err != nil {
		t.Fatal(err)
	}
	release := make(chan struct{})
	client, _ := newConnectTestClient(t, data, gatedRunner{release: release})
	requestCtx, cancelRequest := context.WithCancel(context.Background())
	if _, err := client.SendMessage(requestCtx, connect.NewRequest(&dieterv1.SendMessageRequest{
		CardId: card.ID, Provider: "mock", Model: "mock",
		Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Continue"}},
	})); err != nil {
		t.Fatal(err)
	}
	cancelRequest()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		stored, resolveErr := data.ResolveCard(card.ID)
		if resolveErr == nil && stored.Runtime == "running" {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(50 * time.Millisecond)
	stored, err := data.ResolveCard(card.ID)
	if err != nil || stored.Runtime != "running" {
		t.Fatalf("request cancellation changed admitted turn: runtime=%q err=%v", stored.Runtime, err)
	}
	close(release)
	deadline = time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		stored, err = data.ResolveCard(card.ID)
		if err == nil && stored.Runtime == "idle" {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("admitted turn did not finish: runtime=%q err=%v", stored.Runtime, err)
}
