package server

import (
	"context"
	"time"

	naucliov1 "github.com/dbpprt/nauclio/internal/gen/nauclio/v1"
	"github.com/dbpprt/nauclio/internal/store"
)

func protoSyncCursor(cursor store.SyncCursor) *naucliov1.SyncCursor {
	return &naucliov1.SyncCursor{Epoch: cursor.Epoch, Sequence: cursor.Sequence, ProjectionVersion: store.SyncProjectionVersion}
}

func protoSyncEvent(event store.SyncEvent) *naucliov1.SyncEvent {
	return &naucliov1.SyncEvent{Sequence: event.Sequence, Kind: event.Kind, CreatedAt: event.CreatedAt, CommandId: event.CommandID}
}

func (api *grpcAPI) globalSnapshot(limit int) (*naucliov1.GlobalSnapshot, error) {
	if limit < 1 {
		limit = 40
	}
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
	for _, card := range append(append([]*naucliov1.Card(nil), state.Cards...), state.Chats...) {
		conversation, conversationErr := api.conversationSnapshot(card.GetId(), limit, nil)
		if conversationErr != nil {
			return nil, conversationErr
		}
		snapshot.Conversations = append(snapshot.Conversations, conversation)
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
	if reset || sequence == 0 {
		if waitErr := api.server.store.WaitForWriter(ctx); waitErr != nil {
			return waitErr
		}
		snapshot, snapshotErr := api.globalSnapshot(int(request.GetConversationLimit()))
		if snapshotErr != nil {
			return snapshotErr
		}
		if err := send(&naucliov1.SyncFrame{Cursor: protoSyncCursor(cursor), Snapshot: snapshot, Reset_: reset}); err != nil {
			return err
		}
		sequence = cursor.Sequence
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
			snapshot, snapshotErr := api.globalSnapshot(int(request.GetConversationLimit()))
			if snapshotErr != nil {
				return snapshotErr
			}
			cursor, sequence = current, current.Sequence
			return send(&naucliov1.SyncFrame{Cursor: protoSyncCursor(current), Snapshot: snapshot, Reset_: true})
		}
		if len(events) == 0 {
			return nil
		}
		if waitErr := api.server.store.WaitForWriter(ctx); waitErr != nil {
			return waitErr
		}
		snapshot, snapshotErr := api.globalSnapshot(int(request.GetConversationLimit()))
		if snapshotErr != nil {
			return snapshotErr
		}
		last := events[len(events)-1]
		frame := &naucliov1.SyncFrame{
			Cursor: protoSyncCursor(store.SyncCursor{Epoch: current.Epoch, Sequence: last.Sequence}),
			Event:  protoSyncEvent(last), Snapshot: snapshot,
		}
		for _, event := range events {
			frame.Events = append(frame.Events, protoSyncEvent(event))
		}
		if err := send(frame); err != nil {
			return err
		}
		sequence = last.Sequence
		cursor = current
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
