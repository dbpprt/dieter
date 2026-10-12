package schedules

import (
	"encoding/json"
	"errors"
	"os"
	"sort"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/replica"
)

// FlushSharedOutbox completes pending replica effects and publishes queued
// schedule summaries under the writer lock. The scheduler's authoritative
// occurrence database never runs peer definitions. Its transactionally queued
// directory summaries are drained under the writer lock. Replaying an
// acknowledged summary is a causal no-op.
func (s *Store) FlushSharedOutbox() error {
	release, err := s.home.BeginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	if err = s.replica.RecoverEffects(); err != nil {
		return err
	}
	return s.FlushOutbox()
}

// FlushOutbox publishes the queued schedule summaries to the account's
// replica. The caller holds the writer lock: the root runs it before every
// change commits and in the recovery sweep.
func (s *Store) FlushOutbox() error {
	if _, err := os.Stat(s.home.ScheduleDatabasePath()); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	}
	identity, err := s.replica.PeerIdentity()
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	db, err := s.scheduleDatabase()
	if err != nil {
		return err
	}
	rows, err := db.Query("SELECT document,deleted FROM schedule_peer_outbox ORDER BY id LIMIT 100")
	if err != nil {
		return err
	}
	type pending struct {
		item    model.Schedule
		deleted bool
	}
	var values []pending
	for rows.Next() {
		var raw []byte
		var v pending
		if err = rows.Scan(&raw, &v.deleted); err != nil {
			break
		}
		if err = json.Unmarshal(raw, &v.item); err != nil {
			break
		}
		values = append(values, v)
	}
	rowErr := rows.Err()
	_ = rows.Close()
	if err != nil {
		return err
	}
	if rowErr != nil {
		return rowErr
	}
	if len(values) == 0 {
		return nil
	}
	data, err := s.replica.OpenPeerView(identity.Account)
	if err != nil {
		return err
	}
	data.State = replica.ClonePeerState(data.State)
	for _, v := range values {
		item := v.item
		if item.OwnerDaemonID != identity.DaemonID {
			continue
		}
		// Keep the immutable registration project after consolidation.
		if raw, ok := crdt.Selected(data.Record(crdt.Key("schedule", item.ID+".summary"))); ok {
			var previous model.Schedule
			if json.Unmarshal(raw, &previous) == nil {
				item.ProjectID = previous.ProjectID
			}
		}
		summary := replica.RawValue(map[string]any{"id": item.ID, "projectId": item.ProjectID, "boardId": item.BoardID, "ownerDaemonId": item.OwnerDaemonID, "checkoutId": item.CheckoutID, "name": item.Name, "cron": item.Cron, "timezone": item.Timezone, "enabled": item.Enabled, "nextRunAt": item.NextRunAt, "lastRunAt": item.LastRunAt, "deleted": v.deleted})
		if err = replica.ApplyFields(&data, identity, "schedule", item.ID, nil, map[string]json.RawMessage{"summary": summary}); err != nil {
			return err
		}
	}
	if err = s.replica.SavePeerData(identity.Account, data); err != nil {
		return err
	}
	for _, v := range values {
		if _, err = db.Exec("DELETE FROM schedule_peer_outbox WHERE id=?", v.item.ID); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) ListSharedPage(projectRef string, pageSize int, pageToken string) (Page, error) {
	local, err := s.List(projectRef)
	if err != nil {
		return Page{}, err
	}
	identity, data, err := s.replica.Snapshot()
	defer data.Close()
	if err != nil {
		return Page{}, err
	}
	projectID := ""
	if projectRef != "" {
		p, e := s.kanban.ResolveProject(projectRef)
		if e != nil {
			return Page{}, e
		}
		projectID = p.ID
	}
	byID := map[string]model.Schedule{}
	for _, item := range local {
		if item.OwnerDaemonID == identity.DaemonID {
			byID[item.ID] = item
		}
	}
	for _, id := range replica.EntityIDs(data, "schedule", "summary") {
		if _, ok := byID[id]; ok {
			continue
		}
		fields, _ := replica.EntityFields(data, "schedule", id)
		var summary struct {
			model.Schedule
			Deleted bool `json:"deleted"`
		}
		if err = json.Unmarshal(fields["summary"], &summary); err != nil {
			return Page{}, err
		}
		summary.ProjectID = kanban.CanonicalProjectID(data, summary.ProjectID)
		if summary.Deleted || summary.OwnerDaemonID == identity.DaemonID || projectID != "" && summary.ProjectID != projectID {
			continue
		}
		if _, err = s.kanban.ResolveProject(summary.ProjectID); err != nil {
			continue
		}
		byID[id] = summary.Schedule
	}
	items := make([]model.Schedule, 0, len(byID))
	for _, item := range byID {
		items = append(items, item)
	}
	sort.Slice(items, func(i, j int) bool {
		a, b := strings.ToLower(items[i].Name), strings.ToLower(items[j].Name)
		if a == b {
			return items[i].ID < items[j].ID
		}
		return a < b
	})
	cursor := schedulePageCursor{ProjectID: projectID}
	if pageToken != "" {
		if err = decodeScheduleCursor(pageToken, &cursor); err != nil || cursor.ProjectID != projectID {
			return Page{}, fault.New(fault.Invalid, "invalid schedule page token")
		}
	}
	result := Page{TotalCount: len(items)}
	pageSize = boundedSchedulePageSize(pageSize)
	for _, item := range items {
		if cursor.ID != "" && (strings.ToLower(item.Name) < strings.ToLower(cursor.Name) || strings.EqualFold(item.Name, cursor.Name) && item.ID <= cursor.ID) {
			continue
		}
		result.Items = append(result.Items, item)
		if len(result.Items) > pageSize {
			break
		}
	}
	if len(result.Items) > pageSize {
		result.Items = result.Items[:pageSize]
		last := result.Items[pageSize-1]
		result.NextPageToken, err = encodeScheduleCursor(schedulePageCursor{ProjectID: projectID, Name: last.Name, ID: last.ID})
	}
	if err == nil {
		err = data.Err()
	}
	return result, err
}

// Deleted definitions keep their signed directory summary, so occurrence history
// remains visible to its account without exposing another account's local rows.
func (s *Store) localScheduleIDs() ([]string, error) {
	identity, data, err := s.replica.Snapshot()
	defer data.Close()
	if err != nil {
		return nil, err
	}
	var ids []string
	for _, id := range replica.EntityIDs(data, "schedule", "summary") {
		raw, ok := crdt.Selected(data.Record(crdt.Key("schedule", id+".summary")))
		if !ok {
			continue
		}
		var item model.Schedule
		if json.Unmarshal(raw, &item) == nil && item.OwnerDaemonID == identity.DaemonID {
			ids = append(ids, id)
		}
	}
	return ids, data.Err()
}
func (s *Store) requireLocalScheduleHistory(id string) error {
	ids, err := s.localScheduleIDs()
	if err != nil {
		return err
	}
	for _, candidate := range ids {
		if id == candidate {
			return nil
		}
	}
	return home.ErrNotFound
}

// AdoptOwner moves this machine's schedules to the daemon that adopts
// the unenrolled replica. Adoption retries until it completes; this is idempotent.
func (s *Store) AdoptOwner(old, next replica.PeerIdentity) error {
	if _, err := os.Stat(s.home.ScheduleDatabasePath()); err == nil {
		db, err := s.scheduleDatabase()
		if err != nil {
			return err
		}
		schedules, err := s.listSchedules()
		if err != nil {
			return err
		}
		for _, item := range schedules {
			if item.OwnerDaemonID == old.DaemonID {
				item.OwnerDaemonID = next.DaemonID
				if err = upsertScheduleDocument(db, item); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

// OnBoard returns a schedule of this machine that still targets boardID,
// or "" when none does.
func (s *Store) OnBoard(boardID string) (string, error) {
	if _, err := os.Stat(s.home.ScheduleDatabasePath()); err == nil {
		schedules, err := s.listSchedules()
		if err != nil {
			return "", err
		}
		for _, schedule := range schedules {
			if schedule.BoardID == boardID {
				return schedule.ID, nil
			}
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	return "", nil
}
