package api

import (
	"context"
	"io"
	"log/slog"
	"math"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
)

type creationRetryRunner struct {
	calls       atomic.Int32
	attachments atomic.Int32
}

func (r *creationRetryRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	r.calls.Add(1)
	r.attachments.Store(int32(len(request.Attachments)))
	return (newFakeRunner()).Run(ctx, request, emit)
}

// creationRetryClient serves an isolated mock-harness service whose turns
// require minimumFreeBytes of free disk space.
func creationRetryClient(t *testing.T, data *store.Store, runner harness.Runner, minimumFreeBytes uint64) dieterclient.ConnectClient {
	t.Helper()
	application := NewWithOptions(data, slog.New(slog.NewTextHandler(io.Discard, nil)), Options{
		Runner: runner, Catalog: testkit.MockCatalog(), MinimumFreeBytes: &minimumFreeBytes,
	})
	server := testkit.HTTPServer(application.Handler())
	t.Cleanup(func() {
		server.Close()
		ctx, cancel := context.WithTimeout(context.Background(), testkit.Budget(30*time.Second))
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
		// CancelCard acknowledges admission immediately. Wait for each owning
		// runTurn goroutine to release its lease and finish its last durable write
		// before t.TempDir removes the shared store.
		for {
			settled := true
			for _, card := range cards {
				current, resolveErr := data.ResolveCard(card.ID)
				conversation, conversationErr := data.Conversation(card.ID)
				leased, leaseErr := data.CardHasRuntimeLease(card.ID)
				if resolveErr != nil || conversationErr != nil || leaseErr != nil {
					t.Errorf("inspect canceled creation-retry turn: card=%v conversation=%v lease=%v", resolveErr, conversationErr, leaseErr)
					return
				}
				if leased || model.RuntimeHoldsTurn(current.Runtime) || conversation.Status == "running" || conversation.ActiveTurn != nil {
					settled = false
					break
				}
			}
			if settled {
				break
			}
			select {
			case <-ctx.Done():
				t.Error(ctx.Err())
				return
			case <-time.After(5 * time.Millisecond):
			}
		}
		if err := data.WaitForWriter(ctx); err != nil {
			t.Error(err)
		}
	})
	return dieterclient.NewConnect(localHTTPClient(server.Client(), data.Root), server.URL)
}

func TestCreateConversationRetriesFirstTurnAfterStorageAdmissionFailure(t *testing.T) {
	t.Parallel()
	for _, scope := range []string{model.ConversationScopeChat, model.ConversationScopeBoard} {
		t.Run(scope, func(t *testing.T) {
			// Reject admission regardless of the host's actual available space.
			data := testkit.Store(t)
			project, err := data.CreateProject(store.CreateProjectInput{Name: "Retry", Path: testkit.CheckoutDir(t)})
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
			client := creationRetryClient(t, data, runner, math.MaxUint64)
			create := func() (*dieterv1.Card, error) {
				call := client.CreateChat
				if scope == model.ConversationScopeBoard {
					call = client.CreateCard
				}
				response, err := call(context.Background(), request)
				if err != nil {
					return nil, err
				}
				return response, nil
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
			client = creationRetryClient(t, data, runner, 0)
			card, err := create()
			if err != nil || card.GetId() != id || card.GetInitialPromptSentAt() == "" {
				t.Fatalf("recovered creation=%v err=%v", card, err)
			}
			deadline := time.Now().Add(testkit.Budget(30 * time.Second))
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
	t.Parallel()
	data := testkit.Store(t)
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Ambiguous", Path: testkit.CheckoutDir(t)})
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
	client := creationRetryClient(t, data, runner, 0)
	_, err = client.CreateChat(context.Background(), &dieterv1.CreateConversationRequest{
		ProjectId: project.ID, ClientId: "retry-client", CommandId: "ambiguous",
		WorkspaceMode: model.WorkspaceModeProject,
	})
	if connect.CodeOf(err) != connect.CodeFailedPrecondition || runner.calls.Load() != 0 {
		t.Fatalf("ambiguous admission was replayed: calls=%d err=%v", runner.calls.Load(), err)
	}
	if _, saved, err := data.LoadCommandResult("retry-client", "ambiguous"); err != nil || saved {
		t.Fatalf("ambiguous admission acknowledged: saved=%v err=%v", saved, err)
	}
}
