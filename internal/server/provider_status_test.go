package server

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

func TestConnectProviderStatusSnapshotAndDelta(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Path: testRepository(t), Name: "Provider status"})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Reconnect", WorkspaceMode: "project"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := data.SetConversationActiveTurn(card.ID, model.ConversationTurn{ID: "turn", UserMessageID: "user", ResponseMessageID: "response"}); err != nil {
		t.Fatal(err)
	}
	if _, err := data.StartConversationTurn(card.ID, "turn", "user", "Continue"); err != nil {
		t.Fatal(err)
	}
	client, _ := newConnectTestClient(t, data, &fakeRunner{})
	before, err := client.GetConversation(ctx, connect.NewRequest(&dieterv1.GetConversationRequest{CardId: card.ID}))
	if err != nil || before.Msg.GetConversation().GetProviderStatus() != nil {
		t.Fatalf("before=%v err=%v", before, err)
	}
	if _, _, err := data.AppendCapability(card.ID, "turn", json.RawMessage(`{"id":"provider-status","operation":"replace","status":{"state":"waiting-for-network","message":"Reconnecting... waiting for network (Connection failed: error sending request)","provider":"codex","messageId":"response"}}`)); err != nil {
		t.Fatal(err)
	}
	seq := before.Msg.GetConversation().GetLastSeq()
	update, err := client.PollConversation(ctx, connect.NewRequest(&dieterv1.PollConversationRequest{CardId: card.ID, AfterSeq: &seq}))
	if err != nil {
		t.Fatal(err)
	}
	if status := update.Msg.GetProviderStatus(); update.Msg.GetSnapshot() != nil || status.GetState() != "waiting-for-network" ||
		status.GetProvider() != "codex" || status.GetMessageId() != "response" || len(update.Msg.GetChangedMessages()) != 0 {
		t.Fatalf("provider status delta=%v", update.Msg)
	}
	stream, err := client.WatchConversation(ctx, connect.NewRequest(&dieterv1.WatchConversationRequest{CardId: card.ID}))
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	if !stream.Receive() || stream.Msg().GetSnapshot().GetConversation().GetProviderStatus().GetState() != "waiting-for-network" {
		t.Fatalf("provider status not in reconnect snapshot: %v", stream.Err())
	}
	if _, _, err := data.AppendCapability(card.ID, "turn", json.RawMessage(`{"id":"provider-status","operation":"clear"}`)); err != nil {
		t.Fatal(err)
	}
	if !stream.Receive() || stream.Msg().GetSnapshot() != nil || stream.Msg().GetProviderStatus() != nil {
		t.Fatalf("recovered delta retained provider status: %v err=%v", stream.Msg(), stream.Err())
	}
}
