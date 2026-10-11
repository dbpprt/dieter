package api

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/engine"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/proto"
)

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

func conversationInput(request *dieterv1.CreateConversationRequest) (engine.CardInput, error) {
	workspaceMode, ok := model.CanonicalWorkspaceMode(request.GetWorkspaceMode())
	if strings.TrimSpace(request.GetWorkspaceMode()) == "" || !ok {
		return engine.CardInput{}, fault.New(fault.Invalid, "workspace mode must be selected for each conversation")
	}
	attachments, err := modelUserAttachmentParts(request.GetAttachments())
	if err != nil {
		return engine.CardInput{}, err
	}
	return engine.CardInput{
		CheckoutID: request.GetCheckoutId(), Project: request.GetProjectId(), Board: request.GetBoardId(), Lane: request.GetLane(),
		Title: request.GetTitle(), Prompt: request.GetPrompt(), Provider: request.GetProvider(),
		Model: request.GetModel(), Effort: request.GetEffort(), ProviderOptions: cloneProtoStringMap(request.GetProviderOptions()),
		LabelIDs: append([]string(nil), request.GetLabelIds()...), DeferStart: request.GetDeferStart(), AutoGenerateTitle: request.GetAutoGenerateTitle(), Attachments: attachments,
		WorkspaceMode: workspaceMode, WorkspaceBranch: request.GetWorkspaceBranch(),
		WorkspaceBaseBranch: request.GetWorkspaceBaseBranch(), WorkspaceBaseRemote: request.GetWorkspaceBaseRemote(),
		RemotePublishMode: request.GetRemotePublishMode(), VaultAccess: request.GetVaultAccess(),
	}, nil
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
		PresentedContent: current.GetConversation().GetPresentedContent(),
		ProviderStatus:   current.GetConversation().GetProviderStatus(),
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

// SendMessage is an idempotent outbox operation. Admission contention means
// the same command should be retried after teardown, not marked permanently
// failed by clients.
func sendMessageFailure(err error) error {
	if errors.Is(err, store.ErrCardActive) {
		return fault.Wrap(fault.Conflict, err)
	}
	return err
}

func scheduleInput(request *dieterv1.SaveScheduleRequest) (store.ScheduleInput, error) {
	value := request.GetSchedule()
	if value == nil {
		return store.ScheduleInput{}, fault.New(fault.Invalid, "schedule is required")
	}
	workspaceMode, ok := model.CanonicalWorkspaceMode(value.GetWorkspaceMode())
	if strings.TrimSpace(value.GetWorkspaceMode()) == "" || !ok {
		return store.ScheduleInput{}, fault.New(fault.Invalid, "workspace mode must be selected for each scheduled card")
	}
	return store.ScheduleInput{CheckoutID: value.GetCheckoutId(),
		Project: value.GetProjectId(), Board: value.GetBoardId(), Name: value.GetName(),
		Description: value.GetDescription(), Cron: value.GetCron(), Timezone: value.GetTimezone(),
		Enabled: value.GetEnabled(), Action: value.GetAction(), TitleTemplate: value.GetTitleTemplate(),
		PromptTemplate: value.GetPromptTemplate(), Provider: value.GetProvider(), Model: value.GetModel(),
		Effort: value.GetEffort(), ProviderOptions: cloneProtoStringMap(value.GetProviderOptions()), LabelIDs: append([]string(nil), value.GetLabelIds()...),
		OpenCardPolicy: value.GetOpenCardPolicy(), MisfirePolicy: value.GetMisfirePolicy(),
		WorkspaceMode: workspaceMode, VaultAccess: value.GetVaultAccess(),
	}, nil
}

func (s *Server) idempotentConversation(ctx context.Context, request *dieterv1.CreateConversationRequest, scope string) (*dieterv1.Card, error) {
	clientID, commandID := strings.TrimSpace(request.GetClientId()), strings.TrimSpace(request.GetCommandId())
	if clientID == "" && commandID == "" {
		input, err := conversationInput(request)
		if err != nil {
			return nil, err
		}
		value, err := func() (model.Card, error) {
			if scope == model.ConversationScopeChat {
				return s.app.CreateChat(ctx, input)
			}
			return s.app.CreateCard(ctx, input)
		}()
		if err != nil {
			return nil, err
		}
		return protoCard(value), nil
	}
	s.commandMu.Lock()
	defer s.commandMu.Unlock()
	kind := "create_" + scope
	if result, ok, err := s.store.LoadCommandResult(clientID, commandID); err != nil {
		return nil, err
	} else if ok {
		if result.Kind != kind {
			return nil, fault.New(fault.AlreadyExists, "command_id was already used for another operation")
		}
		card, resolveErr := s.store.ResolveCard(result.CardID)
		if resolveErr != nil {
			return nil, resolveErr
		}
		return protoCard(card), nil
	}
	cardID, err := store.DeterministicCommandID("c_", clientID, commandID)
	if err != nil {
		return nil, err
	}
	if existing, resolveErr := s.store.ResolveCard(cardID); resolveErr == nil {
		if existing.Scope != scope {
			return nil, fault.New(fault.AlreadyExists, "command_id resolved to another conversation scope")
		}
		existing, resolveErr = s.completeConversationCreation(existing, request)
		if resolveErr != nil {
			return nil, resolveErr
		}
		if saveErr := s.store.SaveCommandResult(clientID, commandID, store.CommandResult{Kind: kind, CardID: cardID}); saveErr != nil {
			return nil, saveErr
		}
		return protoCard(existing), nil
	} else if !errors.Is(resolveErr, store.ErrNotFound) {
		return nil, resolveErr
	}
	input, err := conversationInput(request)
	if err != nil {
		return nil, err
	}
	input.ID = cardID
	var value model.Card
	if scope == model.ConversationScopeChat {
		value, err = s.app.CreateChat(ctx, input)
	} else {
		value, err = s.app.CreateCard(ctx, input)
	}
	if err != nil {
		return nil, err
	}
	if err := s.store.SaveCommandResult(clientID, commandID, store.CommandResult{Kind: kind, CardID: value.ID}); err != nil {
		return nil, err
	}
	return protoCard(value), nil
}

// Creation persists the draft before admitting its first turn. A resource or
// workspace failure can therefore leave the deterministic ID present without
// completing the command. Retry admission only when durable state proves no
// turn was admitted; never turn an ambiguous retry into another agent message.
func (s *Server) completeConversationCreation(card model.Card, request *dieterv1.CreateConversationRequest) (model.Card, error) {
	shouldStart := !request.GetDeferStart() &&
		(card.Scope == model.ConversationScopeChat || strings.EqualFold(request.GetLane(), model.LaneRunning))
	if !shouldStart || card.InitialPromptSentAt != "" {
		return card, nil
	}
	conversation, err := s.store.Conversation(card.ID)
	if err != nil {
		return card, err
	}
	if len(conversation.Messages) != 0 || conversation.ActiveTurn != nil || len(conversation.Session) != 0 || len(conversation.Queue) != 0 {
		return card, fault.New(fault.FailedPrecondition, "conversation has turn state; inspect it before resuming")
	}
	// A failed draft-attachment write can also leave the card present. Keep
	// the original request's files; StartCard merges any persisted copies.
	attachments, err := modelUserAttachmentParts(request.GetAttachments())
	if err != nil {
		return card, err
	}
	parts := append([]model.UIMessagePart{{Type: "text", Text: card.InitialPrompt}}, attachments...)
	updates, err := s.app.StartCardWithMessageParts(card.ID, parts, card.Provider, card.Model, card.Effort, card.ProviderOptions, "")
	if err != nil {
		return card, err
	}
	go drainUpdates(updates)
	return s.store.ResolveCard(card.ID)
}

func (s *Server) conversation(cardID string) (model.Conversation, error) {
	revision, err := s.store.ConversationRevisionByID(cardID)
	if err != nil {
		return model.Conversation{}, err
	}
	return s.conversationAtRevision(cardID, revision)
}

func (s *Server) conversationAtRevision(cardID, _ string) (model.Conversation, error) {
	// The Store owns the single byte-bounded, revision-validated cache. Keeping a
	// second full-transcript cache here multiplies memory across client routes.
	return s.store.ConversationByID(cardID)
}

func (s *Server) conversationSnapshot(cardID string, limit int, before *int32) (*dieterv1.ConversationSnapshot, error) {
	if before != nil && *before < 0 {
		return nil, fault.New(fault.Invalid, "before must be a non-negative integer")
	}
	detail, err := s.store.CardDetail(cardID)
	if err != nil {
		return nil, err
	}
	window, err := s.store.ConversationWindowByID(cardID, limit, before)
	if err != nil {
		return nil, err
	}
	snapshot := s.windowedConversationSnapshot(detail, window, 12<<20, before == nil)
	if proto.Size(snapshot) > 12<<20 {
		return nil, fault.New(fault.ResourceExhausted, "one conversation message or its details exceed the 12 MiB response budget")
	}
	return snapshot, nil
}

func (s *Server) conversationSnapshotFrom(detail model.CardDetail, conversation model.Conversation, limit int, before *int32) *dieterv1.ConversationSnapshot {
	return s.boundedConversationSnapshot(detail, conversation, limit, before, 12<<20, true)
}

func (s *Server) boundedConversationSnapshot(detail model.CardDetail, conversation model.Conversation, limit int, before *int32, budget int, remember bool) *dieterv1.ConversationSnapshot {
	if limit < 1 {
		limit = 30
	}
	limit = min(limit, 100)
	end := len(conversation.Messages)
	if before != nil {
		end = min(int(*before), end)
	}
	start := max(0, end-limit)
	total := len(conversation.Messages)
	conversation.Messages = append([]model.UIMessage(nil), conversation.Messages[start:end]...)
	return s.windowedConversationSnapshot(detail, store.ConversationWindow{
		Conversation: conversation, Start: start, End: end, Total: total,
	}, budget, before == nil && remember)
}

func (s *Server) windowedConversationSnapshot(detail model.CardDetail, window store.ConversationWindow, budget int, remember bool) *dieterv1.ConversationSnapshot {
	conversation := window.Conversation
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
		Detail: protoCardDetail(detail), Conversation: protoConversation(conversation, s.previews),
		Page: &dieterv1.ConversationPage{
			Start: int32(window.Start), End: int32(window.End), Total: int32(window.Total), HasMore: window.Start > 0,
		},
	}
	for proto.Size(snapshot) > budget && len(snapshot.Conversation.Messages) > 1 {
		removedID := snapshot.Conversation.Messages[0].GetId()
		snapshot.Conversation.Messages = snapshot.Conversation.Messages[1:]
		snapshot.Conversation.Subagents = slices.DeleteFunc(snapshot.Conversation.Subagents, func(item *dieterv1.Subagent) bool { return item.GetMessageId() == removedID })
		snapshot.Conversation.TaskPlans = slices.DeleteFunc(snapshot.Conversation.TaskPlans, func(item *dieterv1.TaskPlan) bool { return item.GetMessageId() == removedID })
		snapshot.Page.Start++
		snapshot.Page.HasMore = true
	}
	if remember {
		s.rememberConversationSnapshot(detail.Card.ID, snapshot)
	}
	return snapshot
}

func (s *Server) rememberConversationSnapshot(cardID string, snapshot *dieterv1.ConversationSnapshot) {
	seq := snapshot.GetConversation().GetLastSeq()
	s.snapshotMu.Lock()
	defer s.snapshotMu.Unlock()
	if s.snapshotCache == nil {
		s.snapshotCache = make(map[string]snapshotHistory)
	}
	s.snapshotTick++
	history := s.snapshotCache[cardID]
	history.accessed = s.snapshotTick
	if len(history.values) > 0 && history.values[len(history.values)-1].seq == seq {
		history.values[len(history.values)-1].snapshot = snapshot
	} else {
		history.values = append(history.values, sequencedSnapshot{seq: seq, snapshot: snapshot})
		if len(history.values) > maxSnapshotsPerConversation {
			history.values = append([]sequencedSnapshot(nil), history.values[len(history.values)-maxSnapshotsPerConversation:]...)
		}
	}
	s.snapshotCache[cardID] = history
	// Bound retained snapshot memory as well as entry counts. A slow reader
	// cannot pin twelve conversations times eight twelve-megabyte tails.
	for {
		bytes := 0
		for _, item := range s.snapshotCache {
			for _, value := range item.values {
				bytes += proto.Size(value.snapshot)
			}
		}
		if len(s.snapshotCache) <= maxCachedConversations && bytes <= 32<<20 {
			return
		}
		oldestID, oldestTick := "", s.snapshotTick
		for id, item := range s.snapshotCache {
			if id != cardID && item.accessed <= oldestTick {
				oldestID, oldestTick = id, item.accessed
			}
		}
		if oldestID != "" {
			delete(s.snapshotCache, oldestID)
			continue
		}
		item := s.snapshotCache[cardID]
		if len(item.values) <= 1 {
			delete(s.snapshotCache, cardID)
			return
		}
		item.values = item.values[1:]
		s.snapshotCache[cardID] = item
	}
}

func (s *Server) rememberedConversationSnapshot(cardID string, seq int64) *dieterv1.ConversationSnapshot {
	s.snapshotMu.Lock()
	defer s.snapshotMu.Unlock()
	history, ok := s.snapshotCache[cardID]
	if !ok {
		return nil
	}
	s.snapshotTick++
	history.accessed = s.snapshotTick
	s.snapshotCache[cardID] = history
	for index := len(history.values) - 1; index >= 0; index-- {
		if history.values[index].seq == seq {
			return history.values[index].snapshot
		}
	}
	return nil
}

func (s *Server) watchConversation(ctx context.Context, request *dieterv1.WatchConversationRequest, send func(*dieterv1.ConversationUpdate) error) error {
	wake := newChangeWait(s.store)
	if request.GetIntervalMs() > 0 {
		wake.minimumInterval = max(100*time.Millisecond, min(5*time.Second, time.Duration(request.GetIntervalMs())*time.Millisecond))
	}
	defer wake.close()
	var previousSnapshot *dieterv1.ConversationSnapshot
	var revision conversationWatchRevision
	var polls, builds, frames uint64
	started := time.Now()
	defer func() {
		s.log.Debug("conversation watch", "durationMs", time.Since(started).Milliseconds(), "polls", polls, "snapshotBuilds", builds, "frames", frames)
	}()
	resumeSeq := request.GetAfterSeq()
	sendChanged := func() error {
		polls++
		nextRevision, pending, err := s.conversationWatchRevision(request.GetCardId())
		if err != nil {
			return err
		}
		if pending {
			// Filesystem notifications can arrive while the writer is still
			// publishing its commit. Cross that boundary before deciding which
			// selected data changed; this also recovers interrupted publications.
			if err := s.store.WaitForWriter(ctx); err != nil {
				return err
			}
			nextRevision, pending, err = s.conversationWatchRevision(request.GetCardId())
			if err != nil {
				return err
			}
		}
		if previousSnapshot != nil && nextRevision == revision && !pending {
			return nil
		}
		if previousSnapshot != nil && nextRevision.transcript == revision.transcript && !pending {
			// The metadata cursor is shared by the workspace. A title or
			// status change on another card must not clone and re-encode this
			// conversation's tool-heavy history. Still read all selected-card
			// detail so project, board, workspace and read-state changes propagate.
			detail, err := s.store.CardDetail(request.GetCardId())
			if err != nil {
				return err
			}
			if proto.Equal(protoCardDetail(detail), previousSnapshot.GetDetail()) {
				revision = nextRevision
				return nil
			}
		}
		builds++
		snapshot, err := s.conversationSnapshot(request.GetCardId(), int(request.GetLimit()), nil)
		if err != nil {
			return err
		}
		// Capture the revision before reading. A concurrent commit then forces
		// another read, rather than pairing older data with a newer checkpoint.
		revision = nextRevision
		if previousSnapshot == nil && resumeSeq > 0 && resumeSeq == snapshot.GetConversation().GetLastSeq() {
			// A resumed stream must acknowledge freshness even while the
			// transcript is idle. Otherwise reconnecting clients cannot tell a
			// healthy quiet stream from a stalled refresh. Include metadata:
			// read receipts can change without advancing the transcript sequence.
			update := conversationDelta(snapshot, snapshot)
			update.Detail = snapshot.GetDetail()
			if err := send(update); err != nil {
				return err
			}
			frames++
			previousSnapshot = snapshot
			return nil
		}
		if proto.Equal(snapshot, previousSnapshot) {
			return nil
		}
		update := conversationDelta(previousSnapshot, snapshot)
		if err := send(update); err != nil {
			return err
		}
		frames++
		previousSnapshot = snapshot
		return nil
	}
	if err := sendChanged(); err != nil {
		return err
	}
	for {
		if err := wake.wait(ctx); err != nil {
			return err
		}
		if err := sendChanged(); err != nil {
			return err
		}
	}
}
