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

func TestSendMessageReportsAdmissionContentionAsRetryable(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Contention", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.CreateChat(store.CreateCardInput{
		Project: project.ID, Title: "Queued continue", Prompt: "Wait", Provider: "mock", Model: "mock",
	})
	if err != nil {
		t.Fatal(err)
	}
	lease, err := data.AcquireRuntimeLease(project.ID, chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = data.ReleaseRuntimeLease(lease) }()
	client, _ := newConnectTestClient(t, data, &fakeRunner{})
	_, err = client.SendMessage(t.Context(), connect.NewRequest(&dieterv1.SendMessageRequest{
		CardId: chat.ID, ClientId: "mac", CommandId: "continue-once", MessageId: "msg_continue_once",
		Provider: "mock", Model: "mock", Parts: []*dieterv1.MessagePart{{Type: "text", Text: "continue"}},
	}))
	if connect.CodeOf(err) != connect.CodeAborted {
		t.Fatalf("admission contention code=%v err=%v, want aborted", connect.CodeOf(err), err)
	}
	if _, saved, err := data.LoadCommandResult("mac", "continue-once"); err != nil || saved {
		t.Fatalf("contended command was acknowledged: saved=%v err=%v", saved, err)
	}
}

func TestSendMessageRetriesStorageFailureWithoutDuplicateAdmission(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	t.Setenv("DIETER_MIN_FREE_BYTES", "18446744073709551615")
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Storage", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.CreateChat(store.CreateCardInput{
		Project: project.ID, Title: "Disk recovery", Provider: "mock", Model: "mock",
		WorkspaceMode: model.WorkspaceModeProject,
	})
	if err != nil {
		t.Fatal(err)
	}
	runner := &creationRetryRunner{}
	client := creationRetryClient(t, data, runner)
	request := connect.NewRequest(&dieterv1.SendMessageRequest{
		CardId: chat.ID, ClientId: "native", CommandId: "storage-once", MessageId: "msg_storage_once",
		Provider: "mock", Model: "mock", Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Continue after recovery"}},
	})
	for range 2 {
		if _, err := client.SendMessage(t.Context(), request); connect.CodeOf(err) != connect.CodeResourceExhausted {
			t.Fatalf("storage rejection=%v", err)
		}
	}
	if runner.calls.Load() != 0 {
		t.Fatal("storage rejection started a runner")
	}
	if _, saved, err := data.LoadCommandResult("native", "storage-once"); err != nil || saved {
		t.Fatalf("rejected send was acknowledged: saved=%v err=%v", saved, err)
	}
	// Restore capacity on a new isolated service; retain the original command.
	t.Setenv("DIETER_MIN_FREE_BYTES", "0")
	client = creationRetryClient(t, data, runner)
	for range 3 {
		response, err := client.SendMessage(t.Context(), request)
		if err != nil || response.Msg.GetMessageId() != "msg_storage_once" {
			t.Fatalf("recovered send=%v err=%v", response, err)
		}
	}
	deadline := time.Now().Add(5 * time.Second)
	for runner.calls.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	conversation, err := data.Conversation(chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	messages := 0
	for _, message := range conversation.Messages {
		if message.ID == "msg_storage_once" {
			messages++
		}
	}
	if messages != 1 || runner.calls.Load() != 1 {
		t.Fatalf("messages=%d runner calls=%d", messages, runner.calls.Load())
	}
}
