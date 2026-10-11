package server

import (
	"context"
	"io"
	"log/slog"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/gen/dieter/v1/dieterv1connect"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

// Exercise the unchanged client protocol through the real daemon turn pipeline,
// native OMP RPC, GLM, durable questions, normal chat replies and archive cleanup.
func TestOMPNativeRPCConversationEndToEnd(t *testing.T) {
	if os.Getenv("DIETER_TEST_OMP_RPC_E2E") != "1" {
		t.Skip("set DIETER_TEST_OMP_RPC_E2E=1 for live OMP/GLM daemon integration")
	}
	t.Setenv("DIETER_HARNESS_RUNTIME_DIR", "")
	data := store.New(t.TempDir())
	runner := harness.NewSubprocessRunner(data.Root)
	application := NewWithOptions(data, slog.New(slog.NewTextHandler(io.Discard, nil)), Options{
		Runner: runner, HarnessCatalog: func(context.Context, bool) []harness.Adapter { return harness.Catalog(false) },
	})
	server := httptest.NewServer(application.Handler())
	t.Cleanup(server.Close)
	client := dieterv1connect.NewDieterServiceClient(localHTTPClient(server.Client(), data.Root), server.URL)
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	workspace, err := client.CreateProject(ctx, connect.NewRequest(&dieterv1.CreateProjectRequest{
		Mode: "open", Path: testRepository(t), Name: "Native OMP RPC", BoardName: "Main", Workflow: model.WorkflowReview,
	}))
	if err != nil {
		t.Fatal(err)
	}
	modelID := os.Getenv("DIETER_TEST_OMP_MODEL")
	if modelID == "" {
		modelID = "tailscale/glm-5.3-flash-exl3"
	}
	created, err := client.CreateCard(ctx, connect.NewRequest(&dieterv1.CreateConversationRequest{
		ProjectId: workspace.Msg.GetProject().GetId(), BoardId: workspace.Msg.GetBoard().GetId(), Lane: model.LaneTodo,
		Title: "Native question", Prompt: "RPC question test", Provider: "omp", Model: modelID, Effort: "low", DeferStart: true, WorkspaceMode: model.WorkspaceModeProject,
	}))
	if err != nil {
		t.Fatal(err)
	}
	cardID := created.Msg.GetId()
	runtimeRoot := filepath.Join(data.RuntimeDir(), "sessions", workspace.Msg.GetProject().GetId())
	t.Cleanup(func() {
		if err := runner.Cleanup(cardID, runtimeRoot); err != nil {
			t.Error(err)
		}
	})
	send := func(text string) {
		t.Helper()
		if _, err := client.SendMessage(ctx, connect.NewRequest(&dieterv1.SendMessageRequest{
			CardId: cardID, Provider: "omp", Model: modelID, Effort: "low", Parts: []*dieterv1.MessagePart{{Type: "text", Text: text}},
		})); err != nil {
			t.Fatal(err)
		}
	}
	await := func() *dieterv1.Conversation {
		t.Helper()
		for {
			response, err := client.GetConversation(ctx, connect.NewRequest(&dieterv1.GetConversationRequest{CardId: cardID, Limit: 30}))
			if err != nil {
				t.Fatal(err)
			}
			conversation := response.Msg.GetConversation()
			// Card runtime also fences worker cleanup after the finish UI chunk.
			card, err := client.GetCard(ctx, connect.NewRequest(&dieterv1.GetCardRequest{CardId: cardID}))
			if err != nil {
				t.Fatal(err)
			}
			if conversation.GetStatus() == "failed" {
				var failures []string
				for _, message := range conversation.GetMessages() {
					for _, part := range message.GetParts() {
						if part.GetErrorText() != "" {
							failures = append(failures, part.GetErrorText())
						}
					}
				}
				t.Fatalf("native daemon turn failed: %s", strings.Join(failures, "; "))
			}
			if conversation.GetStatus() == "idle" && card.Msg.GetCard().GetRuntime() == "idle" {
				return conversation
			}
			select {
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			case <-time.After(25 * time.Millisecond):
			}
		}
	}
	send(`Use ask with exactly one question "Daemon RPC color?" and options Red and Blue. After the answer reply OMP_DAEMON_ANSWER_OK with the selected color.`)
	question := await()
	persisted, err := data.Conversation(cardID)
	if err != nil || !harness.AwaitingOMPInput(persisted.Session) {
		t.Fatalf("daemon did not retain native question: %v", err)
	}
	cleaned, err := application.app.CleanupInactiveProviderBridges()
	if err != nil || len(cleaned) != 0 {
		t.Fatalf("startup cleanup destroyed native question: %v %v", cleaned, err)
	}
	send("2")
	answered := await()
	if answered.GetLastSeq() <= question.GetLastSeq() {
		t.Fatal("normal chat reply did not advance the same conversation")
	}
	var text strings.Builder
	for _, message := range answered.GetMessages() {
		for _, part := range message.GetParts() {
			if part.GetType() == "text" {
				text.WriteString(part.GetText())
			}
		}
	}
	if !strings.Contains(text.String(), "OMP_DAEMON_ANSWER_OK") || !strings.Contains(text.String(), "Blue") {
		t.Fatalf("native answer missing from client transcript: %q", text.String())
	}
	persisted, err = data.Conversation(cardID)
	if err != nil || harness.AwaitingOMPInput(persisted.Session) {
		t.Fatalf("native question stayed pending after answer: %v", err)
	}
	send(`Use ask with one question "Archive RPC choice?" and options Keep and Archive. Wait for my answer.`)
	await()
	persisted, err = data.Conversation(cardID)
	if err != nil || !harness.AwaitingOMPInput(persisted.Session) {
		t.Fatalf("second native question missing: %v", err)
	}
	if _, err := client.ArchiveCard(ctx, connect.NewRequest(&dieterv1.ArchiveCardRequest{CardId: cardID, Archived: true})); err != nil {
		t.Fatal(err)
	}
	persisted, err = data.Conversation(cardID)
	if err != nil || harness.AwaitingOMPInput(persisted.Session) {
		t.Fatalf("archive retained a canceled native dialog: %v", err)
	}
	meta := filepath.Join(runtimeRoot, ".agent-runs", cardID, "omp-rpc", "bridge", "bridge-meta.json")
	if _, err := os.Stat(meta); !os.IsNotExist(err) {
		t.Fatalf("archive did not remove native provider bridge: %v", err)
	}
}
