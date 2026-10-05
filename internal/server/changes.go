package server

import (
	"context"
	"errors"
	"os"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/peerstore"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

const (
	maxChangeStreams = 64
	maxLocalChanges  = 128
	// Half the transport's 16 MiB message limit. A record page stays within
	// 2 MiB; local changes fill the rest.
	maxChangesFrameBytes = 8 << 20
	defaultChangesBeat   = 15 * time.Second
	changesCoalescing    = 25 * time.Millisecond
	changesRecoveryPoll  = 2 * time.Second
)

func (api *grpcAPI) WatchChanges(request *dieterv1.ChangesRequest, stream dieterv1.DieterService_WatchChangesServer) error {
	return api.watchChanges(stream.Context(), request, stream.Send)
}

// watchChanges streams this machine's view: its replica of the shared peer
// records in the peer store's own order, then what only it knows from the
// local index. Each half resumes from the client's cursor and resets on its
// own when that cursor no longer applies. Frames are bounded; data frames are
// sent only when something changed, heartbeats prove liveness meanwhile.
func (api *grpcAPI) watchChanges(ctx context.Context, request *dieterv1.ChangesRequest, send func(*dieterv1.ChangesFrame) error) error {
	if api.server.changeStreams.Add(1) > maxChangeStreams {
		api.server.changeStreams.Add(-1)
		return status.Error(codes.ResourceExhausted, "too many change streams")
	}
	defer api.server.changeStreams.Add(-1)
	heartbeat := defaultChangesBeat
	if request.GetHeartbeatMs() > 0 {
		heartbeat = max(time.Second, time.Duration(request.GetHeartbeatMs())*time.Millisecond)
	}
	changes, unsubscribe := api.server.store.SubscribeChanges()
	defer unsubscribe()
	if err := api.server.local.current(ctx); err != nil {
		return grpcFailure(err)
	}

	cursor := &dieterv1.ChangesCursor{}
	if after := request.GetAfter(); after != nil {
		cursor = proto.Clone(after).(*dieterv1.ChangesCursor)
	}
	stream := changeStream{api: api, cursor: cursor, resetRecords: cursor.GetRecordsEpoch() == ""}
	beat := time.NewTicker(heartbeat)
	defer beat.Stop()
	recovery := time.NewTicker(changesRecoveryPoll)
	defer recovery.Stop()
	first := true
	for {
		// Taken before draining: an index update during the drain wakes the
		// next wait instead of being missed.
		local := api.server.local.changed()
		for {
			frame, more, err := stream.next()
			if err != nil {
				return grpcFailure(err)
			}
			if first || stream.hasContent(frame) {
				if err := send(frame); err != nil {
					return err
				}
				first = false
				beat.Reset(heartbeat)
			}
			if !more {
				break
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-changes:
			// Coalesce a burst of writes into one frame.
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(changesCoalescing):
			}
			select {
			case <-changes:
			default:
			}
		case <-local:
		case <-recovery.C:
		case <-beat.C:
			if err := send(&dieterv1.ChangesFrame{DaemonId: stream.daemonID, Account: stream.account, Cursor: proto.Clone(stream.cursor).(*dieterv1.ChangesCursor), CaughtUp: true, Heartbeat: true}); err != nil {
				return err
			}
			continue
		}
		// What only this machine knows changes with the store; the recovery
		// tick covers diagnostics and missed notifications.
		if err := api.server.local.current(ctx); err != nil && ctx.Err() == nil {
			api.server.log.Warn("local change index refresh failed", "error", err)
		}
	}
}

type changeStream struct {
	api               *grpcAPI
	cursor            *dieterv1.ChangesCursor
	daemonID, account string
	resetRecords      bool
}

// next builds one bounded frame: a page of peer records and a batch of local
// changes within the frame's byte budget. A local change that does not fit
// beside the records waits for a frame of its own. more is true while either
// half still has data.
func (s *changeStream) next() (*dieterv1.ChangesFrame, bool, error) {
	frame := &dieterv1.ChangesFrame{}
	recordsMore, err := s.records(frame)
	if err != nil {
		return nil, false, err
	}
	budget := maxChangesFrameBytes - proto.Size(frame)
	local, epoch, sequence, reset, localMore := s.api.server.local.since(s.cursor.GetLocalEpoch(), s.cursor.GetLocalSequence(), maxLocalChanges, budget, len(frame.Records) == 0)
	frame.ResetLocal = reset
	for _, change := range local {
		addLocalChange(frame, change)
	}
	s.cursor.LocalEpoch, s.cursor.LocalSequence = epoch, sequence
	frame.DaemonId, frame.Account = s.daemonID, s.account
	frame.Cursor = proto.Clone(s.cursor).(*dieterv1.ChangesCursor)
	frame.CaughtUp = !recordsMore && !localMore
	return frame, recordsMore || localMore, nil
}

// records adds the next page of this machine's peer records. The account can
// appear (first shared write) or change (enrollment); its log then restarts.
func (s *changeStream) records(frame *dieterv1.ChangesFrame) (bool, error) {
	identity, err := s.api.server.store.PeerIdentity()
	if errors.Is(err, os.ErrNotExist) {
		frame.ResetRecords = s.resetRecords
		s.resetRecords = false
		return false, nil
	}
	if err != nil {
		return false, err
	}
	s.daemonID, s.account = identity.DaemonID, identity.Account
	page, err := s.api.server.store.PeerChanges(identity.Account, s.cursor.GetRecordsEpoch(), s.cursor.GetRecordsSequence())
	if errors.Is(err, peerstore.ErrConflict) {
		s.cursor.RecordsEpoch, s.cursor.RecordsSequence, s.resetRecords = "", 0, true
		page, err = s.api.server.store.PeerChanges(identity.Account, "", 0)
	}
	if err != nil {
		return false, err
	}
	frame.ResetRecords = s.resetRecords
	s.resetRecords = false
	for _, record := range page.Records {
		frame.Records = append(frame.Records, changeRecord(record))
	}
	s.cursor.RecordsEpoch, s.cursor.RecordsSequence = page.Epoch, page.After
	return page.More, nil
}

func (s *changeStream) hasContent(frame *dieterv1.ChangesFrame) bool {
	return frame.ResetRecords || frame.ResetLocal || len(frame.Records) > 0 || len(frame.OwnedCards) > 0 ||
		len(frame.RemovedOwnedCardIds) > 0 || len(frame.OwnedCheckouts) > 0 || len(frame.RemovedOwnedCheckoutIds) > 0 ||
		len(frame.Activities) > 0 || len(frame.RemovedActivityIds) > 0 || frame.PeerSync != nil
}

func addLocalChange(frame *dieterv1.ChangesFrame, change localChange) {
	kind, id := splitLocalKey(change.key)
	switch {
	case change.key == peerSyncKey:
		status := change.entry.peerSync
		if change.entry.removed || status == nil {
			status = &dieterv1.PeerSyncStatus{}
		}
		frame.PeerSync = status
	case kind == "card" && change.entry.removed:
		frame.RemovedOwnedCardIds = append(frame.RemovedOwnedCardIds, id)
	case kind == "card":
		frame.OwnedCards = append(frame.OwnedCards, change.entry.card)
	case kind == "checkout" && change.entry.removed:
		frame.RemovedOwnedCheckoutIds = append(frame.RemovedOwnedCheckoutIds, id)
	case kind == "checkout":
		frame.OwnedCheckouts = append(frame.OwnedCheckouts, change.entry.checkout)
	case kind == "activity" && change.entry.removed:
		frame.RemovedActivityIds = append(frame.RemovedActivityIds, id)
	case kind == "activity":
		frame.Activities = append(frame.Activities, change.entry.activity)
	}
}

func splitLocalKey(key string) (string, string) {
	for index := range len(key) {
		if key[index] == '/' {
			return key[:index], key[index+1:]
		}
	}
	return key, ""
}

// changeRecord carries every causal sibling with its presentation rank.
// Ownership proofs stay with the daemons, which verify them on merge.
func changeRecord(record peerstore.Record) *dieterv1.PeerRecord {
	result := &dieterv1.PeerRecord{Kind: record.Kind, Id: record.ID, Revision: record.Revision(), ValueRevision: record.ValueRevision()}
	for _, version := range record.Versions {
		result.Versions = append(result.Versions, &dieterv1.PeerVersion{
			Clock: version.Clock, ValueJson: version.Value, Deleted: version.Deleted, Rank: peerstore.PresentationRank(version),
		})
	}
	return result
}
