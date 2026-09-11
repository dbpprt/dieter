package server

import (
	"context"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/gen/dieter/v1/dieterv1connect"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

type creationRetryRunner struct {
	calls       atomic.Int32
	attachments atomic.Int32
}

func (r *creationRetryRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	r.calls.Add(1)
	r.attachments.Store(int32(len(request.Attachments)))
	return (&fakeRunner{}).Run(ctx, request, emit)
}

func creationRetryClient(t *testing.T, data *store.Store, runner harness.Runner) dieterv1connect.DieterServiceClient {
	t.Helper()
	application := NewWithRunner(data, slog.New(slog.NewTextHandler(io.Discard, nil)), runner)
	server := httptest.NewServer(application.Handler())
	t.Cleanup(func() {
		server.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cards, err := data.ListCards(store.CardFilter{IncludeArchived: true})
		if err != nil {
			t.Error(err)
		}
		for _, card := range cards {
			if err := application.app.CancelCard(card.ID); err != nil {
				t.Error(err)
			}
		}
		if err := data.WaitForWriter(ctx); err != nil {
			t.Error(err)
		}
	})
	return dieterv1connect.NewDieterServiceClient(server.Client(), server.URL)
}

func TestCreateConversationRetriesFirstTurnAfterStorageAdmissionFailure(t *testing.T) {
	for _, scope := range []string{model.ConversationScopeChat, model.ConversationScopeBoard} {
		t.Run(scope, func(t *testing.T) {
			t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
			// Reject admission regardless of the host's actual available space.
			t.Setenv("DIETER_MIN_FREE_BYTES", "18446744073709551615")
			data := store.New(t.TempDir())
			project, err := data.CreateProject(store.CreateProjectInput{Name: "Retry", Path: testRepository(t)})
			if err != nil {
				t.Fatal(err)
			}
			board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
			if err != nil {
				t.Fatal(err)
			}
			request := &dieterv1.CreateConversationRequest{
				ProjectId: project.ID, BoardId: board.ID, Lane: model.LaneRunning,
				Title: "Start after recovery", Prompt: "Run exactly once", Provider: "mock", Model: "mock",
				WorkspaceMode: model.WorkspaceModeProject, ClientId: "retry-client", CommandId: "retry-command",
				Attachments: []*dieterv1.MessagePart{{Type: "file", MediaType: "text/plain", Filename: "notes.txt", Data: []byte("original attachment")}},
			}
			id, err := store.DeterministicCommandID("c_", request.ClientId, request.CommandId)
			if err != nil {
				t.Fatal(err)
			}
			runner := &creationRetryRunner{}
			client := creationRetryClient(t, data, runner)
			create := func() (*dieterv1.Card, error) {
				call := client.CreateChat
				if scope == model.ConversationScopeBoard {
					call = client.CreateCard
				}
				response, err := call(context.Background(), connect.NewRequest(request))
				if err != nil {
					return nil, err
				}
				return response.Msg, nil
			}
			for attempt := 0; attempt < 3; attempt++ {
				if _, err := create(); connect.CodeOf(err) != connect.CodeResourceExhausted || !strings.Contains(err.Error(), "insufficient free disk space") {
					t.Fatalf("attempt %d: expected storage admission error, got %v", attempt, err)
				}
				card, err := data.ResolveCard(id)
				if err != nil || card.InitialPromptSentAt != "" {
					t.Fatalf("draft=%#v err=%v", card, err)
				}
				if _, saved, err := data.LoadCommandResult(request.ClientId, request.CommandId); err != nil || saved {
					t.Fatalf("rejected admission was acknowledged: saved=%v err=%v", saved, err)
				}
			}
			if runner.calls.Load() != 0 {
				t.Fatal("rejected admission started a runner")
			}
			if scope == model.ConversationScopeBoard {
				// Also recover an interruption between persisting the card and its attachments.
				if _, err := data.SetConversationDraftAttachments(id, nil); err != nil {
					t.Fatal(err)
				}
			}

			// Reopen the isolated service with capacity restored. Keep the same
			// durable draft and command identity across the simulated restart.
			t.Setenv("DIETER_MIN_FREE_BYTES", "0")
			client = creationRetryClient(t, data, runner)
			card, err := create()
			if err != nil || card.GetId() != id || card.GetInitialPromptSentAt() == "" {
				t.Fatalf("recovered creation=%v err=%v", card, err)
			}
			deadline := time.Now().Add(5 * time.Second)
			for {
				conversation, err := data.Conversation(id)
				if err != nil {
					t.Fatal(err)
				}
				current, err := data.ResolveCard(id)
				if err != nil {
					t.Fatal(err)
				}
				if runner.calls.Load() == 1 && conversation.Status == "idle" && current.Runtime == "idle" {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("first turn did not finish")
				}
				time.Sleep(10 * time.Millisecond)
			}
			for attempt := 0; attempt < 3; attempt++ {
				if repeated, err := create(); err != nil || repeated.GetId() != id {
					t.Fatalf("repeat=%v err=%v", repeated, err)
				}
			}
			conversation, err := data.Conversation(id)
			if err != nil {
				t.Fatal(err)
			}
			users := 0
			for _, message := range conversation.Messages {
				if message.Role == "user" {
					users++
				}
			}
			cards, err := data.ListCards(store.CardFilter{Project: project.ID, Scope: scope})
			if err != nil || len(cards) != 1 || users != 1 || runner.calls.Load() != 1 || runner.attachments.Load() != 1 {
				t.Fatalf("cards=%d user messages=%d runner calls=%d attachments=%d err=%v", len(cards), users, runner.calls.Load(), runner.attachments.Load(), err)
			}
		})
	}
}

func TestCreateConversationRetryDoesNotReplayAmbiguousTurn(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	t.Setenv("DIETER_MIN_FREE_BYTES", "0")
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Ambiguous", Path: testRepository(t)})
	if err != nil {
		t.Fatal(err)
	}
	id, err := store.DeterministicCommandID("c_", "retry-client", "ambiguous")
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateChat(store.CreateCardInput{ID: id, Project: project.ID, Title: "Partial admission", Prompt: "Run once", Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := data.StartConversationTurnParts(card.ID, "partial-turn", "first-message", []model.UIMessagePart{{Type: "text", Text: card.InitialPrompt}}); err != nil {
		t.Fatal(err)
	}
	runner := &creationRetryRunner{}
	client := creationRetryClient(t, data, runner)
	_, err = client.CreateChat(context.Background(), connect.NewRequest(&dieterv1.CreateConversationRequest{
		ProjectId: project.ID, ClientId: "retry-client", CommandId: "ambiguous",
		WorkspaceMode: model.WorkspaceModeProject,
	}))
	if connect.CodeOf(err) != connect.CodeFailedPrecondition || runner.calls.Load() != 0 {
		t.Fatalf("ambiguous admission was replayed: calls=%d err=%v", runner.calls.Load(), err)
	}
	if _, saved, err := data.LoadCommandResult("retry-client", "ambiguous"); err != nil || saved {
		t.Fatalf("ambiguous admission acknowledged: saved=%v err=%v", saved, err)
	}
}
