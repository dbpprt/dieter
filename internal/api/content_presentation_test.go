package api

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestConnectContentPresentationSnapshotAndDelta(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), testkit.Budget(30*time.Second))
	defer cancel()
	data := testkit.Store(t)
	project, err := data.CreateProject(store.CreateProjectInput{Path: testkit.CheckoutDir(t), Name: "Presentation"})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Present", WorkspaceMode: "project"})
	if err != nil {
		t.Fatal(err)
	}
	client, _ := newConnectTestClient(t, data, newFakeRunner())
	before, err := client.GetConversation(ctx, &dieterv1.GetConversationRequest{CardId: card.ID})
	if err != nil {
		t.Fatal(err)
	}
	shown, err := client.PresentConversationContent(ctx, &dieterv1.PresentConversationContentRequest{CardId: card.ID, Path: "README.md", Title: "Read me"})
	if err != nil || shown.GetId() == "" {
		t.Fatalf("shown=%v err=%v", shown, err)
	}
	seq := before.GetConversation().GetLastSeq()
	update, err := client.PollConversation(ctx, &dieterv1.PollConversationRequest{CardId: card.ID, AfterSeq: &seq})
	if err != nil {
		t.Fatal(err)
	}
	if update.GetSnapshot() != nil || update.GetPresentedContent().GetId() != shown.GetId() || len(update.GetChangedMessages()) != 0 || update.GetLastSeq() <= seq {
		t.Fatalf("presentation delta=%v", update)
	}
	stream, err := client.WatchConversation(ctx, &dieterv1.WatchConversationRequest{CardId: card.ID})
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	if !stream.Receive() || stream.Msg().GetSnapshot().GetConversation().GetPresentedContent().GetId() != shown.Id {
		t.Fatalf("presentation not in reconnect snapshot: %v", stream.Err())
	}
	_, err = client.PresentConversationContent(ctx, &dieterv1.PresentConversationContentRequest{CardId: card.ID, Url: "javascript:bad"})
	if connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Fatalf("invalid URL code: %v", err)
	}
}
