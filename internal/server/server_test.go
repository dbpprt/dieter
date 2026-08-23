package server

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
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
	"google.golang.org/protobuf/types/known/emptypb"
)

type fakeRunner struct{ requests []harness.Request }

func (f *fakeRunner) Run(_ context.Context, request harness.Request, emit func(harness.Output) error) error {
	f.requests = append(f.requests, request)
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

type gatedRunner struct{ release <-chan struct{} }

func (runner gatedRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
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

func newConnectTestClient(t *testing.T, data *store.Store, runner harness.Runner) (dieterv1connect.DieterServiceClient, string) {
	t.Helper()
	application := NewWithRunner(data, slog.New(slog.NewTextHandler(io.Discard, nil)), runner)
	server := httptest.NewServer(application.Handler())
	t.Cleanup(server.Close)
	return dieterv1connect.NewDieterServiceClient(server.Client(), server.URL), server.URL
}

func testRepository(t *testing.T) string {
	t.Helper()
	repo := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(repo, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("# Fixture\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return repo
}

func TestConnectConversationEndToEnd(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	data := store.New(t.TempDir())
	runner := &fakeRunner{}
	client, baseURL := newConnectTestClient(t, data, runner)

	rootResponse, err := http.Get(baseURL + "/")
	if err != nil || rootResponse.StatusCode != http.StatusNotFound {
		t.Fatalf("machine-only root response=%v err=%v", rootResponse, err)
	}
	_ = rootResponse.Body.Close()
	legacyResponse, err := http.Get(baseURL + "/api/v1/state")
	if err != nil {
		t.Fatal(err)
	}
	_ = legacyResponse.Body.Close()
	if legacyResponse.StatusCode != http.StatusNotFound {
		t.Fatalf("legacy API status=%d", legacyResponse.StatusCode)
	}

	health, err := client.Health(ctx, connect.NewRequest(&emptypb.Empty{}))
	if err != nil || health.Msg.GetStatus() != "ok" {
		t.Fatalf("health=%#v err=%v", health, err)
	}
	harnesses, err := client.GetHarnesses(ctx, connect.NewRequest(&emptypb.Empty{}))
	if err != nil || len(harnesses.Msg.GetHarnesses()) < 5 {
		t.Fatalf("harnesses=%#v err=%v", harnesses, err)
	}

	workspace, err := client.CreateProject(ctx, connect.NewRequest(&dieterv1.CreateProjectRequest{
		Mode: "open", Path: testRepository(t), Name: "Connect", BoardName: "Main", Workflow: model.WorkflowReview,
	}))
	if err != nil {
		t.Fatal(err)
	}
	project, board := workspace.Msg.GetProject(), workspace.Msg.GetBoard()
	cardResponse, err := client.CreateCard(ctx, connect.NewRequest(&dieterv1.CreateConversationRequest{
		ProjectId: project.GetId(), BoardId: board.GetId(), Lane: model.LaneTodo,
		Title: "Protocol", Prompt: "Build it", Provider: "mock", Model: "mock", DeferStart: true,
		Attachments: []*dieterv1.MessagePart{{
			Type: "image", MediaType: "image/png", Filename: "wire.png", Data: []byte("png fixture bytes"),
		}},
	}))
	if err != nil {
		t.Fatal(err)
	}
	card := cardResponse.Msg
	draft, err := client.GetConversation(ctx, connect.NewRequest(&dieterv1.GetConversationRequest{CardId: card.GetId(), Limit: 30}))
	if err != nil || len(draft.Msg.GetConversation().GetDraftAttachments()) != 1 || draft.Msg.GetConversation().GetDraftAttachments()[0].GetFilename() != "wire.png" {
		t.Fatalf("draft attachments=%#v err=%v", draft.Msg.GetConversation().GetDraftAttachments(), err)
	}
	updatedCard, err := client.UpdateCard(ctx, connect.NewRequest(&dieterv1.UpdateCardRequest{
		CardId: card.GetId(), Title: "Protocol draft", InitialPrompt: "Build the edited task",
	}))
	if err != nil || updatedCard.Msg.GetTitle() != "Protocol draft" || updatedCard.Msg.GetInitialPrompt() != "Build the edited task" {
		t.Fatalf("updated card=%#v err=%v", updatedCard, err)
	}
	card = updatedCard.Msg

	stream, err := client.WatchConversation(ctx, connect.NewRequest(&dieterv1.WatchConversationRequest{CardId: card.GetId(), Limit: 30, IntervalMs: 10}))
	if err != nil {
		t.Fatal(err)
	}
	if !stream.Receive() || stream.Msg().GetSnapshot() == nil {
		t.Fatalf("initial update=%#v err=%v", stream.Msg(), stream.Err())
	}
	zeroSeq := draft.Msg.GetConversation().GetLastSeq()
	emptyCurrent, err := client.PollConversation(ctx, connect.NewRequest(&dieterv1.PollConversationRequest{CardId: card.GetId(), Limit: 30, AfterSeq: &zeroSeq}))
	if err != nil || emptyCurrent.Msg.GetSnapshot() != nil || emptyCurrent.Msg.GetLastSeq() != zeroSeq {
		t.Fatalf("empty current poll=%#v err=%v", emptyCurrent, err)
	}
	if _, err := client.SendMessage(ctx, connect.NewRequest(&dieterv1.SendMessageRequest{
		CardId: card.GetId(), Provider: "mock", Model: "mock",
		Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Ship through protobuf"}},
	})); err != nil {
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
		cardDetail, detailErr := client.GetCard(ctx, connect.NewRequest(&dieterv1.GetCardRequest{CardId: card.GetId()}))
		if detailErr != nil {
			t.Fatal(detailErr)
		}
		if cardDetail.Msg.GetCard().GetRuntime() == "idle" {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-time.After(10 * time.Millisecond):
		}
	}

	timeline, err := client.GetConversation(ctx, connect.NewRequest(&dieterv1.GetConversationRequest{CardId: card.GetId(), Limit: 30}))
	if err != nil {
		t.Fatal(err)
	}
	if plans := timeline.Msg.GetConversation().GetTaskPlans(); len(plans) != 1 || plans[0].GetState() != "completed" || plans[0].GetPhases()[0].GetTasks()[0].GetContent() != "Build locally" {
		t.Fatalf("task plan protocol projection=%#v", plans)
	}
	if subagents := timeline.Msg.GetConversation().GetSubagents(); len(subagents) != 1 || subagents[0].GetName() != "Verifier" {
		raw, rawErr := data.Conversation(card.GetId())
		t.Fatalf("subagent protocol projection=%#v raw=%#v rawErr=%v", subagents, raw.Subagents, rawErr)
	}
	if len(timeline.Msg.GetConversation().GetDraftAttachments()) != 0 {
		t.Fatalf("sent draft attachments were not cleared: %#v", timeline.Msg.GetConversation().GetDraftAttachments())
	}
	if len(runner.requests) != 1 || len(runner.requests[0].Attachments) != 1 || runner.requests[0].Attachments[0].Filename != "wire.png" || runner.requests[0].Attachments[0].URL != "data:image/png;base64,cG5nIGZpeHR1cmUgYnl0ZXM=" {
		t.Fatalf("attachment did not reach harness: %#v", runner.requests)
	}
	var toolMessageID string
	var toolPart *dieterv1.MessagePart
	for _, message := range timeline.Msg.GetConversation().GetMessages() {
		for _, part := range message.GetParts() {
			if part.GetToolCallId() == "tool_live" {
				toolMessageID, toolPart = message.GetId(), part
			}
		}
	}
	if toolPart == nil || len(toolPart.GetInputJson()) != 0 || len(toolPart.GetOutputJson()) != 0 || !toolPart.GetHasInput() || !toolPart.GetHasOutput() || toolPart.GetPayloadRevision() == "" || toolPart.GetInputPreview() != "printf ready" {
		t.Fatalf("conversation tool envelope=%#v", toolPart)
	}
	tool, err := client.GetToolOutput(ctx, connect.NewRequest(&dieterv1.GetToolOutputRequest{
		CardId: card.GetId(), MessageId: toolMessageID, ToolCallId: toolPart.GetToolCallId(), Revision: toolPart.GetPayloadRevision(),
	}))
	var toolInput map[string]any
	var toolOutput map[string]any
	inputErr, outputErr := json.Unmarshal(tool.Msg.GetInputJson(), &toolInput), json.Unmarshal(tool.Msg.GetOutputJson(), &toolOutput)
	if err != nil || inputErr != nil || outputErr != nil || toolInput["command"] != "printf ready" || toolOutput["stdout"] != "ready" || toolOutput["exitCode"] != float64(0) || tool.Msg.GetRevision() != toolPart.GetPayloadRevision() {
		t.Fatalf("lazy tool input=%q output=%q revision=%q want=%q err=%v", tool.Msg.GetInputJson(), tool.Msg.GetOutputJson(), tool.Msg.GetRevision(), toolPart.GetPayloadRevision(), err)
	}
	currentSeq := timeline.Msg.GetConversation().GetLastSeq()
	unchanged, err := client.PollConversation(ctx, connect.NewRequest(&dieterv1.PollConversationRequest{
		CardId: card.GetId(), Limit: 30, AfterSeq: &currentSeq,
	}))
	if err != nil || unchanged.Msg.GetSnapshot() != nil || unchanged.Msg.GetLastSeq() != timeline.Msg.GetConversation().GetLastSeq() {
		t.Fatalf("unchanged poll=%#v err=%v", unchanged, err)
	}
	if _, _, err := data.AppendConversationEvent(card.GetId(), "status", "", "", "idle"); err != nil {
		t.Fatal(err)
	}
	delta, err := client.PollConversation(ctx, connect.NewRequest(&dieterv1.PollConversationRequest{
		CardId: card.GetId(), Limit: 30, AfterSeq: &currentSeq,
	}))
	if err != nil || delta.Msg.GetSnapshot() != nil || delta.Msg.GetPage() == nil || delta.Msg.GetLastSeq() <= timeline.Msg.GetConversation().GetLastSeq() || len(delta.Msg.GetTaskPlans()) != 1 || len(delta.Msg.GetSubagents()) != 1 {
		t.Fatalf("current cursor delta=%#v err=%v", delta, err)
	}
	staleSeq := int64(999999)
	stale, err := client.PollConversation(ctx, connect.NewRequest(&dieterv1.PollConversationRequest{CardId: card.GetId(), Limit: 30, AfterSeq: &staleSeq}))
	if err != nil || stale.Msg.GetSnapshot() == nil || len(stale.Msg.GetSnapshot().GetConversation().GetMessages()) == 0 {
		t.Fatalf("stale poll=%#v err=%v", stale, err)
	}

	comment, err := client.AddComment(ctx, connect.NewRequest(&dieterv1.AddCommentRequest{CardId: card.GetId(), Message: "Reviewed", Name: "Human"}))
	if err != nil || comment.Msg.GetBody() != "Reviewed" {
		t.Fatalf("comment=%#v err=%v", comment, err)
	}
	labelBoard, err := client.CreateBoardLabel(ctx, connect.NewRequest(&dieterv1.CreateBoardLabelRequest{BoardId: board.GetId(), Name: "Backend", Color: "#6558df"}))
	if err != nil || len(labelBoard.Msg.GetLabels()) != 1 {
		t.Fatalf("labels=%#v err=%v", labelBoard, err)
	}
	labelID := labelBoard.Msg.GetLabels()[0].GetId()
	if _, err := client.SetCardLabels(ctx, connect.NewRequest(&dieterv1.SetCardLabelsRequest{CardId: card.GetId(), LabelIds: []string{labelID}})); err != nil {
		t.Fatal(err)
	}
	if _, err := client.MoveCard(ctx, connect.NewRequest(&dieterv1.MoveCardRequest{CardId: card.GetId(), Lane: model.LaneReview})); err != nil {
		t.Fatal(err)
	}
	if _, err := client.RenameCard(ctx, connect.NewRequest(&dieterv1.RenameCardRequest{CardId: card.GetId(), Title: "Protocol complete"})); err != nil {
		t.Fatal(err)
	}
	if _, err := client.ArchiveCard(ctx, connect.NewRequest(&dieterv1.ArchiveCardRequest{CardId: card.GetId(), Archived: true})); err != nil {
		t.Fatal(err)
	}
	archived, err := client.ListArchivedCards(ctx, connect.NewRequest(&dieterv1.BoardRef{BoardId: board.GetId()}))
	if err != nil || len(archived.Msg.GetCards()) != 1 {
		t.Fatalf("archived=%#v err=%v", archived, err)
	}

	chat, err := client.CreateChat(ctx, connect.NewRequest(&dieterv1.CreateConversationRequest{ProjectId: project.GetId(), Title: "Standalone", Prompt: "Discuss", Provider: "mock", Model: "mock", DeferStart: true}))
	if err != nil || chat.Msg.GetScope() != model.ConversationScopeChat || chat.Msg.GetBoardId() != "" {
		t.Fatalf("chat=%#v err=%v", chat, err)
	}
	if _, err := data.UpdateCardCache(chat.Msg.GetId(), store.CardCacheInput{Runtime: "running"}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := data.AppendCapability(chat.Msg.GetId(), "turn_list", json.RawMessage(`{"id":"subagents","operation":"upsert","subagent":{"id":"worker-list","provider":"mock","messageId":"assistant-list","name":"List scout","status":"running","activity":"Reading files"}}`)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := data.AppendCapability(chat.Msg.GetId(), "turn_list", json.RawMessage(`{"id":"subagents","operation":"upsert","subagent":{"id":"worker-done","provider":"mock","messageId":"assistant-list","name":"Finished scout","status":"completed"}}`)); err != nil {
		t.Fatal(err)
	}
	chats, err := client.ListChats(ctx, connect.NewRequest(&dieterv1.ListChatsRequest{IncludeArchived: true}))
	if err != nil || len(chats.Msg.GetChats()) != 1 {
		t.Fatalf("chats=%#v err=%v", chats, err)
	}
	if subagents := chats.Msg.GetChats()[0].GetActiveSubagents(); len(subagents) != 1 || subagents[0].GetId() != "worker-list" || subagents[0].GetActivity() != "Reading files" {
		t.Fatalf("active chat subagents=%#v", subagents)
	}
	if _, err := client.PinChat(ctx, connect.NewRequest(&dieterv1.PinChatRequest{CardId: chat.Msg.GetId(), Pinned: true})); err != nil {
		t.Fatal(err)
	}
}

func TestPromptConfigurationAPIEndToEnd(t *testing.T) {
	data := store.New(t.TempDir())
	client, _ := newConnectTestClient(t, data, &fakeRunner{})
	ctx := context.Background()
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Prompt project", Path: testRepository(t), Prompt: "Project baseline"})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Delivery", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	board, err = data.CreateBoardLabel(board.ID, "Android", "#3b82f6", "Run emulator verification.")
	if err != nil {
		t.Fatal(err)
	}
	label := board.Labels[0]
	settings, err := client.GetPromptSettings(ctx, connect.NewRequest(&emptypb.Empty{}))
	if err != nil || settings.Msg.GetBoardSkillTemplate() == "" || len(settings.Msg.GetVariables()) == 0 {
		t.Fatalf("prompt settings=%#v err=%v", settings, err)
	}
	global := "Global context\n{{project.instructions_block}}\n{{labels.instructions_block}}"
	if _, err := client.UpdatePromptSettings(ctx, connect.NewRequest(&dieterv1.UpdatePromptSettingsRequest{PromptTemplate: global, BoardSkillTemplate: settings.Msg.GetBoardSkillTemplate(), ChatSkillTemplate: settings.Msg.GetChatSkillTemplate()})); err != nil {
		t.Fatal(err)
	}
	projectTemplate := "Project context\n{{project.instructions_block}}\n{{labels.instructions_block}}"
	if _, err := client.SetProjectPromptTemplate(ctx, connect.NewRequest(&dieterv1.SetScopedPromptTemplateRequest{ScopeId: project.ID, PromptTemplate: projectTemplate})); err != nil {
		t.Fatal(err)
	}
	boardTemplate := "Board context\n{{project.instructions_block}}\n{{labels.instructions_block}}"
	if _, err := client.SetBoardPromptTemplate(ctx, connect.NewRequest(&dieterv1.SetScopedPromptTemplateRequest{ScopeId: board.ID, PromptTemplate: boardTemplate})); err != nil {
		t.Fatal(err)
	}
	if _, err := client.UpdateBoardLabel(ctx, connect.NewRequest(&dieterv1.UpdateBoardLabelRequest{BoardId: board.ID, LabelId: label.ID, Name: "Android", Color: "#3b82f6", Instructions: "Use Compose and run emulator tests."})); err != nil {
		t.Fatal(err)
	}
	preview, err := client.PreviewPrompt(ctx, connect.NewRequest(&dieterv1.PreviewPromptRequest{ProjectId: project.ID, BoardId: board.ID, Scope: model.ConversationScopeBoard, LabelIds: []string{label.ID}}))
	if err != nil || preview.Msg.GetSource() != "board" || !strings.Contains(preview.Msg.GetInstructions(), "Use Compose") || !strings.Contains(preview.Msg.GetSkill(), "dieter card context preview") {
		t.Fatalf("preview=%#v err=%v", preview, err)
	}
	if _, err := client.SetBoardPromptTemplate(ctx, connect.NewRequest(&dieterv1.SetScopedPromptTemplateRequest{ScopeId: board.ID, Inherit: true})); err != nil {
		t.Fatal(err)
	}
	preview, err = client.PreviewPrompt(ctx, connect.NewRequest(&dieterv1.PreviewPromptRequest{ProjectId: project.ID, BoardId: board.ID, Scope: model.ConversationScopeBoard}))
	if err != nil || preview.Msg.GetSource() != "project" {
		t.Fatalf("inherited preview=%#v err=%v", preview, err)
	}
}

func TestBoardNamingConnectEndToEnd(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	data := store.New(t.TempDir())
	client, _ := newConnectTestClient(t, data, &fakeRunner{})

	workspace, err := client.CreateProject(ctx, connect.NewRequest(&dieterv1.CreateProjectRequest{
		Mode: "open", Path: testRepository(t), Name: "Naming", BoardName: "Roadmap", Workflow: model.WorkflowReview,
	}))
	if err != nil {
		t.Fatal(err)
	}
	board := workspace.Msg.GetBoard()
	if board.GetName() != "Roadmap" {
		t.Fatalf("initial board=%#v", board)
	}
	renamed, err := client.RenameBoard(ctx, connect.NewRequest(&dieterv1.RenameBoardRequest{BoardId: board.GetId(), Name: " Product delivery "}))
	if err != nil {
		t.Fatal(err)
	}
	if renamed.Msg.GetId() != board.GetId() || renamed.Msg.GetName() != "Product delivery" {
		t.Fatalf("renamed board=%#v", renamed.Msg)
	}
	state, err := client.GetState(ctx, connect.NewRequest(&dieterv1.GetStateRequest{ProjectId: workspace.Msg.GetProject().GetId()}))
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Msg.GetBoards()) != 1 || state.Msg.GetBoards()[0].GetName() != "Product delivery" {
		t.Fatalf("persisted boards=%#v", state.Msg.GetBoards())
	}
}

func TestConnectCancellationInterruptsActiveTurn(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	release := make(chan struct{})
	data := store.New(t.TempDir())
	client, _ := newConnectTestClient(t, data, gatedRunner{release: release})
	workspace, err := client.CreateProject(ctx, connect.NewRequest(&dieterv1.CreateProjectRequest{Mode: "open", Path: testRepository(t), BoardName: "Main", Workflow: model.WorkflowReview}))
	if err != nil {
		t.Fatal(err)
	}
	card, err := client.CreateCard(ctx, connect.NewRequest(&dieterv1.CreateConversationRequest{ProjectId: workspace.Msg.GetProject().GetId(), BoardId: workspace.Msg.GetBoard().GetId(), Lane: model.LaneRunning, Title: "Cancel", Prompt: "Wait", Provider: "mock", Model: "mock", DeferStart: true}))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.SendMessage(ctx, connect.NewRequest(&dieterv1.SendMessageRequest{CardId: card.Msg.GetId(), Provider: "mock", Model: "mock", Parts: []*dieterv1.MessagePart{{Type: "text", Text: "start"}}})); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		conversation, getErr := data.Conversation(card.Msg.GetId())
		if getErr == nil && conversation.Status == "running" {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, err := client.CancelCard(ctx, connect.NewRequest(&dieterv1.GetCardRequest{CardId: card.Msg.GetId()})); err != nil {
		t.Fatal(err)
	}
	var conversation model.Conversation
	deadline = time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		conversation, err = data.Conversation(card.Msg.GetId())
		if err == nil && conversation.Status != "running" {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if err != nil || conversation.Status == "running" {
		t.Fatalf("conversation=%#v err=%v", conversation, err)
	}
	leasePath := filepath.Join(data.RuntimeDir(), "leases", workspace.Msg.GetProject().GetId()+".json")
	deadline = time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		_, leaseErr := os.Stat(leasePath)
		_, lockErr := os.Stat(filepath.Join(data.Root, ".write-lock"))
		if os.IsNotExist(leaseErr) && os.IsNotExist(lockErr) {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
}
