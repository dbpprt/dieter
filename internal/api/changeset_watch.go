package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/kanban"
)

const (
	maxChangesetStreams = 64
	// Activity (an agent starting or finishing, an operation) can change
	// without a file changing; it is checked this often.
	changesetActivityPoll = 1500 * time.Millisecond
	defaultChangesetBeat  = 15 * time.Second
)

// watchChangeset streams one directory's changeset: the full changeset first,
// then one whenever its status, activity or running operation changes, and
// heartbeats meanwhile. One reader per directory serves every stream on it.
func (s *Server) watchChangeset(ctx context.Context, request *dieterv1.WatchChangesetRequest, send func(*dieterv1.ChangesetFrame) error) error {
	if s.changesetStreams.Add(1) > maxChangesetStreams {
		s.changesetStreams.Add(-1)
		return fault.New(fault.ResourceExhausted, "too many changeset streams")
	}
	defer s.changesetStreams.Add(-1)
	heartbeat := defaultChangesetBeat
	if request.GetHeartbeatMs() > 0 {
		heartbeat = min(30*time.Second, max(time.Second, time.Duration(request.GetHeartbeatMs())*time.Millisecond))
	}
	ctx = kanban.WithCheckout(ctx, request.GetCheckoutId())
	target, err := s.changesets.Resolve(ctx, request.GetCardId(), request.GetProjectId())
	if err != nil {
		return err
	}
	watch := s.changesetHub.Watch(target, func() bool { return s.changesets.AgentActive(target) })
	defer watch.Release()
	beat := time.NewTicker(heartbeat)
	defer beat.Stop()
	activity := time.NewTicker(changesetActivityPoll)
	defer activity.Stop()
	sent := ""
	for {
		reading := watch.Current()
		if reading.Read && reading.Err != nil && sent == "" {
			return reading.Err
		}
		if reading.Read && reading.Err == nil {
			value := s.changesets.Build(ctx, target, reading.Status)
			if key := changesetKey(value); key != sent {
				frame := &dieterv1.ChangesetFrame{Changeset: protoChangeset(value)}
				if err := send(frame); err != nil {
					return err
				}
				sent = key
				beat.Reset(heartbeat)
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-reading.Changed:
		case <-activity.C:
		case <-beat.C:
			if err := send(&dieterv1.ChangesetFrame{Heartbeat: true}); err != nil {
				return err
			}
		}
	}
}

// changesetKey identifies what a client shows of a changeset, so an unchanged
// one is not resent.
func changesetKey(value model.Changeset) string {
	hash := sha256.New()
	_, _ = fmt.Fprintf(hash, "%s\x00%s\x00%s\x00%d\x00%d\x00%s\x00%t\x00%s\x00%s\x00%d",
		value.Revision, value.Branch, value.HeadSHA, value.Ahead, value.Behind, value.CurrentOperationID,
		value.Activity.AgentActive, strings.Join(value.Activity.AgentCardIDs, ","), value.IndexFingerprint, len(value.Commits))
	for _, commit := range value.Commits {
		_, _ = fmt.Fprintf(hash, "\x00%s", commit.SHA)
	}
	return hex.EncodeToString(hash.Sum(nil))
}
