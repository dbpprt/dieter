package server

import (
	"context"
	"sort"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/protocol"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func protoSyncCursor(cursor store.SyncCursor) *dieterv1.SyncCursor {
	return &dieterv1.SyncCursor{Epoch: cursor.Epoch, Sequence: cursor.Sequence, ProjectionVersion: store.SyncProjectionVersion}
}

func protoSyncEvent(event store.SyncEvent) *dieterv1.SyncEvent {
	return &dieterv1.SyncEvent{Sequence: event.Sequence, Kind: event.Kind, CreatedAt: event.CreatedAt, CommandId: event.CommandID}
}

// activeSyncRuntime mirrors the client-side definition of "the model is doing
// something right now" so running work is always part of the bounded stream.
func activeSyncRuntime(runtime string) bool {
	switch runtime {
	case "running", "starting", "working", "streaming":
		return true
	}
	return false
}

// syncConversationCards bounds the conversation payload of a sync stream:
// every card with an active runtime plus the most recently active
// conversations up to recent.
func syncConversationCards(cards []*dieterv1.Card, recent int) []*dieterv1.Card {
	selected := append([]*dieterv1.Card(nil), cards...)
	sort.SliceStable(selected, func(left, right int) bool {
		return syncActivityKey(selected[left]) > syncActivityKey(selected[right])
	})
	bounded := selected[:0]
	remaining := recent
	for _, card := range selected {
		if activeSyncRuntime(card.GetRuntime()) {
			bounded = append(bounded, card)
			continue
		}
		if remaining > 0 {
			bounded = append(bounded, card)
			remaining--
		}
	}
	return bounded
}

// syncActivityKey sorts RFC 3339 UTC timestamps lexicographically.
func syncActivityKey(card *dieterv1.Card) string {
	if key := card.GetLastActivityAt(); key != "" {
		return key
	}
	return card.GetUpdatedAt()
}

type syncProjection struct {
	snapshot              *dieterv1.GlobalSnapshot
	state                 model.State
	conversationRevisions map[string]string
	cursor                store.SyncCursor
	hydrated              bool
}

func (api *grpcAPI) globalSnapshot(limit, recent int, previous *syncProjection) (*syncProjection, error) {
	return api.globalSnapshotContext(context.Background(), limit, recent, previous, false)
}

func (api *grpcAPI) globalSnapshotReusingMetadata(limit, recent int, previous *syncProjection, reuseMetadata bool) (*syncProjection, error) {
	return api.globalSnapshotContext(context.Background(), limit, recent, previous, reuseMetadata)
}

func (api *grpcAPI) globalSnapshotContext(ctx context.Context, limit, recent int, previous *syncProjection, reuseMetadata bool) (*syncProjection, error) {
	began := time.Now()
	defer func() {
		if elapsed := time.Since(began); elapsed > 250*time.Millisecond {
			api.server.log.Debug("sync projection build", "durationMs", elapsed.Milliseconds(), "conversationLimit", limit, "recentLimit", recent)
		}
	}()
	if limit > 100 {
		limit = 100
	}

	var state model.State
	var cursor store.SyncCursor
	var snapshot *dieterv1.GlobalSnapshot
	if reuseMetadata && previous != nil {
		state = previous.state
		cursor = previous.cursor
		snapshot = proto.Clone(previous.snapshot).(*dieterv1.GlobalSnapshot)
		snapshot.Conversations = nil
	} else {
		var err error
		state, cursor, err = api.server.store.GlobalStateContext(ctx)
		if err != nil {
			return nil, err
		}
		settings, err := api.server.store.Settings()
		if err != nil {
			return nil, err
		}

		snapshot = &dieterv1.GlobalSnapshot{State: protoState(state), Settings: protoSettings(settings)}
	}

	protoState := snapshot.GetState()
	projection := &syncProjection{snapshot: snapshot, state: state, cursor: cursor, hydrated: limit > 0, conversationRevisions: make(map[string]string)}
	if limit <= 0 {
		return projection, nil
	}

	conversationCards := append(append([]*dieterv1.Card(nil), protoState.Cards...), protoState.Chats...)
	if recent > 0 {
		conversationCards = syncConversationCards(conversationCards, min(recent, 16))
	}
	if len(conversationCards) > 32 {
		conversationCards = conversationCards[:32]
	}
	snapshot.Conversations = make([]*dieterv1.ConversationSnapshot, len(conversationCards))
	projectsByID := make(map[string]model.Project, len(state.Projects))
	for _, project := range state.Projects {
		projectsByID[project.ID] = project
	}
	boardsByID := make(map[string]model.Board, len(state.Boards))
	for _, board := range state.Boards {
		boardsByID[board.ID] = board
	}
	cardsByID := make(map[string]model.Card, len(state.Cards)+len(state.Chats))
	for _, card := range state.Cards {
		cardsByID[card.ID] = card
	}
	for _, card := range state.Chats {
		cardsByID[card.ID] = card
	}
	previousConversations := make(map[string]*dieterv1.ConversationSnapshot)
	previousRevisions := make(map[string]string)
	if previous != nil {
		previousRevisions = previous.conversationRevisions
		for _, conversation := range previous.snapshot.GetConversations() {
			previousConversations[conversation.GetDetail().GetCard().GetId()] = conversation
		}
	}

	// Optional hydration is bounded and independently fallible. A damaged or
	// oversized transcript cannot prevent the workspace directory from arriving.
	snapshot.Conversations = nil
	used := proto.Size(snapshot)
	for _, card := range conversationCards {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		cardID := card.GetId()
		revision, err := api.server.store.ConversationRevisionByID(cardID)
		if err != nil {
			continue
		}
		modelCard := cardsByID[cardID]
		detail := model.CardDetail{Card: modelCard, Project: projectsByID[modelCard.ProjectID], Board: boardsByID[modelCard.BoardID]}
		// Comment bodies belong to the selected conversation RPC, not workspace sync.
		var tail *dieterv1.ConversationSnapshot
		if cached := previousConversations[cardID]; cached != nil && previousRevisions[cardID] == revision && proto.Equal(cached.GetDetail(), protoCardDetail(detail)) {
			tail = cached
		} else {
			conversation, err := api.conversationAtRevision(cardID, revision)
			if err != nil {
				api.server.log.Warn("sync conversation hydration failed", "cardID", cardID, "error", err)
				continue
			}
			tail = api.boundedConversationSnapshot(detail, conversation, limit, nil, maxSyncConversationBytes, false)
		}
		size := proto.Size(tail)
		if size > maxSyncConversationBytes || used+size > maxSyncFrameBytes-65536 {
			continue
		}
		used += size
		snapshot.Conversations = append(snapshot.Conversations, tail)
		projection.conversationRevisions[cardID] = revision
	}

	return projection, nil
}

func globalDelta(previous, current *dieterv1.GlobalSnapshot) *dieterv1.GlobalDelta {
	delta := &dieterv1.GlobalDelta{}
	if !proto.Equal(previous.GetState().GetArchives(), current.GetState().GetArchives()) {
		delta.Archives = current.GetState().GetArchives()
	}
	previousProjects := make(map[string]*dieterv1.Project, len(previous.GetState().GetProjects()))
	for _, value := range previous.GetState().GetProjects() {
		previousProjects[value.GetId()] = value
	}
	currentProjects := make(map[string]struct{}, len(current.GetState().GetProjects()))
	for _, value := range current.GetState().GetProjects() {
		currentProjects[value.GetId()] = struct{}{}
		if before := previousProjects[value.GetId()]; before == nil || !proto.Equal(before, value) {
			delta.Projects = append(delta.Projects, value)
		}
	}
	for id := range previousProjects {
		if _, ok := currentProjects[id]; !ok {
			delta.RemovedProjectIds = append(delta.RemovedProjectIds, id)
		}
	}

	previousBoards := make(map[string]*dieterv1.Board, len(previous.GetState().GetBoards()))
	for _, value := range previous.GetState().GetBoards() {
		previousBoards[value.GetId()] = value
	}
	currentBoards := make(map[string]struct{}, len(current.GetState().GetBoards()))
	for _, value := range current.GetState().GetBoards() {
		currentBoards[value.GetId()] = struct{}{}
		if before := previousBoards[value.GetId()]; before == nil || !proto.Equal(before, value) {
			delta.Boards = append(delta.Boards, value)
		}
	}
	for id := range previousBoards {
		if _, ok := currentBoards[id]; !ok {
			delta.RemovedBoardIds = append(delta.RemovedBoardIds, id)
		}
	}

	previousCards := make(map[string]*dieterv1.Card, len(previous.GetState().GetCards()))
	for _, value := range previous.GetState().GetCards() {
		previousCards[value.GetId()] = value
	}
	currentCards := make(map[string]struct{}, len(current.GetState().GetCards()))
	for _, value := range current.GetState().GetCards() {
		currentCards[value.GetId()] = struct{}{}
		if before := previousCards[value.GetId()]; before == nil || !proto.Equal(before, value) {
			delta.Cards = append(delta.Cards, value)
		}
	}
	for id := range previousCards {
		if _, ok := currentCards[id]; !ok {
			delta.RemovedCardIds = append(delta.RemovedCardIds, id)
		}
	}

	previousChats := make(map[string]*dieterv1.Card, len(previous.GetState().GetChats()))
	for _, value := range previous.GetState().GetChats() {
		previousChats[value.GetId()] = value
	}
	currentChats := make(map[string]struct{}, len(current.GetState().GetChats()))
	for _, value := range current.GetState().GetChats() {
		currentChats[value.GetId()] = struct{}{}
		if before := previousChats[value.GetId()]; before == nil || !proto.Equal(before, value) {
			delta.Chats = append(delta.Chats, value)
		}
	}
	for id := range previousChats {
		if _, ok := currentChats[id]; !ok {
			delta.RemovedChatIds = append(delta.RemovedChatIds, id)
		}
	}
	if !proto.Equal(previous.GetSettings(), current.GetSettings()) {
		delta.Settings = current.GetSettings()
	}

	previousConversations := make(map[string]*dieterv1.ConversationSnapshot, len(previous.GetConversations()))
	for _, value := range previous.GetConversations() {
		previousConversations[value.GetDetail().GetCard().GetId()] = value
	}
	currentConversations := make(map[string]struct{}, len(current.GetConversations()))
	for _, value := range current.GetConversations() {
		id := value.GetDetail().GetCard().GetId()
		currentConversations[id] = struct{}{}
		if before := previousConversations[id]; before == nil || !proto.Equal(before, value) {
			delta.Conversations = append(delta.Conversations, value)
		}
	}
	for id := range previousConversations {
		if _, ok := currentConversations[id]; !ok {
			delta.RemovedConversationIds = append(delta.RemovedConversationIds, id)
		}
	}
	return delta
}

func globalDeltaEmpty(delta *dieterv1.GlobalDelta) bool {
	return delta == nil || proto.Equal(delta, &dieterv1.GlobalDelta{})
}

// watchSync has one sender and one bounded projection worker. Slow projection
// work cannot suppress liveness, and canceled senders cancel their worker.
func (api *grpcAPI) watchSync(parent context.Context, request *dieterv1.SyncRequest, send func(*dieterv1.SyncFrame) error) error {
	if request.GetProtocolVersion() != protocol.Number {
		return status.Error(codes.FailedPrecondition, "unsupported Dieter sync contract")
	}
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	heartbeat := time.Duration(request.GetHeartbeatMs()) * time.Millisecond
	if heartbeat <= 0 {
		heartbeat = 15 * time.Second
	}
	heartbeat = max(time.Second, heartbeat)
	type delivery struct {
		frame *dieterv1.SyncFrame
		sent  chan struct{}
	}
	frames := make(chan delivery)
	done := make(chan error, 1)
	go func() {
		done <- api.buildSyncFrames(ctx, request, func(frame *dieterv1.SyncFrame) error {
			ack := make(chan struct{})
			select {
			case frames <- delivery{frame, ack}:
				select {
				case <-ack:
					return nil
				case <-ctx.Done():
					return ctx.Err()
				}
			case <-ctx.Done():
				return ctx.Err()
			}
		})
	}()
	ticks := time.NewTicker(heartbeat)
	defer ticks.Stop()
	var applied *dieterv1.SyncCursor
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-done:
			return err
		case delivery := <-frames:
			frame := delivery.frame
			if err := sendBoundedSyncFrame(frame, send); err != nil {
				return err
			}
			applied = frame.Cursor
			close(delivery.sent)
		case <-ticks.C:
			observed, _, err := api.server.store.SyncEvents(^uint64(0), 1)
			if err != nil {
				return err
			}
			frame := &dieterv1.SyncFrame{Cursor: applied, ObservedCursor: protoSyncCursor(observed), Heartbeat: true, TransportOnly: true}
			frame.ProjectionPending = applied == nil || applied.GetEpoch() != observed.Epoch || applied.GetSequence() < observed.Sequence
			if err := send(frame); err != nil {
				return err
			}
		}
	}
}

func (api *grpcAPI) buildSyncFrames(ctx context.Context, request *dieterv1.SyncRequest, send func(*dieterv1.SyncFrame) error) error {
	limit, recent := int(request.GetConversationLimit()), int(request.GetRecentConversationLimit())
	cursor, _, err := api.server.store.SyncEvents(^uint64(0), 1)
	if err != nil {
		return err
	}
	projection := api.server.resumedSyncProjection(request, cursor)
	reset := projection == nil
	publish := func(next *syncProjection, events []store.SyncEvent, full bool) error {
		frame := &dieterv1.SyncFrame{Cursor: protoSyncCursor(next.cursor)}
		frame.Cursor.ProjectionId = api.server.retainSyncProjection(next, limit, recent)
		if full {
			frame.Snapshot = next.snapshot
			frame.Reset_ = reset
		} else if delta := globalDelta(projection.snapshot, next.snapshot); !globalDeltaEmpty(delta) {
			frame.Delta = delta
		}
		for _, event := range events {
			frame.Events = append(frame.Events, protoSyncEvent(event))
		}
		if len(events) > 0 {
			frame.Event = protoSyncEvent(events[len(events)-1])
		}
		if err := send(frame); err != nil {
			return err
		}
		projection = next
		reset = false
		return nil
	}
	if projection == nil {
		initial, err := api.globalSnapshotContext(ctx, 0, recent, nil, false)
		if err != nil {
			return err
		}
		if err := publish(initial, nil, true); err != nil {
			return err
		}
	} else {
		next := projection
		if cursor != projection.cursor {
			next, err = api.globalSnapshotContext(ctx, limit, recent, projection, false)
			if err != nil {
				return err
			}
		}
		if err := publish(next, nil, false); err != nil {
			return err
		}
	}
	if limit > 0 && !projection.hydrated {
		hydrated, err := api.globalSnapshotContext(ctx, limit, recent, projection, false)
		if err != nil {
			return err
		}
		if err := publish(hydrated, nil, false); err != nil {
			return err
		}
	}
	poll := time.NewTicker(200 * time.Millisecond)
	defer poll.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-poll.C:
		}
		current, events, err := api.server.store.SyncEvents(projection.cursor.Sequence, 256)
		if err != nil {
			return err
		}
		full := current.Epoch != projection.cursor.Epoch || current.Sequence < projection.cursor.Sequence
		if !full && current.Sequence == projection.cursor.Sequence && !api.server.store.SyncMutationPending() {
			continue
		}
		// Always capture committed metadata. The Store reuses it for text-only
		// commits; an incomplete diagnostic journal batch never decides correctness.
		next, err := api.globalSnapshotContext(ctx, limit, recent, projection, false)
		if err != nil {
			return err
		}
		// The projection build crosses the central writer boundary and can
		// therefore observe commits newer than the highwater sampled above.
		// Refresh the diagnostic journal after that build and retain only events
		// covered by the cursor we are about to publish. Otherwise a concurrent
		// commit can produce a cursor-only frame that permanently skips its event.
		_, events, err = api.server.store.SyncEvents(projection.cursor.Sequence, 256)
		if err != nil {
			return err
		}
		covered := events[:0]
		for _, event := range events {
			if event.Sequence <= next.cursor.Sequence {
				covered = append(covered, event)
			}
		}
		events = covered
		full = full || next.cursor.Epoch != projection.cursor.Epoch || next.cursor.Sequence < projection.cursor.Sequence
		reset = full
		if err := publish(next, events, full); err != nil {
			return err
		}
	}
}

const maxSyncFrameBytes = 8 << 20
const maxSyncConversationBytes = 512 << 10

func (api *grpcAPI) WatchSync(request *dieterv1.SyncRequest, stream dieterv1.DieterService_WatchSyncServer) error {
	return api.watchSync(stream.Context(), request, stream.Send)
}
