package server

import (
	"context"
	"testing"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

func TestMoveRPCAndStateCarryTheSameCausalPlacementReceipt(t *testing.T) {
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Test", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateCard(store.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Move", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	client, _ := newConnectTestClient(t, data, &fakeRunner{})
	moved, err := client.MoveCard(context.Background(), connect.NewRequest(&dieterv1.MoveCardRequest{CardId: card.ID, Lane: "done", ExpectedRevision: card.PlacementRevision}))
	if err != nil {
		t.Fatal(err)
	}
	if moved.Msg.Lane != "done" || moved.Msg.PlacementRevision == card.PlacementRevision || len(moved.Msg.StateFields) != 2 {
		t.Fatalf("missing move receipt: %v", moved.Msg)
	}
	state, err := client.GetState(context.Background(), connect.NewRequest(&dieterv1.GetStateRequest{ProjectId: project.ID, AllProjects: true}))
	if err != nil {
		t.Fatal(err)
	}
	var got *dieterv1.Card
	for _, value := range state.Msg.Cards {
		if value.Id == card.ID {
			got = value
		}
	}
	if got == nil || got.PlacementRevision != moved.Msg.PlacementRevision {
		t.Fatalf("state disagrees with committed move: %v", got)
	}
	for _, f := range got.StateFields {
		if f.Name == "placement" && (f.Revision != got.PlacementRevision || len(f.Versions) != 1 || f.Versions[0].Value.Lane != "done") {
			t.Fatalf("invalid frontier: %v", f)
		}
	}
}
