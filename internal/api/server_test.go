package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/protobuf/types/known/emptypb"
)

// fakeRunner streams a live turn: reasoning, a tool call, text, a task plan,
// and a subagent.
type fakeRunner = testkit.FakeRunner

func newFakeRunner() *fakeRunner { return &fakeRunner{Script: liveTurn} }

func liveTurn(_ context.Context, request harness.Request, emit func(harness.Output) error) error {
	for _, chunk := range []string{
		`{"type":"start","messageId":"` + request.ResponseMessageID + `","messageMetadata":{"createdAt":"2026-08-11T12:00:00Z"}}`,
		`{"type":"reasoning-start","id":"reasoning_live"}`,
		`{"type":"reasoning-delta","id":"reasoning_live","delta":"Checked locally"}`,
		`{"type":"reasoning-end","id":"reasoning_live"}`,
		`{"type":"tool-input-available","toolCallId":"tool_live","toolName":"exec_command","input":{"command":"printf ready"}}`,
		`{"type":"tool-output-available","toolCallId":"tool_live","toolName":"exec_command","output":{"stdout":"ready","exitCode":0}}`,
		`{"type":"text-start","id":"text_live"}`,
		`{"type":"text-delta","id":"text_live","delta":"Built locally"}`,
		`{"type":"text-end","id":"text_live"}`,
		`{"type":"finish","finishReason":"stop"}`,
	} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	if err := emit(harness.Output{Type: "capability", Capability: json.RawMessage(`{"id":"task-plan","operation":"replace","plan":{"id":"mock:` + request.ResponseMessageID + `","provider":"mock","messageId":"` + request.ResponseMessageID + `","revision":1,"state":"completed","source":"mock","phases":[{"tasks":[{"content":"Build locally","status":"completed"}]}]}}`)}); err != nil {
		return err
	}
	if err := emit(harness.Output{Type: "capability", Capability: json.RawMessage(`{"id":"subagents","operation":"upsert","subagent":{"id":"worker-live","provider":"mock","messageId":"` + request.ResponseMessageID + `","name":"Verifier","status":"completed"}}`)}); err != nil {
		return err
	}
	return emit(harness.Output{Type: "session", State: json.RawMessage(`{"type":"resume-session","data":{"threadId":"thread_live"}}`)})
}

type gatedRunner struct {
	release <-chan struct{}
	stopped chan<- struct{}
}

func (runner gatedRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	if runner.stopped != nil {
		defer close(runner.stopped)
	}
	for _, chunk := range []string{
		`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`,
		`{"type":"text-start","id":"text_live"}`,
		`{"type":"text-delta","id":"text_live","delta":"first"}`,
	} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-runner.release:
	}
	return nil
}

func newConnectTestClient(t *testing.T, data *store.Store, runner harness.Runner, catalog ...*harness.Catalog) (dieterclient.ConnectClient, string) {
	t.Helper()
	options := Options{Runner: runner}
	if len(catalog) > 0 {
		options.Catalog = catalog[0]
	}
	application := NewWithOptions(data, slog.New(slog.NewTextHandler(io.Discard, nil)), options)
	server := testkit.HTTPServer(application.Handler())
	t.Cleanup(server.Close)
	return dieterclient.NewConnect(localHTTPClient(server.Client(), data.Root), server.URL), server.URL
}

func TestFixtureCatalogServesHarnessesAndSettingsWithoutDiscovery(t *testing.T) {
	t.Parallel()
	application := NewWithOptions(testkit.Store(t), slog.New(slog.NewTextHandler(io.Discard, nil)), Options{
		Runner:  newFakeRunner(),
		Catalog: harness.StaticCatalogOf([]harness.Adapter{{ID: "fixture", Name: "Fixture", Runtime: "mock"}}, false),
	})
	httpServer := testkit.HTTPServer(application.Handler())
	defer httpServer.Close()
	client := dieterclient.NewConnect(localHTTPClient(httpServer.Client(), application.store.Root), httpServer.URL)
	ctx, cancel := context.WithTimeout(context.Background(), testkit.Budget(30*time.Second))
	defer cancel()
	catalog, err := client.GetHarnesses(ctx, &emptypb.Empty{})
	if err != nil || len(catalog.GetHarnesses()) != 1 || catalog.GetHarnesses()[0].GetId() != "fixture" {
		t.Fatalf("injected harness catalog: %v %v", catalog, err)
	}
	settings, err := client.GetSettingsOptions(ctx, &emptypb.Empty{})
	if err != nil || len(settings.GetAgents().GetHarnesses()) != 1 || settings.GetAgents().GetHarnesses()[0].GetId() != "fixture" {
		t.Fatalf("injected settings catalog: %v %v", settings, err)
	}
}

func waitForCanceledCard(t *testing.T, data *store.Store, cardID string) {
	t.Helper()
	deadline := time.Now().Add(testkit.Budget(30 * time.Second))
	var card model.Card
	var conversation model.Conversation
	var cardErr, conversationErr, leaseErr error
	var leased bool
	for time.Now().Before(deadline) {
		card, cardErr = data.Kanban.ResolveCard(cardID)
		conversation, conversationErr = data.Conversations.Get(cardID)
		leased, leaseErr = data.Leases.CardActive(cardID)
		if cardErr == nil && conversationErr == nil && leaseErr == nil &&
			!model.RuntimeHoldsTurn(card.Runtime) && conversation.Status != "running" && conversation.ActiveTurn == nil && !leased {
			// The in-memory conversation state becomes visible before the owning
			// write releases the store lock and commits its change count. Cross that
			// writer boundary before TempDir cleanup can remove the store root.
			if err := data.WaitForWriter(t.Context()); err != nil {
				t.Fatalf("wait for canceled turn writer: %v", err)
			}
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("canceled turn did not finish cleanup: card=%#v conversation=%#v leased=%v errors=%v", card, conversation, leased, errors.Join(cardErr, conversationErr, leaseErr))
}

// isolatedMockCatalog verifies the settings/schedule contract with an
// isolated fixture catalog plus the mock harness. Live provider discovery has
// its own opt-in integration test: it may install pinned runtimes and must not
// use the operator's DIETER_HOME here.
func isolatedMockCatalog() *harness.Catalog {
	return harness.StaticCatalogOf([]harness.Adapter{{
		ID: "fixture", Name: "Fixture", Runtime: "mock", DefaultModel: "mock",
		Models: []harness.Model{{ID: "mock", Name: "Mock"}},
	}}, true)
}

func TestConnectConversationEndToEnd(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), testkit.Budget(30*time.Second))
	defer cancel()
	data := testkit.Store(t)
	runner := newFakeRunner()
	client, baseURL := newConnectTestClient(t, data, runner, isolatedMockCatalog())

	raw := localHTTPClient(http.DefaultClient, data.Root)
	rootResponse, err := raw.Get(baseURL + "/")
	if err != nil || rootResponse.StatusCode != http.StatusNotFound {
		t.Fatalf("machine-only root response=%v err=%v", rootResponse, err)
	}
	_ = rootResponse.Body.Close()
	legacyResponse, err := raw.Get(baseURL + "/api/v1/state")
	if err != nil {
		t.Fatal(err)
	}
	_ = legacyResponse.Body.Close()
	if legacyResponse.StatusCode != http.StatusNotFound {
		t.Fatalf("legacy API status=%d", legacyResponse.StatusCode)
	}

	health, err := client.Health(ctx, &emptypb.Empty{})
	if err != nil || health.GetStatus() != "ok" {
		t.Fatalf("health=%#v err=%v", health, err)
	}
	harnesses, err := client.GetHarnesses(ctx, &emptypb.Empty{})
	if err != nil || len(harnesses.GetHarnesses()) != 2 || harnesses.GetHarnesses()[0].GetId() != "fixture" || harnesses.GetHarnesses()[1].GetId() != "mock" {
		t.Fatalf("harnesses=%#v err=%v", harnesses, err)
	}

	workspace, err := client.CreateProject(ctx, &dieterv1.CreateProjectRequest{
		Mode: "open", Path: testkit.CheckoutDir(t), Name: "Connect", BoardName: "Main", Workflow: model.WorkflowReview,
	})
	if err != nil {
		t.Fatal(err)
	}
	project, board := workspace.GetProject(), workspace.GetBoard()
	cardResponse, err := client.CreateCard(ctx, &dieterv1.CreateConversationRequest{
		ProjectId: project.GetId(), BoardId: board.GetId(), Lane: model.LaneTodo,
		Title: "Protocol", Prompt: "Build it", Provider: "mock", Model: "mock", DeferStart: true, WorkspaceMode: model.WorkspaceModeProject,
		Attachments: []*dieterv1.MessagePart{{
			Type: "image", MediaType: "image/png", Filename: "wire.png", Data: []byte("png fixture bytes"),
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	card := cardResponse
	draft, err := client.GetConversation(ctx, &dieterv1.GetConversationRequest{CardId: card.GetId(), Limit: 30})
	if err != nil || len(draft.GetConversation().GetDraftAttachments()) != 1 || draft.GetConversation().GetDraftAttachments()[0].GetFilename() != "wire.png" {
		t.Fatalf("draft attachments=%#v err=%v", draft.GetConversation().GetDraftAttachments(), err)
	}
	updatedCard, err := client.UpdateCard(ctx, &dieterv1.UpdateCardRequest{
		CardId: card.GetId(), Title: "Protocol draft", InitialPrompt: "Build the edited task",
	})
	if err != nil || updatedCard.GetTitle() != "Protocol draft" || updatedCard.GetInitialPrompt() != "Build the edited task" {
		t.Fatalf("updated card=%#v err=%v", updatedCard, err)
	}
	card = updatedCard

	stream, err := client.WatchConversation(ctx, &dieterv1.WatchConversationRequest{CardId: card.GetId(), Limit: 30, IntervalMs: 10})
	if err != nil {
		t.Fatal(err)
	}
	if !stream.Receive() || stream.Msg().GetSnapshot() == nil {
		t.Fatalf("initial update=%#v err=%v", stream.Msg(), stream.Err())
	}
	zeroSeq := draft.GetConversation().GetLastSeq()
	emptyCurrent, err := client.PollConversation(ctx, &dieterv1.PollConversationRequest{CardId: card.GetId(), Limit: 30, AfterSeq: &zeroSeq})
	if err != nil || emptyCurrent.GetSnapshot() != nil || emptyCurrent.GetLastSeq() != zeroSeq {
		t.Fatalf("empty current poll=%#v err=%v", emptyCurrent, err)
	}
	if _, err := client.SendMessage(ctx, &dieterv1.SendMessageRequest{
		CardId: card.GetId(), Provider: "mock", Model: "mock",
		Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Ship through protobuf"}},
	}); err != nil {
		t.Fatal(err)
	}

	found, foundPlan, foundSubagent := false, false, false
	for stream.Receive() {
		update := stream.Msg()
		for _, message := range update.GetChangedMessages() {
			for _, part := range message.GetParts() {
				if part.GetText() == "Built locally" {
					found = true
				}
			}
		}
		foundPlan = foundPlan || len(update.GetTaskPlans()) > 0
		foundSubagent = foundSubagent || len(update.GetSubagents()) > 0
		if found && foundPlan && foundSubagent && update.GetStatus() == "idle" {
			break
		}
	}
	if !found || !foundPlan || !foundSubagent {
		t.Fatalf("conversation capabilities not streamed; message=%v plan=%v subagent=%v err=%v", found, foundPlan, foundSubagent, stream.Err())
	}
	for {
		cardDetail, detailErr := client.GetCard(ctx, &dieterv1.GetCardRequest{CardId: card.GetId()})
		if detailErr != nil {
			t.Fatal(detailErr)
		}
		if cardDetail.GetCard().GetRuntime() == "idle" {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-time.After(10 * time.Millisecond):
		}
	}

	timeline, err := client.GetConversation(ctx, &dieterv1.GetConversationRequest{CardId: card.GetId(), Limit: 30})
	if err != nil {
		t.Fatal(err)
	}
	if plans := timeline.GetConversation().GetTaskPlans(); len(plans) != 1 || plans[0].GetState() != "completed" || plans[0].GetPhases()[0].GetTasks()[0].GetContent() != "Build locally" {
		t.Fatalf("task plan protocol projection=%#v", plans)
	}
	if subagents := timeline.GetConversation().GetSubagents(); len(subagents) != 1 || subagents[0].GetName() != "Verifier" {
		raw, rawErr := data.Conversations.Get(card.GetId())
		t.Fatalf("subagent protocol projection=%#v raw=%#v rawErr=%v", subagents, raw.Subagents, rawErr)
	}
	if len(timeline.GetConversation().GetDraftAttachments()) != 0 {
		t.Fatalf("sent draft attachments were not cleared: %#v", timeline.GetConversation().GetDraftAttachments())
	}
	if requests := runner.Requests(); len(requests) != 1 || len(requests[0].Attachments) != 1 || requests[0].Attachments[0].Filename != "wire.png" || requests[0].Attachments[0].URL != "data:image/png;base64,cG5nIGZpeHR1cmUgYnl0ZXM=" {
		t.Fatalf("attachment did not reach harness: %#v", requests)
	}
	var toolMessageID string
	var toolPart *dieterv1.MessagePart
	for _, message := range timeline.GetConversation().GetMessages() {
		for _, part := range message.GetParts() {
			if part.GetToolCallId() == "tool_live" {
				toolMessageID, toolPart = message.GetId(), part
			}
		}
	}
	if toolPart == nil || len(toolPart.GetInputJson()) != 0 || len(toolPart.GetOutputJson()) != 0 || !toolPart.GetHasInput() || !toolPart.GetHasOutput() || toolPart.GetPayloadRevision() == "" || toolPart.GetInputPreview() != "printf ready" {
		t.Fatalf("conversation tool envelope=%#v", toolPart)
	}
	tool, err := client.GetToolOutput(ctx, &dieterv1.GetToolOutputRequest{
		CardId: card.GetId(), MessageId: toolMessageID, ToolCallId: toolPart.GetToolCallId(), Revision: toolPart.GetPayloadRevision(),
	})
	var toolInput map[string]any
	var toolOutput map[string]any
	inputErr, outputErr := json.Unmarshal(tool.GetInputJson(), &toolInput), json.Unmarshal(tool.GetOutputJson(), &toolOutput)
	if err != nil || inputErr != nil || outputErr != nil || toolInput["command"] != "printf ready" || toolOutput["stdout"] != "ready" || toolOutput["exitCode"] != float64(0) || tool.GetRevision() != toolPart.GetPayloadRevision() {
		t.Fatalf("lazy tool input=%q output=%q revision=%q want=%q err=%v", tool.GetInputJson(), tool.GetOutputJson(), tool.GetRevision(), toolPart.GetPayloadRevision(), err)
	}
	currentSeq := timeline.GetConversation().GetLastSeq()
	unchanged, err := client.PollConversation(ctx, &dieterv1.PollConversationRequest{
		CardId: card.GetId(), Limit: 30, AfterSeq: &currentSeq,
	})
	if err != nil || unchanged.GetSnapshot() != nil || unchanged.GetLastSeq() != timeline.GetConversation().GetLastSeq() {
		t.Fatalf("unchanged poll=%#v err=%v", unchanged, err)
	}
	if _, _, err := data.Conversations.Append(card.GetId(), "status", "", "", "idle"); err != nil {
		t.Fatal(err)
	}
	delta, err := client.PollConversation(ctx, &dieterv1.PollConversationRequest{
		CardId: card.GetId(), Limit: 30, AfterSeq: &currentSeq,
	})
	if err != nil || delta.GetSnapshot() != nil || delta.GetPage() == nil || delta.GetLastSeq() <= timeline.GetConversation().GetLastSeq() || len(delta.GetTaskPlans()) != 1 || len(delta.GetSubagents()) != 1 {
		t.Fatalf("current cursor delta=%#v err=%v", delta, err)
	}
	staleSeq := int64(999999)
	stale, err := client.PollConversation(ctx, &dieterv1.PollConversationRequest{CardId: card.GetId(), Limit: 30, AfterSeq: &staleSeq})
	if err != nil || stale.GetSnapshot() == nil || len(stale.GetSnapshot().GetConversation().GetMessages()) == 0 {
		t.Fatalf("stale poll=%#v err=%v", stale, err)
	}

	labelBoard, err := client.CreateBoardLabel(ctx, &dieterv1.CreateBoardLabelRequest{BoardId: board.GetId(), Name: "Backend", Color: "#6558df"})
	if err != nil || len(labelBoard.GetLabels()) != 1 {
		t.Fatalf("labels=%#v err=%v", labelBoard, err)
	}
	labelID := labelBoard.GetLabels()[0].GetId()
	if _, err := client.SetCardLabels(ctx, &dieterv1.SetCardLabelsRequest{CardId: card.GetId(), LabelIds: []string{labelID}}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.MoveCard(ctx, &dieterv1.MoveCardRequest{CardId: card.GetId(), Lane: model.LaneReview}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.RenameCard(ctx, &dieterv1.RenameCardRequest{CardId: card.GetId(), Title: "Protocol complete"}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.ArchiveCard(ctx, &dieterv1.ArchiveCardRequest{CardId: card.GetId(), Archived: true}); err != nil {
		t.Fatal(err)
	}
	archived, err := client.ListArchivedCards(ctx, &dieterv1.BoardRef{BoardId: board.GetId()})
	if err != nil || len(archived.GetCards()) != 1 {
		t.Fatalf("archived=%#v err=%v", archived, err)
	}

	chat, err := client.CreateChat(ctx, &dieterv1.CreateConversationRequest{ProjectId: project.GetId(), Title: "Standalone", Prompt: "Discuss", Provider: "mock", Model: "mock", DeferStart: true, WorkspaceMode: model.WorkspaceModeProject})
	if err != nil || chat.GetScope() != model.ConversationScopeChat || chat.GetBoardId() != "" {
		t.Fatalf("chat=%#v err=%v", chat, err)
	}
	if _, err := data.Kanban.UpdateCardCache(chat.GetId(), kanban.CardCacheInput{Runtime: "running"}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := data.Conversations.AppendCapability(chat.GetId(), "turn_list", json.RawMessage(`{"id":"subagents","operation":"upsert","subagent":{"id":"worker-list","provider":"mock","messageId":"assistant-list","name":"List scout","status":"running","activity":"Reading files"}}`)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := data.Conversations.AppendCapability(chat.GetId(), "turn_list", json.RawMessage(`{"id":"subagents","operation":"upsert","subagent":{"id":"worker-done","provider":"mock","messageId":"assistant-list","name":"Finished scout","status":"completed"}}`)); err != nil {
		t.Fatal(err)
	}
	chats, err := client.ListChats(ctx, &dieterv1.ListChatsRequest{IncludeArchived: true})
	if err != nil || len(chats.GetChats()) != 1 {
		t.Fatalf("chats=%#v err=%v", chats, err)
	}
	if subagents := chats.GetChats()[0].GetActiveSubagents(); len(subagents) != 1 || subagents[0].GetId() != "worker-list" || subagents[0].GetActivity() != "Reading files" {
		t.Fatalf("active chat subagents=%#v", subagents)
	}
	if _, err := client.PinChat(ctx, &dieterv1.PinChatRequest{CardId: chat.GetId(), Pinned: true}); err != nil {
		t.Fatal(err)
	}
}

func TestPromptConfigurationAPIEndToEnd(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	client, _ := newConnectTestClient(t, data, newFakeRunner())
	ctx := context.Background()
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Prompt project", Path: testkit.CheckoutDir(t), Prompt: "Project baseline"})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Delivery", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	board, err = data.Kanban.CreateBoardLabel(board.ID, "Android", "#3b82f6", "Run emulator verification.")
	if err != nil {
		t.Fatal(err)
	}
	label := board.Labels[0]
	settings, err := client.GetPromptSettings(ctx, &emptypb.Empty{})
	if err != nil || settings.GetBoardSkillTemplate() == "" || len(settings.GetVariables()) == 0 {
		t.Fatalf("prompt settings=%#v err=%v", settings, err)
	}
	global := "Global context\n{{project.instructions_block}}\n{{labels.instructions_block}}"
	if _, err := client.UpdatePromptSettings(ctx, &dieterv1.UpdatePromptSettingsRequest{PromptTemplate: global, BoardSkillTemplate: settings.GetBoardSkillTemplate(), ChatSkillTemplate: settings.GetChatSkillTemplate()}); err != nil {
		t.Fatal(err)
	}
	projectTemplate := "Project context\n{{project.instructions_block}}\n{{labels.instructions_block}}"
	if _, err := client.SetProjectPromptTemplate(ctx, &dieterv1.SetScopedPromptTemplateRequest{ScopeId: project.ID, PromptTemplate: projectTemplate}); err != nil {
		t.Fatal(err)
	}
	boardTemplate := "Board context\n{{project.instructions_block}}\n{{labels.instructions_block}}"
	if _, err := client.SetBoardPromptTemplate(ctx, &dieterv1.SetScopedPromptTemplateRequest{ScopeId: board.ID, PromptTemplate: boardTemplate}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.UpdateBoardLabel(ctx, &dieterv1.UpdateBoardLabelRequest{BoardId: board.ID, LabelId: label.ID, Name: "Android", Color: "#3b82f6", Instructions: "Use Compose and run emulator tests."}); err != nil {
		t.Fatal(err)
	}
	preview, err := client.PreviewPrompt(ctx, &dieterv1.PreviewPromptRequest{ProjectId: project.ID, BoardId: board.ID, Scope: model.ConversationScopeBoard, LabelIds: []string{label.ID}})
	if err != nil || preview.GetSource() != "board" || !strings.Contains(preview.GetInstructions(), "Use Compose") || !strings.Contains(preview.GetSkill(), "dieter card context preview") {
		t.Fatalf("preview=%#v err=%v", preview, err)
	}
	if _, err := client.SetBoardPromptTemplate(ctx, &dieterv1.SetScopedPromptTemplateRequest{ScopeId: board.ID, Inherit: true}); err != nil {
		t.Fatal(err)
	}
	preview, err = client.PreviewPrompt(ctx, &dieterv1.PreviewPromptRequest{ProjectId: project.ID, BoardId: board.ID, Scope: model.ConversationScopeBoard})
	if err != nil || preview.GetSource() != "project" {
		t.Fatalf("inherited preview=%#v err=%v", preview, err)
	}
}

func TestBoardNamingConnectEndToEnd(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), testkit.Budget(30*time.Second))
	defer cancel()
	data := testkit.Store(t)
	client, _ := newConnectTestClient(t, data, newFakeRunner())

	workspace, err := client.CreateProject(ctx, &dieterv1.CreateProjectRequest{
		Mode: "open", Path: testkit.CheckoutDir(t), Name: "Naming", BoardName: "Roadmap", Workflow: model.WorkflowReview,
	})
	if err != nil {
		t.Fatal(err)
	}
	board := workspace.GetBoard()
	if board.GetName() != "Roadmap" {
		t.Fatalf("initial board=%#v", board)
	}
	renamed, err := client.RenameBoard(ctx, &dieterv1.RenameBoardRequest{BoardId: board.GetId(), Name: " Product delivery "})
	if err != nil {
		t.Fatal(err)
	}
	if renamed.GetId() != board.GetId() || renamed.GetName() != "Product delivery" {
		t.Fatalf("renamed board=%#v", renamed)
	}
	configured, err := client.UpdateBoardGitSettings(ctx, &dieterv1.UpdateBoardGitSettingsRequest{
		BoardId: board.GetId(), BaseRemote: "private", RemotePublishMode: model.RemotePublishPullRequest,
	})
	if err != nil || configured.GetBaseRemote() != "private" || configured.GetRemotePublishMode() != model.RemotePublishPullRequest {
		t.Fatalf("configured board=%#v err=%v", configured, err)
	}
	state, err := client.GetState(ctx, &dieterv1.GetStateRequest{ProjectId: workspace.GetProject().GetId()})
	if err != nil {
		t.Fatal(err)
	}
	if len(state.GetBoards()) != 1 || state.GetBoards()[0].GetName() != "Product delivery" || state.GetBoards()[0].GetBaseRemote() != "private" {
		t.Fatalf("persisted boards=%#v", state.GetBoards())
	}
}

func TestConnectRejectsUnknownProjectMode(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), testkit.Budget(30*time.Second))
	defer cancel()
	data := testkit.Store(t)
	client, _ := newConnectTestClient(t, data, newFakeRunner())

	_, err := client.CreateProject(ctx, &dieterv1.CreateProjectRequest{
		Mode: "clone", Path: testkit.CheckoutDir(t), BoardName: "Main", Workflow: model.WorkflowReview,
	})
	if err == nil || !strings.Contains(err.Error(), "project mode must be open or create") {
		t.Fatalf("unknown project mode error=%v", err)
	}
}

func TestConnectCancellationInterruptsActiveTurn(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), testkit.Budget(30*time.Second))
	defer cancel()
	release := make(chan struct{})
	data := testkit.Store(t)
	client, _ := newConnectTestClient(t, data, gatedRunner{release: release}, testkit.MockCatalog())
	workspace, err := client.CreateProject(ctx, &dieterv1.CreateProjectRequest{Mode: "open", Path: testkit.CheckoutDir(t), BoardName: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	card, err := client.CreateCard(ctx, &dieterv1.CreateConversationRequest{ProjectId: workspace.GetProject().GetId(), BoardId: workspace.GetBoard().GetId(), Lane: model.LaneRunning, Title: "Cancel", Prompt: "Wait", Provider: "mock", Model: "mock", DeferStart: true, WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.SendMessage(ctx, &dieterv1.SendMessageRequest{CardId: card.GetId(), Provider: "mock", Model: "mock", Parts: []*dieterv1.MessagePart{{Type: "text", Text: "start"}}}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		conversation, getErr := data.Conversations.Get(card.GetId())
		if getErr == nil && conversation.Status == "running" {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, err := client.CancelCard(ctx, &dieterv1.GetCardRequest{CardId: card.GetId()}); err != nil {
		t.Fatal(err)
	}
	waitForCanceledCard(t, data, card.GetId())
}
