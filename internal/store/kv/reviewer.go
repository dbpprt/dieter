package kv

import (
	"encoding/json"
	"errors"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/home"
)

// ErrReviewerSettingsChanged reports a compare-and-set write whose expected
// revision is no longer current.
var ErrReviewerSettingsChanged = fault.New(fault.Conflict, "the reviewer setting changed since it was read; reload and retry")

// ReviewerSettingsEntry is the account's reviewer setting with its record
// revision. Configured is false while nobody has saved one; Record then holds
// the defaults.
type ReviewerSettingsEntry struct {
	Record     schema.ReviewerSettingsRecord
	Revision   string
	Configured bool
}

// ReviewerSettings reads the reviewer setting. A record that fails validation
// (from a newer daemon) reads as the defaults, unconfigured.
func (s *Store) ReviewerSettings() (ReviewerSettingsEntry, error) {
	entry := ReviewerSettingsEntry{Record: schema.DefaultReviewerSettings()}
	current, err := s.currentRecord(schema.KVKindPrefix+schema.ReviewerSettingsNamespace, schema.ReviewerSettingsKey)
	if err != nil {
		return entry, err
	}
	entry.Revision = current.Revision()
	if len(current.Versions) == 0 {
		return entry, nil
	}
	selected := schema.SelectedKV(current)
	if selected.Deleted {
		return entry, nil
	}
	record, err := schema.DecodeReviewerSettings(schema.ReviewerSettingsKey, selected.Value)
	if err != nil {
		return entry, nil
	}
	entry.Record, entry.Configured = record, true
	return entry, nil
}

// PutReviewerSettings saves the reviewer setting. A non-empty expected
// revision makes the write compare-and-set (ErrReviewerSettingsChanged when
// it lost); an empty one overwrites.
func (s *Store) PutReviewerSettings(record schema.ReviewerSettingsRecord, expectedRevision string) (ReviewerSettingsEntry, error) {
	record.UpdatedAt = home.Timestamp()
	if err := schema.ValidateReviewerSettings(record); err != nil {
		return ReviewerSettingsEntry{}, err
	}
	raw, err := json.Marshal(record)
	if err != nil {
		return ReviewerSettingsEntry{}, err
	}
	identity, err := s.providerIdentity()
	if err != nil {
		return ReviewerSettingsEntry{}, err
	}
	kind := schema.KVKindPrefix + schema.ReviewerSettingsNamespace
	for attempt := 0; attempt < 4; attempt++ {
		current, err := s.currentRecord(kind, schema.ReviewerSettingsKey)
		if err != nil {
			return ReviewerSettingsEntry{}, err
		}
		if expectedRevision != "" && current.Revision() != expectedRevision {
			return ReviewerSettingsEntry{}, ErrReviewerSettingsChanged
		}
		_, err = s.Mutate(identity, Mutation{
			Namespace: schema.ReviewerSettingsNamespace, Key: schema.ReviewerSettingsKey, Revision: current.Revision(),
			OperationID: home.NewID("op_"), DaemonID: identity.DaemonID, Value: raw,
		})
		if errors.Is(err, crdt.ErrConflict) {
			if expectedRevision != "" {
				return ReviewerSettingsEntry{}, ErrReviewerSettingsChanged
			}
			continue
		}
		if err != nil {
			return ReviewerSettingsEntry{}, err
		}
		return s.ReviewerSettings()
	}
	return ReviewerSettingsEntry{}, crdt.ErrConflict
}
