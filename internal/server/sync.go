package server

import (
	"context"
	"sort"
	"sync"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
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
}

func (api *grpcAPI) globalSnapshot(limit, recent int, previous *syncProjection) (*syncProjection, error) {
	return api.globalSnapshotReusingMetadata(limit, recent, previous, false)
}

func (api *grpcAPI) globalSnapshotReusingMetadata(limit, recent int, previous *syncProjection, reuseMetadata bool) (*syncProjection, error) {
	if limit > 100 {
		limit = 100
	}

	var state model.State
	var snapshot *dieterv1.GlobalSnapshot
	if reuseMetadata && previous != nil {
		state = previous.state
		snapshot = proto.Clone(previous.snapshot).(*dieterv1.GlobalSnapshot)
		snapshot.Conversations = nil
	} else {
		// The independent roots are loaded concurrently. GlobalState itself
		// scans each workspace directory once, instead of once per project.
		var settings model.Settings
		errs := make([]error, 2)
		var roots sync.WaitGroup
		roots.Add(2)
		go func() { defer roots.Done(); state, errs[0] = api.server.store.GlobalState() }()
		go func() { defer roots.Done(); settings, errs[1] = api.server.store.Settings() }()
		roots.Wait()
		for _, err := range errs {
			if err != nil {
				return nil, err
			}
		}

		snapshot = &dieterv1.GlobalSnapshot{State: protoState(state), Settings: protoSettings(settings)}
	}

	protoState := snapshot.GetState()
	projection := &syncProjection{snapshot: snapshot, state: state, conversationRevisions: make(map[string]string)}
	if limit <= 0 {
		return projection, nil
	}

	conversationCards := append(append([]*dieterv1.Card(nil), protoState.Cards...), protoState.Chats...)
	if recent > 0 {
		conversationCards = syncConversationCards(conversationCards, recent)
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

	// Conversation tails are independent and can contain large tool payloads.
	// Build at most eight in parallel, and reuse unchanged serialized snapshots
	// by checking their constant-time durable revision first.
	var conversations sync.WaitGroup
	var resultMu sync.Mutex
	var firstErr error
	revisions := make([]string, len(conversationCards))
	workers := make(chan struct{}, 8)
	for index, card := range conversationCards {
		workers <- struct{}{}
		conversations.Add(1)
		go func(index int, card *dieterv1.Card) {
			defer conversations.Done()
			defer func() { <-workers }()
			cardID := card.GetId()
			revision, err := api.server.store.ConversationRevisionByID(cardID)
			if err != nil {
				resultMu.Lock()
				if firstErr == nil {
					firstErr = err
				}
				resultMu.Unlock()
				return
			}
			comments, err := api.server.store.ListComments(cardID, 0)
			if err != nil {
				resultMu.Lock()
				if firstErr == nil {
					firstErr = err
				}
				resultMu.Unlock()
				return
			}
			modelCard := cardsByID[cardID]
			detail := model.CardDetail{
				Card: modelCard, Project: projectsByID[modelCard.ProjectID],
				Board: boardsByID[modelCard.BoardID], Comments: comments,
			}
			protoDetail := protoCardDetail(detail)
			if cached := previousConversations[cardID]; cached != nil &&
				previousRevisions[cardID] == revision && proto.Equal(cached.GetDetail(), protoDetail) {
				snapshot.Conversations[index] = cached
				revisions[index] = revision
				return
			}
			conversation, err := api.conversationAtRevision(cardID, revision)
			if err != nil {
				resultMu.Lock()
				if firstErr == nil {
					firstErr = err
				}
				resultMu.Unlock()
				return
			}
			snapshot.Conversations[index] = api.conversationSnapshotFrom(detail, conversation, limit, nil)
			revisions[index] = revision
		}(index, card)
	}
	conversations.Wait()
	if firstErr != nil {
		return nil, firstErr
	}
	for index, card := range conversationCards {
		projection.conversationRevisions[card.GetId()] = revisions[index]
	}
	return projection, nil
}

func globalDelta(previous, current *dieterv1.GlobalSnapshot) *dieterv1.GlobalDelta {
	delta := &dieterv1.GlobalDelta{}
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

	previousSchedules := make(map[string]*dieterv1.Schedule, len(previous.GetSchedules()))
	for _, value := range previous.GetSchedules() {
		previousSchedules[value.GetId()] = value
	}
	currentSchedules := make(map[string]struct{}, len(current.GetSchedules()))
	for _, value := range current.GetSchedules() {
		currentSchedules[value.GetId()] = struct{}{}
		if before := previousSchedules[value.GetId()]; before == nil || !proto.Equal(before, value) {
			delta.Schedules = append(delta.Schedules, value)
		}
	}
	for id := range previousSchedules {
		if _, ok := currentSchedules[id]; !ok {
			delta.RemovedScheduleIds = append(delta.RemovedScheduleIds, id)
		}
	}

	previousRuns := make(map[string]*dieterv1.ScheduleRun, len(previous.GetScheduleRuns()))
	for _, value := range previous.GetScheduleRuns() {
		previousRuns[value.GetId()] = value
	}
	currentRuns := make(map[string]struct{}, len(current.GetScheduleRuns()))
	for _, value := range current.GetScheduleRuns() {
		currentRuns[value.GetId()] = struct{}{}
		if before := previousRuns[value.GetId()]; before == nil || !proto.Equal(before, value) {
			delta.ScheduleRuns = append(delta.ScheduleRuns, value)
		}
	}
	for id := range previousRuns {
		if _, ok := currentRuns[id]; !ok {
			delta.RemovedScheduleRunIds = append(delta.RemovedScheduleRunIds, id)
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

func (api *grpcAPI) watchSync(ctx context.Context, request *dieterv1.SyncRequest, send func(*dieterv1.SyncFrame) error) error {
	heartbeat := boundedInterval(request.GetHeartbeatMs(), 15*time.Second)
	if heartbeat < time.Second {
		heartbeat = time.Second
	}
	poll := time.NewTicker(200 * time.Millisecond)
	defer poll.Stop()
	heartbeats := time.NewTicker(heartbeat)
	defer heartbeats.Stop()

	cursor, _, err := api.server.store.SyncEvents(0, 1)
	if err != nil {
		return err
	}
	after := request.GetAfter()
	sequence := uint64(0)
	reset := after == nil || after.GetEpoch() == "" || after.GetEpoch() != cursor.Epoch || after.GetProjectionVersion() != store.SyncProjectionVersion || after.GetSequence() > cursor.Sequence
	if !reset {
		sequence = after.GetSequence()
	}
	// Delta framing applies to metadata-only clients and to bounded
	// conversation subscribers; only the legacy full-snapshot mode is exempt.
	deltaMode := request.GetConversationLimit() == 0 || request.GetRecentConversationLimit() > 0
	var projection *syncProjection
	if deltaMode || reset || sequence == 0 {
		if waitErr := api.server.store.WaitForWriter(ctx); waitErr != nil {
			return waitErr
		}
		snapshot, snapshotErr := api.globalSnapshot(int(request.GetConversationLimit()), int(request.GetRecentConversationLimit()), nil)
		if snapshotErr != nil {
			return snapshotErr
		}
		if err := send(&dieterv1.SyncFrame{Cursor: protoSyncCursor(cursor), Snapshot: snapshot.snapshot, Reset_: reset}); err != nil {
			return err
		}
		sequence = cursor.Sequence
		projection = snapshot
	}
	if projection == nil {
		var projectionErr error
		projection, projectionErr = api.globalSnapshot(int(request.GetConversationLimit()), int(request.GetRecentConversationLimit()), nil)
		if projectionErr != nil {
			return projectionErr
		}
	}

	sendEvents := func() error {
		current, events, readErr := api.server.store.SyncEvents(sequence, 256)
		if readErr != nil {
			return readErr
		}
		if current.Epoch != cursor.Epoch || current.Sequence < sequence {
			if waitErr := api.server.store.WaitForWriter(ctx); waitErr != nil {
				return waitErr
			}
			snapshot, snapshotErr := api.globalSnapshot(int(request.GetConversationLimit()), int(request.GetRecentConversationLimit()), nil)
			if snapshotErr != nil {
				return snapshotErr
			}
			cursor, sequence = current, current.Sequence
			projection = snapshot
			return send(&dieterv1.SyncFrame{Cursor: protoSyncCursor(current), Snapshot: snapshot.snapshot, Reset_: true})
		}
		if len(events) == 0 {
			return nil
		}
		if waitErr := api.server.store.WaitForWriter(ctx); waitErr != nil {
			return waitErr
		}
		reuseMetadata := projection != nil
		for _, event := range events {
			if event.Kind != "conversation_changed" {
				reuseMetadata = false
				break
			}
		}
		snapshot, snapshotErr := api.globalSnapshotReusingMetadata(
			int(request.GetConversationLimit()),
			int(request.GetRecentConversationLimit()),
			projection,
			reuseMetadata,
		)
		if snapshotErr != nil {
			return snapshotErr
		}
		last := events[len(events)-1]
		frame := &dieterv1.SyncFrame{
			Cursor: protoSyncCursor(current),
			Event:  protoSyncEvent(last),
		}
		if deltaMode {
			if delta := globalDelta(projection.snapshot, snapshot.snapshot); !globalDeltaEmpty(delta) {
				frame.Delta = delta
			}
		} else {
			frame.Snapshot = snapshot.snapshot
		}
		for _, event := range events {
			frame.Events = append(frame.Events, protoSyncEvent(event))
		}
		if err := send(frame); err != nil {
			return err
		}
		// The projection was materialized after every mutation through current.
		// Advance directly to that high-water mark even when the durable journal
		// batch contains more than 256 rows, so a burst becomes one delta build.
		sequence = current.Sequence
		cursor = current
		projection = snapshot
		return nil
	}

	if err := sendEvents(); err != nil {
		return err
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-poll.C:
			if err := sendEvents(); err != nil {
				return err
			}
		case <-heartbeats.C:
			current, _, readErr := api.server.store.SyncEvents(sequence, 1)
			if readErr != nil {
				return readErr
			}
			if err := send(&dieterv1.SyncFrame{Cursor: protoSyncCursor(current), Heartbeat: true}); err != nil {
				return err
			}
		}
	}
}

func (api *grpcAPI) WatchSync(request *dieterv1.SyncRequest, stream dieterv1.DieterService_WatchSyncServer) error {
	return api.watchSync(stream.Context(), request, stream.Send)
}
