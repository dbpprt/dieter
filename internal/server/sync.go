package server

import (
	"context"
	"sort"
	"time"

	naucliov1 "github.com/dbpprt/nauclio/internal/gen/nauclio/v1"
	"github.com/dbpprt/nauclio/internal/store"
	"google.golang.org/protobuf/proto"
)

func protoSyncCursor(cursor store.SyncCursor) *naucliov1.SyncCursor {
	return &naucliov1.SyncCursor{Epoch: cursor.Epoch, Sequence: cursor.Sequence, ProjectionVersion: store.SyncProjectionVersion}
}

func protoSyncEvent(event store.SyncEvent) *naucliov1.SyncEvent {
	return &naucliov1.SyncEvent{Sequence: event.Sequence, Kind: event.Kind, CreatedAt: event.CreatedAt, CommandId: event.CommandID}
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
func syncConversationCards(cards []*naucliov1.Card, recent int) []*naucliov1.Card {
	selected := append([]*naucliov1.Card(nil), cards...)
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
func syncActivityKey(card *naucliov1.Card) string {
	if key := card.GetLastActivityAt(); key != "" {
		return key
	}
	return card.GetUpdatedAt()
}

func (api *grpcAPI) globalSnapshot(limit, recent int) (*naucliov1.GlobalSnapshot, error) {
	if limit > 100 {
		limit = 100
	}
	projects, err := api.server.store.ListProjects()
	if err != nil {
		return nil, err
	}
	state := &naucliov1.State{StorePath: api.server.store.Root}
	for _, project := range projects {
		state.Projects = append(state.Projects, protoProject(project))
		projectState, stateErr := api.server.store.State(project.ID, store.CardFilter{})
		if stateErr != nil {
			return nil, stateErr
		}
		for _, board := range projectState.Boards {
			state.Boards = append(state.Boards, protoBoard(board))
		}
		for _, card := range projectState.Cards {
			state.Cards = append(state.Cards, protoCard(card))
		}
		for _, chat := range projectState.Chats {
			state.Chats = append(state.Chats, protoCard(chat))
		}
	}
	snapshot := &naucliov1.GlobalSnapshot{State: state}
	if limit > 0 {
		conversationCards := append(append([]*naucliov1.Card(nil), state.Cards...), state.Chats...)
		if recent > 0 {
			conversationCards = syncConversationCards(conversationCards, recent)
		}
		for _, card := range conversationCards {
			conversation, conversationErr := api.conversationSnapshot(card.GetId(), limit, nil)
			if conversationErr != nil {
				return nil, conversationErr
			}
			snapshot.Conversations = append(snapshot.Conversations, conversation)
		}
	}
	schedules, err := api.server.store.ListSchedules("")
	if err != nil {
		return nil, err
	}
	for _, schedule := range schedules {
		snapshot.Schedules = append(snapshot.Schedules, protoSchedule(schedule))
		runs, runsErr := api.server.store.ListScheduleRuns(schedule.ID, 20)
		if runsErr != nil {
			return nil, runsErr
		}
		for _, run := range runs {
			snapshot.ScheduleRuns = append(snapshot.ScheduleRuns, protoScheduleRun(run))
		}
	}
	settings, err := api.server.store.Settings()
	if err != nil {
		return nil, err
	}
	snapshot.Settings = protoSettings(settings)
	return snapshot, nil
}

func globalDelta(previous, current *naucliov1.GlobalSnapshot) *naucliov1.GlobalDelta {
	delta := &naucliov1.GlobalDelta{}
	previousProjects := make(map[string]*naucliov1.Project, len(previous.GetState().GetProjects()))
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

	previousBoards := make(map[string]*naucliov1.Board, len(previous.GetState().GetBoards()))
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

	previousCards := make(map[string]*naucliov1.Card, len(previous.GetState().GetCards()))
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

	previousChats := make(map[string]*naucliov1.Card, len(previous.GetState().GetChats()))
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

	previousSchedules := make(map[string]*naucliov1.Schedule, len(previous.GetSchedules()))
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

	previousRuns := make(map[string]*naucliov1.ScheduleRun, len(previous.GetScheduleRuns()))
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

	previousConversations := make(map[string]*naucliov1.ConversationSnapshot, len(previous.GetConversations()))
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

func (api *grpcAPI) watchSync(ctx context.Context, request *naucliov1.SyncRequest, send func(*naucliov1.SyncFrame) error) error {
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
	var projection *naucliov1.GlobalSnapshot
	if deltaMode || reset || sequence == 0 {
		if waitErr := api.server.store.WaitForWriter(ctx); waitErr != nil {
			return waitErr
		}
		snapshot, snapshotErr := api.globalSnapshot(int(request.GetConversationLimit()), int(request.GetRecentConversationLimit()))
		if snapshotErr != nil {
			return snapshotErr
		}
		if err := send(&naucliov1.SyncFrame{Cursor: protoSyncCursor(cursor), Snapshot: snapshot, Reset_: reset}); err != nil {
			return err
		}
		sequence = cursor.Sequence
		projection = snapshot
	}
	if projection == nil {
		var projectionErr error
		projection, projectionErr = api.globalSnapshot(int(request.GetConversationLimit()), int(request.GetRecentConversationLimit()))
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
			snapshot, snapshotErr := api.globalSnapshot(int(request.GetConversationLimit()), int(request.GetRecentConversationLimit()))
			if snapshotErr != nil {
				return snapshotErr
			}
			cursor, sequence = current, current.Sequence
			projection = snapshot
			return send(&naucliov1.SyncFrame{Cursor: protoSyncCursor(current), Snapshot: snapshot, Reset_: true})
		}
		if len(events) == 0 {
			return nil
		}
		if waitErr := api.server.store.WaitForWriter(ctx); waitErr != nil {
			return waitErr
		}
		snapshot, snapshotErr := api.globalSnapshot(int(request.GetConversationLimit()), int(request.GetRecentConversationLimit()))
		if snapshotErr != nil {
			return snapshotErr
		}
		last := events[len(events)-1]
		frame := &naucliov1.SyncFrame{
			Cursor: protoSyncCursor(store.SyncCursor{Epoch: current.Epoch, Sequence: last.Sequence}),
			Event:  protoSyncEvent(last),
		}
		if deltaMode {
			frame.Delta = globalDelta(projection, snapshot)
		} else {
			frame.Snapshot = snapshot
		}
		for _, event := range events {
			frame.Events = append(frame.Events, protoSyncEvent(event))
		}
		if err := send(frame); err != nil {
			return err
		}
		sequence = last.Sequence
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
			if err := send(&naucliov1.SyncFrame{Cursor: protoSyncCursor(current), Heartbeat: true}); err != nil {
				return err
			}
		}
	}
}

func (api *grpcAPI) WatchSync(request *naucliov1.SyncRequest, stream naucliov1.NauclioService_WatchSyncServer) error {
	return api.watchSync(stream.Context(), request, stream.Send)
}
