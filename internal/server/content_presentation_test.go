package server

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
)

func TestConnectContentPresentationSnapshotAndDelta(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Path: testRepository(t), Name: "Presentation"})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Present", WorkspaceMode: "project"})
	if err != nil {
		t.Fatal(err)
	}
	client, _ := newConnectTestClient(t, data, &fakeRunner{})
	before, err := client.GetConversation(ctx, connect.NewRequest(&dieterv1.GetConversationRequest{CardId: card.ID}))
	if err != nil {
		t.Fatal(err)
	}
	shown, err := client.PresentConversationContent(ctx, connect.NewRequest(&dieterv1.PresentConversationContentRequest{CardId: card.ID, Path: "README.md", Title: "Read me"}))
	if err != nil || shown.Msg.GetId() == "" {
		t.Fatalf("shown=%v err=%v", shown, err)
	}
	seq := before.Msg.GetConversation().GetLastSeq()
	update, err := client.PollConversation(ctx, connect.NewRequest(&dieterv1.PollConversationRequest{CardId: card.ID, AfterSeq: &seq}))
	if err != nil {
		t.Fatal(err)
	}
	if update.Msg.GetSnapshot() != nil || update.Msg.GetPresentedContent().GetId() != shown.Msg.GetId() || len(update.Msg.GetChangedMessages()) != 0 || update.Msg.GetLastSeq() <= seq {
		t.Fatalf("presentation delta=%v", update.Msg)
	}
	stream, err := client.WatchConversation(ctx, connect.NewRequest(&dieterv1.WatchConversationRequest{CardId: card.ID}))
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	if !stream.Receive() || stream.Msg().GetSnapshot().GetConversation().GetPresentedContent().GetId() != shown.Msg.Id {
		t.Fatalf("presentation not in reconnect snapshot: %v", stream.Err())
	}
	_, err = client.PresentConversationContent(ctx, connect.NewRequest(&dieterv1.PresentConversationContentRequest{CardId: card.ID, Url: "javascript:bad"}))
	if connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Fatalf("invalid URL code: %v", err)
	}
}
