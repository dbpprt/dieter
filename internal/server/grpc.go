package server

import (
	"context"
	"crypto/sha256"
	"errors"
	"io/fs"
	"mime"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/dbpprt/dieter/internal/app"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/terminal"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

type grpcAPI struct {
	dieterv1.UnimplementedDieterServiceServer
	server            *Server
	conversationMu    sync.Mutex
	conversationCache map[string]cachedConversation
	conversationTick  uint64
	snapshotMu        sync.Mutex
	snapshotCache     map[string]snapshotHistory
	snapshotTick      uint64
	commandMu         sync.Mutex
}

type cachedConversation struct {
	revision string
	value    model.Conversation
	accessed uint64
}

const maxCachedConversations = 12

type sequencedSnapshot struct {
	seq      int64
	snapshot *dieterv1.ConversationSnapshot
}

type snapshotHistory struct {
	accessed uint64
	values   []sequencedSnapshot
}

const maxSnapshotsPerConversation = 8

func (api *grpcAPI) Health(context.Context, *emptypb.Empty) (*dieterv1.HealthResponse, error) {
	return &dieterv1.HealthResponse{Status: "ok", Version: "2", StorePath: api.server.store.Root}, nil
}

func (api *grpcAPI) RenameBoard(_ context.Context, request *dieterv1.RenameBoardRequest) (*dieterv1.Board, error) {
	value, err := api.server.store.RenameBoard(request.GetBoardId(), request.GetName())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoBoard(value), nil
}

func (api *grpcAPI) GetState(_ context.Context, request *dieterv1.GetStateRequest) (*dieterv1.State, error) {
	value, err := api.server.store.State(request.GetProjectId(), store.CardFilter{
		Board: request.GetBoardId(), Lane: request.GetLane(), Runtime: request.GetRuntime(),
		Query: request.GetQuery(), Label: request.GetLabelId(), Limit: int(request.GetLimit()),
	})
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoState(value), nil
}

func (api *grpcAPI) GetHarnesses(ctx context.Context, _ *emptypb.Empty) (*dieterv1.HarnessCatalog, error) {
	return protoHarnessCatalog(harness.RefreshCatalog(ctx, os.Getenv("DIETER_ENABLE_MOCK_HARNESS") == "1")), nil
}

func (api *grpcAPI) GetPromptSettings(context.Context, *emptypb.Empty) (*dieterv1.PromptSettings, error) {
	value, err := api.server.store.Settings()
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoPromptSettings(value), nil
}

func (api *grpcAPI) UpdatePromptSettings(_ context.Context, request *dieterv1.UpdatePromptSettingsRequest) (*dieterv1.PromptSettings, error) {
	value, err := api.server.store.UpdatePromptSettings(request.GetPromptTemplate(), request.GetBoardSkillTemplate(), request.GetChatSkillTemplate())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoPromptSettings(value), nil
}

func (api *grpcAPI) SetProjectPromptTemplate(_ context.Context, request *dieterv1.SetScopedPromptTemplateRequest) (*dieterv1.Project, error) {
	template := request.GetPromptTemplate()
	if request.GetInherit() {
		template = ""
	}
	value, err := api.server.store.UpdateProjectPromptTemplate(request.GetScopeId(), template)
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoProject(value), nil
}

func (api *grpcAPI) SetBoardPromptTemplate(_ context.Context, request *dieterv1.SetScopedPromptTemplateRequest) (*dieterv1.Board, error) {
	template := request.GetPromptTemplate()
	if request.GetInherit() {
		template = ""
	}
	value, err := api.server.store.UpdateBoardPromptTemplate(request.GetScopeId(), template)
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoBoard(value), nil
}

func (api *grpcAPI) PreviewPrompt(_ context.Context, request *dieterv1.PreviewPromptRequest) (*dieterv1.PromptPreview, error) {
	var detail model.CardDetail
	var err error
	if request.GetCardId() != "" {
		detail, err = api.server.store.CardDetail(request.GetCardId())
	} else {
		detail.Project, err = api.server.store.ResolveProject(request.GetProjectId())
		if err == nil && request.GetBoardId() != "" {
			detail.Board, err = api.server.store.ResolveBoard(detail.Project.ID, request.GetBoardId())
		}
		detail.Card = model.Card{ID: "preview", Scope: request.GetScope(), ProjectID: detail.Project.ID, BoardID: detail.Board.ID, Lane: model.LaneTodo, Title: "Prompt preview", LabelIDs: request.GetLabelIds()}
		if detail.Card.Scope == "" {
			if detail.Board.ID != "" {
				detail.Card.Scope = model.ConversationScopeBoard
			} else {
				detail.Card.Scope = model.ConversationScopeChat
			}
		}
	}
	if err != nil {
		return nil, grpcFailure(err)
	}
	labelIDs := request.GetLabelIds()
	if request.GetCardId() != "" && len(labelIDs) == 0 {
		labelIDs = detail.Card.LabelIDs
	}
	settings, err := api.server.store.Settings()
	if err != nil {
		return nil, grpcFailure(err)
	}
	resolved, err := dieterprompt.Resolve(settings, detail, labelIDs)
	if err != nil {
		return nil, grpcFailure(err)
	}
	result := &dieterv1.PromptPreview{
		Source: resolved.Source, PromptTemplate: resolved.Template, Context: resolved.Context,
		Skill: resolved.Skill, Instructions: resolved.Instructions,
		Characters: int32(len(resolved.Instructions)), EstimatedTokens: int32((len(resolved.Instructions) + 3) / 4),
	}
	for _, label := range resolved.AppliedLabels {
		result.AppliedLabels = append(result.AppliedLabels, &dieterv1.Label{Id: label.ID, Name: label.Name, Color: label.Color, Instructions: label.Instructions})
	}
	return result, nil
}

func conversationInput(request *dieterv1.CreateConversationRequest) (app.CardInput, error) {
	attachments, err := modelUserAttachmentParts(request.GetAttachments())
	if err != nil {
		return app.CardInput{}, err
	}
	return app.CardInput{
		Project: request.GetProjectId(), Board: request.GetBoardId(), Lane: request.GetLane(),
		Title: request.GetTitle(), Prompt: request.GetPrompt(), Provider: request.GetProvider(),
		Model: request.GetModel(), Effort: request.GetEffort(), ProviderOptions: cloneProtoStringMap(request.GetProviderOptions()),
		LabelIDs: append([]string(nil), request.GetLabelIds()...), DeferStart: request.GetDeferStart(), Attachments: attachments,
	}, nil
}

func (api *grpcAPI) idempotentConversation(ctx context.Context, request *dieterv1.CreateConversationRequest, scope string) (*dieterv1.Card, error) {
	clientID, commandID := strings.TrimSpace(request.GetClientId()), strings.TrimSpace(request.GetCommandId())
	if clientID == "" && commandID == "" {
		input, err := conversationInput(request)
		if err != nil {
			return nil, grpcFailure(err)
		}
		value, err := func() (model.Card, error) {
			if scope == model.ConversationScopeChat {
				return api.server.app.CreateChat(ctx, input)
			}
			return api.server.app.CreateCard(ctx, input)
		}()
		if err != nil {
			return nil, grpcFailure(err)
		}
		return protoCard(value), nil
	}
	api.commandMu.Lock()
	defer api.commandMu.Unlock()
	kind := "create_" + scope
	if result, ok, err := api.server.store.LoadCommandResult(clientID, commandID); err != nil {
		return nil, grpcFailure(err)
	} else if ok {
		if result.Kind != kind {
			return nil, status.Error(codes.AlreadyExists, "command_id was already used for another operation")
		}
		card, resolveErr := api.server.store.ResolveCard(result.CardID)
		if resolveErr != nil {
			return nil, grpcFailure(resolveErr)
		}
		return protoCard(card), nil
	}
	cardID, err := store.DeterministicCommandID("c_", clientID, commandID)
	if err != nil {
		return nil, grpcFailure(err)
	}
	if existing, resolveErr := api.server.store.ResolveCard(cardID); resolveErr == nil {
		if existing.Scope != scope {
			return nil, status.Error(codes.AlreadyExists, "command_id resolved to another conversation scope")
		}
		if saveErr := api.server.store.SaveCommandResult(clientID, commandID, store.CommandResult{Kind: kind, CardID: cardID}); saveErr != nil {
			return nil, grpcFailure(saveErr)
		}
		return protoCard(existing), nil
	} else if !errors.Is(resolveErr, store.ErrNotFound) {
		return nil, grpcFailure(resolveErr)
	}
	input, err := conversationInput(request)
	if err != nil {
		return nil, grpcFailure(err)
	}
	input.ID = cardID
	var value model.Card
	if scope == model.ConversationScopeChat {
		value, err = api.server.app.CreateChat(ctx, input)
	} else {
		value, err = api.server.app.CreateCard(ctx, input)
	}
	if err != nil {
		return nil, grpcFailure(err)
	}
	if err := api.server.store.SaveCommandResult(clientID, commandID, store.CommandResult{Kind: kind, CardID: value.ID}); err != nil {
		return nil, grpcFailure(err)
	}
	return protoCard(value), nil
}

func cloneProtoStringMap(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	result := make(map[string]string, len(values))
	for key, value := range values {
		result[key] = value
	}
	return result
}

func (api *grpcAPI) CreateCard(ctx context.Context, request *dieterv1.CreateConversationRequest) (*dieterv1.Card, error) {
	return api.idempotentConversation(ctx, request, model.ConversationScopeBoard)
}

func (api *grpcAPI) CreateChat(ctx context.Context, request *dieterv1.CreateConversationRequest) (*dieterv1.Card, error) {
	return api.idempotentConversation(ctx, request, model.ConversationScopeChat)
}

func (api *grpcAPI) ListChats(_ context.Context, request *dieterv1.ListChatsRequest) (*dieterv1.ChatsResponse, error) {
	projects, err := api.server.store.ListProjects()
	if err != nil {
		return nil, grpcFailure(err)
	}
	chats, err := api.server.store.ListCards(store.CardFilter{
		Scope: model.ConversationScopeChat, IncludeArchived: request.GetIncludeArchived(),
	})
	if err != nil {
		return nil, grpcFailure(err)
	}
	result := &dieterv1.ChatsResponse{}
	for _, value := range projects {
		result.Projects = append(result.Projects, protoProject(value))
	}
	for _, value := range chats {
		chat := protoCard(value)
		if value.Runtime == "running" || value.Runtime == "starting" {
			conversation, conversationErr := api.conversation(value.ID)
			if conversationErr != nil {
				return nil, grpcFailure(conversationErr)
			}
			for _, subagent := range conversation.Subagents {
				if subagent.Status == "running" || subagent.Status == "pending" {
					chat.ActiveSubagents = append(chat.ActiveSubagents, protoSubagent(subagent))
				}
			}
		}
		result.Chats = append(result.Chats, chat)
	}
	return result, nil
}

func (api *grpcAPI) GetCard(_ context.Context, request *dieterv1.GetCardRequest) (*dieterv1.CardDetail, error) {
	value, err := api.server.store.CardDetail(request.GetCardId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoCardDetail(value), nil
}

func (api *grpcAPI) conversation(cardID string) (model.Conversation, error) {
	revision, err := api.server.store.ConversationRevision(cardID)
	if err != nil {
		return model.Conversation{}, err
	}
	api.conversationMu.Lock()
	cached, ok := api.conversationCache[cardID]
	if ok && cached.revision == revision {
		api.conversationTick++
		cached.accessed = api.conversationTick
		api.conversationCache[cardID] = cached
	}
	api.conversationMu.Unlock()
	if ok && cached.revision == revision {
		return cached.value, nil
	}
	conversation, err := api.server.store.Conversation(cardID)
	if err != nil {
		return model.Conversation{}, err
	}
	api.conversationMu.Lock()
	if api.conversationCache == nil {
		api.conversationCache = make(map[string]cachedConversation)
	}
	api.conversationTick++
	api.conversationCache[cardID] = cachedConversation{revision: revision, value: conversation, accessed: api.conversationTick}
	if len(api.conversationCache) > maxCachedConversations {
		oldestID, oldestTick := "", api.conversationTick
		for id, item := range api.conversationCache {
			if id != cardID && item.accessed <= oldestTick {
				oldestID, oldestTick = id, item.accessed
			}
		}
		delete(api.conversationCache, oldestID)
	}
	api.conversationMu.Unlock()
	return conversation, nil
}

func (api *grpcAPI) conversationSnapshot(cardID string, limit int, before *int32) (*dieterv1.ConversationSnapshot, error) {
	detail, err := api.server.store.CardDetail(cardID)
	if err != nil {
		return nil, err
	}
	conversation, err := api.conversation(cardID)
	if err != nil {
		return nil, err
	}
	if limit < 1 {
		limit = 30
	}
	limit = min(limit, 100)
	end := len(conversation.Messages)
	if before != nil {
		if *before < 0 {
			return nil, errors.New("before must be a non-negative integer")
		}
		end = min(int(*before), end)
	}
	start := max(0, end-limit)
	total := len(conversation.Messages)
	conversation.Messages = append([]model.UIMessage(nil), conversation.Messages[start:end]...)
	visibleMessages := make(map[string]bool, len(conversation.Messages))
	for _, message := range conversation.Messages {
		visibleMessages[message.ID] = true
	}
	visibleSubagents := make([]model.Subagent, 0, len(conversation.Subagents))
	for _, subagent := range conversation.Subagents {
		if visibleMessages[subagent.MessageID] {
			visibleSubagents = append(visibleSubagents, subagent)
		}
	}
	conversation.Subagents = visibleSubagents
	visibleTaskPlans := make([]model.TaskPlan, 0, len(conversation.TaskPlans))
	for _, plan := range conversation.TaskPlans {
		if visibleMessages[plan.MessageID] {
			visibleTaskPlans = append(visibleTaskPlans, plan)
		}
	}
	conversation.TaskPlans = visibleTaskPlans
	snapshot := &dieterv1.ConversationSnapshot{
		Detail: protoCardDetail(detail), Conversation: protoConversation(conversation),
		Page: &dieterv1.ConversationPage{
			Start: int32(start), End: int32(end), Total: int32(total), HasMore: start > 0,
		},
	}
	if before == nil {
		api.rememberConversationSnapshot(cardID, snapshot)
	}
	return snapshot, nil
}

func (api *grpcAPI) rememberConversationSnapshot(cardID string, snapshot *dieterv1.ConversationSnapshot) {
	seq := snapshot.GetConversation().GetLastSeq()
	api.snapshotMu.Lock()
	defer api.snapshotMu.Unlock()
	if api.snapshotCache == nil {
		api.snapshotCache = make(map[string]snapshotHistory)
	}
	api.snapshotTick++
	history := api.snapshotCache[cardID]
	history.accessed = api.snapshotTick
	if len(history.values) > 0 && history.values[len(history.values)-1].seq == seq {
		history.values[len(history.values)-1].snapshot = snapshot
	} else {
		history.values = append(history.values, sequencedSnapshot{seq: seq, snapshot: snapshot})
		if len(history.values) > maxSnapshotsPerConversation {
			history.values = append([]sequencedSnapshot(nil), history.values[len(history.values)-maxSnapshotsPerConversation:]...)
		}
	}
	api.snapshotCache[cardID] = history
	if len(api.snapshotCache) <= maxCachedConversations {
		return
	}
	oldestID, oldestTick := "", api.snapshotTick
	for id, item := range api.snapshotCache {
		if id != cardID && item.accessed <= oldestTick {
			oldestID, oldestTick = id, item.accessed
		}
	}
	delete(api.snapshotCache, oldestID)
}

func (api *grpcAPI) rememberedConversationSnapshot(cardID string, seq int64) *dieterv1.ConversationSnapshot {
	api.snapshotMu.Lock()
	defer api.snapshotMu.Unlock()
	history, ok := api.snapshotCache[cardID]
	if !ok {
		return nil
	}
	api.snapshotTick++
	history.accessed = api.snapshotTick
	api.snapshotCache[cardID] = history
	for index := len(history.values) - 1; index >= 0; index-- {
		if history.values[index].seq == seq {
			return history.values[index].snapshot
		}
	}
	return nil
}

func (api *grpcAPI) GetConversation(_ context.Context, request *dieterv1.GetConversationRequest) (*dieterv1.ConversationSnapshot, error) {
	value, err := api.conversationSnapshot(request.GetCardId(), int(request.GetLimit()), request.Before)
	if err != nil {
		return nil, grpcFailure(err)
	}
	return value, nil
}

func (api *grpcAPI) PollConversation(_ context.Context, request *dieterv1.PollConversationRequest) (*dieterv1.ConversationUpdate, error) {
	snapshot, err := api.conversationSnapshot(request.GetCardId(), int(request.GetLimit()), nil)
	if err != nil {
		return nil, grpcFailure(err)
	}
	conversation := snapshot.GetConversation()
	if request.AfterSeq != nil && request.GetAfterSeq() == conversation.GetLastSeq() {
		return &dieterv1.ConversationUpdate{
			Status: conversation.GetStatus(), LastSeq: conversation.GetLastSeq(), UpdatedAt: conversation.GetUpdatedAt(),
		}, nil
	}
	if request.AfterSeq != nil {
		if previous := api.rememberedConversationSnapshot(request.GetCardId(), request.GetAfterSeq()); previous != nil {
			return conversationDelta(previous, snapshot), nil
		}
	}
	return &dieterv1.ConversationUpdate{Snapshot: snapshot}, nil
}

func (api *grpcAPI) GetToolOutput(_ context.Context, request *dieterv1.GetToolOutputRequest) (*dieterv1.ToolOutput, error) {
	conversation, err := api.conversation(request.GetCardId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	for _, message := range conversation.Messages {
		if message.ID != request.GetMessageId() {
			continue
		}
		for _, part := range message.Parts {
			if part.ToolCallID != request.GetToolCallId() || (part.Type != "dynamic-tool" && !strings.HasPrefix(part.Type, "tool-")) {
				continue
			}
			return &dieterv1.ToolOutput{
				CardId: conversation.CardID, MessageId: message.ID,
				ToolCallId: part.ToolCallID, ToolName: part.ToolName, State: part.State,
				InputJson: append([]byte(nil), part.Input...), OutputJson: append([]byte(nil), part.Output...),
				ErrorText: part.ErrorText, Revision: toolPayloadRevision(part),
			}, nil
		}
	}
	return nil, status.Errorf(codes.NotFound, "tool call %q was not found in message %q", request.GetToolCallId(), request.GetMessageId())
}

func (api *grpcAPI) watchConversation(ctx context.Context, request *dieterv1.WatchConversationRequest, send func(*dieterv1.ConversationUpdate) error) error {
	interval := time.Duration(request.GetIntervalMs()) * time.Millisecond
	if interval <= 0 {
		interval = 350 * time.Millisecond
	}
	if interval < 100*time.Millisecond {
		interval = 100 * time.Millisecond
	}
	if interval > 5*time.Second {
		interval = 5 * time.Second
	}
	var previous [sha256.Size]byte
	var previousSnapshot *dieterv1.ConversationSnapshot
	resumeSeq := request.GetAfterSeq()
	sendChanged := func() error {
		snapshot, err := api.conversationSnapshot(request.GetCardId(), int(request.GetLimit()), nil)
		if err != nil {
			return err
		}
		raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(snapshot)
		if err != nil {
			return err
		}
		digest := sha256.Sum256(raw)
		if previousSnapshot == nil && resumeSeq > 0 && resumeSeq == snapshot.GetConversation().GetLastSeq() {
			previous = digest
			previousSnapshot = snapshot
			return nil
		}
		if digest == previous {
			return nil
		}
		update := conversationDelta(previousSnapshot, snapshot)
		if err := send(update); err != nil {
			return err
		}
		previous = digest
		previousSnapshot = snapshot
		return nil
	}
	if err := sendChanged(); err != nil {
		return grpcFailure(err)
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			if err := sendChanged(); err != nil {
				return grpcFailure(err)
			}
		}
	}
}

func (api *grpcAPI) WatchConversation(request *dieterv1.WatchConversationRequest, stream dieterv1.DieterService_WatchConversationServer) error {
	return api.watchConversation(stream.Context(), request, stream.Send)
}

func conversationDelta(previous, current *dieterv1.ConversationSnapshot) *dieterv1.ConversationUpdate {
	if previous == nil {
		return &dieterv1.ConversationUpdate{Snapshot: current}
	}
	update := &dieterv1.ConversationUpdate{
		Status:           current.GetConversation().GetStatus(),
		PendingTools:     current.GetConversation().GetPendingTools(),
		Queue:            current.GetConversation().GetQueue(),
		LastSeq:          current.GetConversation().GetLastSeq(),
		UpdatedAt:        current.GetConversation().GetUpdatedAt(),
		Page:             current.GetPage(),
		Subagents:        current.GetConversation().GetSubagents(),
		TaskPlans:        current.GetConversation().GetTaskPlans(),
		DraftAttachments: current.GetConversation().GetDraftAttachments(),
	}
	before := make(map[string]*dieterv1.UiMessage, len(previous.GetConversation().GetMessages()))
	for _, message := range previous.GetConversation().GetMessages() {
		before[message.GetId()] = message
	}
	after := make(map[string]bool, len(current.GetConversation().GetMessages()))
	for _, message := range current.GetConversation().GetMessages() {
		after[message.GetId()] = true
		if old := before[message.GetId()]; old == nil || !proto.Equal(old, message) {
			update.ChangedMessages = append(update.ChangedMessages, message)
		}
	}
	for id := range before {
		if !after[id] {
			update.RemovedMessageIds = append(update.RemovedMessageIds, id)
		}
	}
	if !proto.Equal(previous.GetDetail(), current.GetDetail()) {
		update.Detail = current.GetDetail()
	}
	return update
}

// SendMessage only uses the RPC context for admission. SubmitCardParts creates
// a daemon-owned turn context, so a client disconnect after this method returns
// never cancels an admitted agent turn.
func (api *grpcAPI) SendMessage(_ context.Context, request *dieterv1.SendMessageRequest) (*dieterv1.SendMessageResponse, error) {
	parts, err := modelUserMessageParts(request.GetParts())
	if err != nil {
		return nil, grpcFailure(err)
	}
	clientID, commandID := strings.TrimSpace(request.GetClientId()), strings.TrimSpace(request.GetCommandId())
	if (clientID == "") != (commandID == "") {
		return nil, status.Error(codes.InvalidArgument, "client_id and command_id must be supplied together")
	}
	if clientID == "" {
		queued, submitErr := api.server.app.SubmitCardParts(
			request.GetCardId(), parts, request.GetProvider(), request.GetModel(), request.GetEffort(), cloneProtoStringMap(request.GetProviderOptions()),
		)
		if submitErr != nil {
			return nil, grpcFailure(submitErr)
		}
		return &dieterv1.SendMessageResponse{Sent: !queued, Queued: queued}, nil
	}
	api.commandMu.Lock()
	defer api.commandMu.Unlock()
	if result, ok, loadErr := api.server.store.LoadCommandResult(clientID, commandID); loadErr != nil {
		return nil, grpcFailure(loadErr)
	} else if ok {
		if result.Kind != "send_message" {
			return nil, status.Error(codes.AlreadyExists, "command_id was already used for another operation")
		}
		return &dieterv1.SendMessageResponse{Sent: result.Sent, Queued: result.Queued, MessageId: result.MessageID}, nil
	}
	messageID := strings.TrimSpace(request.GetMessageId())
	if messageID == "" {
		messageID, err = store.DeterministicCommandID("msg_", clientID, commandID)
		if err != nil {
			return nil, grpcFailure(err)
		}
	}
	if len(messageID) > 200 || strings.ContainsAny(messageID, `/\\`) {
		return nil, status.Error(codes.InvalidArgument, "message_id is invalid")
	}
	if conversation, conversationErr := api.server.store.Conversation(request.GetCardId()); conversationErr == nil {
		for _, message := range conversation.Messages {
			if message.ID == messageID {
				result := store.CommandResult{Kind: "send_message", MessageID: messageID, Sent: true}
				if saveErr := api.server.store.SaveCommandResult(clientID, commandID, result); saveErr != nil {
					return nil, grpcFailure(saveErr)
				}
				return &dieterv1.SendMessageResponse{Sent: true, MessageId: messageID}, nil
			}
		}
		for _, queuedMessage := range conversation.Queue {
			if queuedMessage.ID == messageID {
				result := store.CommandResult{Kind: "send_message", MessageID: messageID, Queued: true}
				if saveErr := api.server.store.SaveCommandResult(clientID, commandID, result); saveErr != nil {
					return nil, grpcFailure(saveErr)
				}
				return &dieterv1.SendMessageResponse{Queued: true, MessageId: messageID}, nil
			}
		}
	}
	queued, err := api.server.app.SubmitCardPartsWithMessageID(
		request.GetCardId(), parts, request.GetProvider(), request.GetModel(), request.GetEffort(), cloneProtoStringMap(request.GetProviderOptions()),
		messageID,
	)
	if err != nil {
		return nil, grpcFailure(err)
	}
	result := store.CommandResult{Kind: "send_message", MessageID: messageID, Sent: !queued, Queued: queued}
	if err := api.server.store.SaveCommandResult(clientID, commandID, result); err != nil {
		return nil, grpcFailure(err)
	}
	return &dieterv1.SendMessageResponse{Sent: !queued, Queued: queued, MessageId: messageID}, nil
}

func (api *grpcAPI) AddComment(_ context.Context, request *dieterv1.AddCommentRequest) (*dieterv1.Comment, error) {
	card, err := api.server.store.ResolveCard(request.GetCardId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	value, err := api.server.store.AddComment(card.ID, request.GetMessage(), model.Author{Kind: "human", Name: request.GetName()})
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoComment(value), nil
}

func (api *grpcAPI) MoveCard(_ context.Context, request *dieterv1.MoveCardRequest) (*dieterv1.Card, error) {
	before, err := api.server.store.ResolveCard(request.GetCardId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	value, err := api.server.store.MoveCard(before.ID, request.GetLane(), request.Position)
	if err != nil {
		return nil, grpcFailure(err)
	}
	if value.Lane == model.LaneRunning && value.InitialPromptSentAt == "" {
		updates, startErr := api.server.app.StartCard(value.ID, "", value.Provider, value.Model, "")
		if startErr != nil {
			_, _ = api.server.store.MoveCard(value.ID, before.Lane, nil)
			return nil, grpcFailure(startErr)
		}
		go drainUpdates(updates)
		// StartCard durably updates the runtime and initial prompt marker before
		// returning. Resolve again so legacy MoveCard callers never receive the
		// stale "running lane / idle runtime" projection.
		value, _ = api.server.store.ResolveCard(value.ID)
	}
	if value.Lane == model.LaneDone {
		if _, err := api.server.store.ArchiveDoneCards(time.Now()); err != nil {
			return nil, grpcFailure(err)
		}
		value, _ = api.server.store.ResolveCard(value.ID)
	}
	return protoCard(value), nil
}

func (api *grpcAPI) StartCard(_ context.Context, request *dieterv1.StartCardRequest) (*dieterv1.StartCardResponse, error) {
	clientID, commandID := strings.TrimSpace(request.GetClientId()), strings.TrimSpace(request.GetCommandId())
	if clientID == "" || commandID == "" {
		return nil, status.Error(codes.InvalidArgument, "client_id and command_id are required")
	}
	api.commandMu.Lock()
	defer api.commandMu.Unlock()
	if result, ok, err := api.server.store.LoadCommandResult(clientID, commandID); err != nil {
		return nil, grpcFailure(err)
	} else if ok {
		if result.Kind != "start_card" || result.CardID != request.GetCardId() {
			return nil, status.Error(codes.AlreadyExists, "command_id was already used for another operation")
		}
		card, resolveErr := api.server.store.ResolveCard(result.CardID)
		if resolveErr != nil {
			return nil, grpcFailure(resolveErr)
		}
		return &dieterv1.StartCardResponse{Card: protoCard(card), Accepted: true, Replayed: true, CommandId: commandID}, nil
	}

	card, err := api.server.store.ResolveCard(request.GetCardId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	if card.Scope != model.ConversationScopeBoard {
		return nil, status.Error(codes.FailedPrecondition, "only board cards can be started")
	}
	if card.InitialPromptSentAt != "" {
		if card.Runtime == "starting" || card.Runtime == "running" || card.Runtime == "working" || card.Runtime == "streaming" {
			if saveErr := api.server.store.SaveCommandResult(clientID, commandID, store.CommandResult{Kind: "start_card", CardID: card.ID}); saveErr != nil {
				return nil, grpcFailure(saveErr)
			}
			return &dieterv1.StartCardResponse{Card: protoCard(card), Accepted: true, AlreadyRunning: true, CommandId: commandID}, nil
		}
		return nil, status.Error(codes.FailedPrecondition, "card has already been started; send a message to resume its conversation")
	}

	updates, err := api.server.app.StartCard(card.ID, "", card.Provider, card.Model, card.Effort)
	if err != nil {
		return nil, grpcFailure(err)
	}
	go drainUpdates(updates)
	fresh, err := api.server.store.ResolveCard(card.ID)
	if err != nil {
		return nil, grpcFailure(err)
	}
	if err := api.server.store.SaveCommandResult(clientID, commandID, store.CommandResult{Kind: "start_card", CardID: fresh.ID}); err != nil {
		return nil, grpcFailure(err)
	}
	return &dieterv1.StartCardResponse{Card: protoCard(fresh), Accepted: true, CommandId: commandID}, nil
}

func (api *grpcAPI) SetCardLabels(_ context.Context, request *dieterv1.SetCardLabelsRequest) (*dieterv1.Card, error) {
	value, err := api.server.store.SetCardLabels(request.GetCardId(), request.GetLabelIds())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoCard(value), nil
}

func (api *grpcAPI) CancelCard(_ context.Context, request *dieterv1.GetCardRequest) (*emptypb.Empty, error) {
	if err := api.server.app.CancelCard(request.GetCardId()); err != nil {
		return nil, grpcFailure(err)
	}
	return &emptypb.Empty{}, nil
}

func (api *grpcAPI) RenameCard(_ context.Context, request *dieterv1.RenameCardRequest) (*dieterv1.Card, error) {
	value, err := api.server.store.RenameCard(request.GetCardId(), request.GetTitle())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoCard(value), nil
}

func (api *grpcAPI) UpdateCard(_ context.Context, request *dieterv1.UpdateCardRequest) (*dieterv1.Card, error) {
	value, err := api.server.store.UpdateCard(request.GetCardId(), request.GetTitle(), request.GetInitialPrompt())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoCard(value), nil
}

func (api *grpcAPI) ArchiveCard(_ context.Context, request *dieterv1.ArchiveCardRequest) (*dieterv1.Card, error) {
	value, err := api.server.store.ArchiveCard(request.GetCardId(), request.GetArchived())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoCard(value), nil
}

func (api *grpcAPI) PinChat(_ context.Context, request *dieterv1.PinChatRequest) (*dieterv1.Card, error) {
	value, err := api.server.store.PinChat(request.GetCardId(), request.GetPinned())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoCard(value), nil
}

func (api *grpcAPI) ListFiles(_ context.Context, request *dieterv1.ListFilesRequest) (*dieterv1.FileList, error) {
	api.server.filesMu.RLock()
	defer api.server.filesMu.RUnlock()
	project, err := api.server.store.ResolveProject(request.GetProjectId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	relative, err := cleanProjectPath(request.GetPath(), true)
	if err != nil {
		return nil, grpcFailure(err)
	}
	root, target, err := existingProjectPath(project, relative)
	if err != nil {
		return nil, grpcFailure(err)
	}
	info, err := os.Stat(target)
	if err != nil {
		return nil, grpcFailure(projectPathIOError(relative, err))
	}
	if !info.IsDir() {
		return nil, status.Errorf(codes.InvalidArgument, "%q is not a directory", relative)
	}
	items, err := os.ReadDir(target)
	if err != nil {
		return nil, grpcFailure(projectPathIOError(relative, err))
	}
	entries := make([]projectFileEntry, 0, len(items))
	for _, item := range items {
		if item.Name() == ".git" {
			continue
		}
		logicalPath := path.Join(relative, item.Name())
		entry, entryErr := projectEntry(root, logicalPath, filepath.Join(target, item.Name()), item)
		if entryErr != nil || entry.Hidden && !request.GetShowHidden() {
			continue
		}
		entries = append(entries, entry)
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Kind != entries[j].Kind {
			return entries[i].Kind == "directory"
		}
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})
	result := &dieterv1.FileList{Path: relative}
	for _, entry := range entries {
		result.Entries = append(result.Entries, &dieterv1.FileEntry{
			Name: entry.Name, Path: entry.Path, Kind: entry.Kind, Size: entry.Size,
			ModifiedAt: entry.ModifiedAt, Hidden: entry.Hidden, Symlink: entry.Symlink,
		})
	}
	return result, nil
}

func (api *grpcAPI) ReadFile(_ context.Context, request *dieterv1.ReadFileRequest) (*dieterv1.FileDocument, error) {
	api.server.filesMu.RLock()
	defer api.server.filesMu.RUnlock()
	project, err := api.server.store.ResolveProject(request.GetProjectId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	relative, err := cleanProjectPath(request.GetPath(), false)
	if err != nil {
		return nil, grpcFailure(err)
	}
	_, target, err := existingProjectPath(project, relative)
	if err != nil {
		return nil, grpcFailure(err)
	}
	info, err := os.Stat(target)
	if err != nil {
		return nil, grpcFailure(projectPathIOError(relative, err))
	}
	if !info.Mode().IsRegular() {
		return nil, status.Errorf(codes.InvalidArgument, "%q is not a regular file", relative)
	}
	content, err := readLimitedProjectFile(target)
	if err != nil {
		return nil, grpcFailure(err)
	}
	binary := !utf8.Valid(content) || containsNUL(content)
	result := &dieterv1.FileDocument{
		Path: relative, Name: path.Base(relative), Binary: binary, Size: info.Size(),
		ModifiedAt: info.ModTime().UTC().Format(projectTimeFormat),
		Revision:   projectFileRevision(content), MimeType: mime.TypeByExtension(strings.ToLower(filepath.Ext(target))),
	}
	if binary {
		result.Data = content
	} else {
		result.Content = string(content)
	}
	return result, nil
}

func (api *grpcAPI) ListSchedules(_ context.Context, request *dieterv1.ListSchedulesRequest) (*dieterv1.SchedulesResponse, error) {
	values, err := api.server.schedules.List(request.GetProjectId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	result := &dieterv1.SchedulesResponse{}
	for _, value := range values {
		result.Schedules = append(result.Schedules, protoSchedule(value))
	}
	return result, nil
}

func (api *grpcAPI) PreviewSchedule(_ context.Context, request *dieterv1.PreviewScheduleRequest) (*dieterv1.SchedulePreview, error) {
	values, err := api.server.schedules.Preview(request.GetCron(), request.GetTimezone(), int(request.GetCount()))
	if err != nil {
		return nil, grpcFailure(err)
	}
	return &dieterv1.SchedulePreview{Times: values}, nil
}

func scheduleInput(request *dieterv1.SaveScheduleRequest) (store.ScheduleInput, error) {
	value := request.GetSchedule()
	if value == nil {
		return store.ScheduleInput{}, errors.New("schedule is required")
	}
	return store.ScheduleInput{
		Project: value.GetProjectId(), Board: value.GetBoardId(), Name: value.GetName(),
		Description: value.GetDescription(), Cron: value.GetCron(), Timezone: value.GetTimezone(),
		Enabled: value.GetEnabled(), Action: value.GetAction(), TitleTemplate: value.GetTitleTemplate(),
		PromptTemplate: value.GetPromptTemplate(), Provider: value.GetProvider(), Model: value.GetModel(),
		Effort: value.GetEffort(), ProviderOptions: cloneProtoStringMap(value.GetProviderOptions()), LabelIDs: append([]string(nil), value.GetLabelIds()...),
		OpenCardPolicy: value.GetOpenCardPolicy(), MisfirePolicy: value.GetMisfirePolicy(),
		BusyPolicy: value.GetBusyPolicy(),
	}, nil
}

func (api *grpcAPI) CreateSchedule(_ context.Context, request *dieterv1.SaveScheduleRequest) (*dieterv1.Schedule, error) {
	input, err := scheduleInput(request)
	if err != nil {
		return nil, grpcFailure(err)
	}
	value, err := api.server.schedules.Create(input)
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoSchedule(value), nil
}

func (api *grpcAPI) UpdateSchedule(_ context.Context, request *dieterv1.SaveScheduleRequest) (*dieterv1.Schedule, error) {
	input, err := scheduleInput(request)
	if err != nil {
		return nil, grpcFailure(err)
	}
	if strings.TrimSpace(request.GetScheduleId()) == "" {
		return nil, status.Error(codes.InvalidArgument, "schedule ID is required")
	}
	value, err := api.server.schedules.Update(request.GetScheduleId(), input)
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoSchedule(value), nil
}

func (api *grpcAPI) DeleteSchedule(_ context.Context, request *dieterv1.ScheduleRef) (*emptypb.Empty, error) {
	if err := api.server.store.DeleteSchedule(request.GetScheduleId()); err != nil {
		return nil, grpcFailure(err)
	}
	return &emptypb.Empty{}, nil
}

func (api *grpcAPI) RunSchedule(_ context.Context, request *dieterv1.ScheduleRef) (*dieterv1.ScheduleRun, error) {
	value, err := api.server.schedules.RunNow(request.GetScheduleId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoScheduleRun(value), nil
}

func (api *grpcAPI) SetScheduleEnabled(_ context.Context, request *dieterv1.SetScheduleEnabledRequest) (*dieterv1.Schedule, error) {
	value, err := api.server.schedules.SetEnabled(request.GetScheduleId(), request.GetEnabled())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoSchedule(value), nil
}

func (api *grpcAPI) ListScheduleRuns(_ context.Context, request *dieterv1.ListScheduleRunsRequest) (*dieterv1.ScheduleRunsResponse, error) {
	values, err := api.server.store.ListScheduleRuns(request.GetScheduleId(), int(request.GetLimit()))
	if err != nil {
		return nil, grpcFailure(err)
	}
	result := &dieterv1.ScheduleRunsResponse{}
	for _, value := range values {
		result.Runs = append(result.Runs, protoScheduleRun(value))
	}
	return result, nil
}

func grpcFailure(err error) error {
	if err == nil {
		return nil
	}
	if _, ok := status.FromError(err); ok {
		if status.Code(err) != codes.Unknown {
			return err
		}
	}
	if errors.Is(err, context.Canceled) {
		return status.Error(codes.Canceled, err.Error())
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return status.Error(codes.DeadlineExceeded, err.Error())
	}
	if errors.Is(err, store.ErrNotFound) || errors.Is(err, fs.ErrNotExist) {
		return status.Error(codes.NotFound, err.Error())
	}
	if errors.Is(err, store.ErrCapacity) {
		return status.Error(codes.ResourceExhausted, err.Error())
	}
	if errors.Is(err, store.ErrCardActive) {
		return status.Error(codes.FailedPrecondition, err.Error())
	}
	if errors.Is(err, terminal.ErrNotFound) {
		return status.Error(codes.NotFound, err.Error())
	}
	if errors.Is(err, terminal.ErrNotRunning) {
		return status.Error(codes.FailedPrecondition, err.Error())
	}
	if errors.Is(err, terminal.ErrLimitReached) {
		return status.Error(codes.ResourceExhausted, err.Error())
	}
	var fileErr *projectFileError
	if errors.As(err, &fileErr) {
		code := codes.InvalidArgument
		switch fileErr.status {
		case http.StatusForbidden:
			code = codes.PermissionDenied
		case http.StatusNotFound:
			code = codes.NotFound
		case http.StatusConflict:
			code = codes.Aborted
		case http.StatusRequestEntityTooLarge:
			code = codes.ResourceExhausted
		}
		return status.Error(code, fileErr.message)
	}
	return status.Error(codes.InvalidArgument, err.Error())
}
