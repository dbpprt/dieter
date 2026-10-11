package api

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestConnectProviderStatusSnapshotAndDelta(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), testkit.Budget(30*time.Second))
	defer cancel()
	data := testkit.Store(t)
	project, err := data.CreateProject(store.CreateProjectInput{Path: testkit.CheckoutDir(t), Name: "Provider status"})
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
	client, _ := newConnectTestClient(t, data, newFakeRunner())
	before, err := client.GetConversation(ctx, &dieterv1.GetConversationRequest{CardId: card.ID})
	if err != nil || before.GetConversation().GetProviderStatus() != nil {
		t.Fatalf("before=%v err=%v", before, err)
	}
	if _, _, err := data.AppendCapability(card.ID, "turn", json.RawMessage(`{"id":"provider-status","operation":"replace","status":{"state":"waiting-for-network","message":"Reconnecting... waiting for network (Connection failed: error sending request)","provider":"codex","messageId":"response"}}`)); err != nil {
		t.Fatal(err)
	}
	seq := before.GetConversation().GetLastSeq()
	update, err := client.PollConversation(ctx, &dieterv1.PollConversationRequest{CardId: card.ID, AfterSeq: &seq})
	if err != nil {
		t.Fatal(err)
	}
	if status := update.GetProviderStatus(); update.GetSnapshot() != nil || status.GetState() != "waiting-for-network" ||
		status.GetProvider() != "codex" || status.GetMessageId() != "response" || len(update.GetChangedMessages()) != 0 {
		t.Fatalf("provider status delta=%v", update)
	}
	stream, err := client.WatchConversation(ctx, &dieterv1.WatchConversationRequest{CardId: card.ID})
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
