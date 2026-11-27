package kv

import (
	"encoding/json"
	"errors"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/home"
)

// ErrMemorySettingsChanged reports a compare-and-set write of the memory
// setting whose expected revision is no longer current.
var ErrMemorySettingsChanged = fault.New(fault.Conflict, "the memory setting changed since it was read; reload and retry")

// MemorySettingsEntry is the account's memory setting with its revision.
// Configured is false while nobody has saved one; Record then holds the
// defaults.
type MemorySettingsEntry struct {
	Record     schema.MemorySettingsRecord
	Revision   string
	Configured bool
}

// MemorySettings reads the memory setting. A record that fails validation
// (from a newer daemon) reads as the defaults, unconfigured.
func (s *Store) MemorySettings() (MemorySettingsEntry, error) {
	entry := MemorySettingsEntry{Record: schema.DefaultMemorySettings()}
	current, err := s.currentRecord(schema.KVKindPrefix+schema.MemorySettingsNamespace, schema.MemorySettingsKey)
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
	record, err := schema.DecodeMemorySettings(schema.MemorySettingsKey, selected.Value)
	if err != nil {
		return entry, nil
	}
	entry.Record, entry.Configured = record, true
	return entry, nil
}

// PutMemorySettings saves the memory setting; a non-empty expected revision
// makes it compare-and-set.
func (s *Store) PutMemorySettings(record schema.MemorySettingsRecord, expectedRevision string) (MemorySettingsEntry, error) {
	record.UpdatedAt = home.Timestamp()
	if err := schema.ValidateMemorySettings(record); err != nil {
		return MemorySettingsEntry{}, err
	}
	raw, err := json.Marshal(record)
	if err != nil {
		return MemorySettingsEntry{}, err
	}
	identity, err := s.replica.EnsureIdentity()
	if err != nil {
		return MemorySettingsEntry{}, err
	}
	kind := schema.KVKindPrefix + schema.MemorySettingsNamespace
	for attempt := 0; attempt < 4; attempt++ {
		current, err := s.currentRecord(kind, schema.MemorySettingsKey)
		if err != nil {
			return MemorySettingsEntry{}, err
		}
		if expectedRevision != "" && current.Revision() != expectedRevision {
			return MemorySettingsEntry{}, ErrMemorySettingsChanged
		}
		_, err = s.Mutate(identity, Mutation{
			Namespace: schema.MemorySettingsNamespace, Key: schema.MemorySettingsKey, Revision: current.Revision(),
			OperationID: home.NewID("op_"), DaemonID: identity.DaemonID, Value: raw,
		})
		if errors.Is(err, crdt.ErrConflict) {
			if expectedRevision != "" {
				return MemorySettingsEntry{}, ErrMemorySettingsChanged
			}
			continue
		}
		if err != nil {
			return MemorySettingsEntry{}, err
		}
		return s.MemorySettings()
	}
	return MemorySettingsEntry{}, crdt.ErrConflict
}

// SavedMemory is a saved memory with its ID and record revision.
type SavedMemory struct {
	ID       string
	Revision string
	Record   schema.MemoryRecord
}

// Memory reads one saved memory; found is false for a missing, deleted or
// invalid record.
func (s *Store) Memory(projectID, memoryID string) (SavedMemory, bool, error) {
	current, err := s.currentRecord(schema.KVKindPrefix+schema.MemoryNamespace, schema.MemoryKey(projectID, memoryID))
	if err != nil {
		return SavedMemory{}, false, err
	}
	memory, ok := decodeSavedMemory(current)
	return memory, ok, nil
}

// EachMemory visits a project's saved memories in key order. Concurrent
// versions merge: the selected version wins, with each daemon's highest
// reinforcement count. Deleted and invalid records are skipped.
func (s *Store) EachMemory(projectID string, visit func(SavedMemory) error) error {
	_, data, err := s.replica.Snapshot()
	if err != nil {
		return err
	}
	defer data.Close()
	kind := schema.KVKindPrefix + schema.MemoryNamespace
	err = data.Each(crdt.Key(kind, projectID+"."), func(record crdt.Record) error {
		if record.Kind != kind {
			return nil
		}
		memory, ok := decodeSavedMemory(record)
		if !ok {
			return nil
		}
		return visit(memory)
	})
	if err == nil {
		err = data.Err()
	}
	return err
}

func decodeSavedMemory(record crdt.Record) (SavedMemory, bool) {
	if len(record.Versions) == 0 {
		return SavedMemory{}, false
	}
	selected := schema.SelectedKV(record)
	if selected.Deleted || len(selected.Value) == 0 {
		return SavedMemory{}, false
	}
	value, err := schema.DecodeMemory(record.ID, selected.Value)
	if err != nil {
		return SavedMemory{}, false
	}
	for _, version := range record.Versions {
		if version.Deleted || len(version.Value) == 0 {
			continue
		}
		sibling, err := schema.DecodeMemory(record.ID, version.Value)
		if err != nil {
			continue
		}
		for daemon, count := range sibling.Reinforcements {
			if count > value.Reinforcements[daemon] {
				if value.Reinforcements == nil {
					value.Reinforcements = map[string]int{}
				}
				value.Reinforcements[daemon] = count
			}
		}
	}
	_, memoryID, _ := schema.SplitMemoryKey(record.ID)
	return SavedMemory{ID: memoryID, Revision: record.Revision(), Record: value}, true
}

// PutMemory writes a saved memory as this daemon.
func (s *Store) PutMemory(memoryID string, record schema.MemoryRecord) error {
	if err := schema.ValidateMemory(record); err != nil {
		return err
	}
	return s.putDaemonRecord(schema.MemoryNamespace, schema.MemoryKey(record.Project, memoryID), record)
}

// DeleteMemory deletes a saved memory everywhere (a person's forget).
func (s *Store) DeleteMemory(projectID, memoryID string) error {
	identity, err := s.replica.EnsureIdentity()
	if err != nil {
		return err
	}
	kind, key := schema.KVKindPrefix+schema.MemoryNamespace, schema.MemoryKey(projectID, memoryID)
	for attempt := 0; attempt < 4; attempt++ {
		current, err := s.currentRecord(kind, key)
		if err != nil {
			return err
		}
		if len(current.Versions) == 0 {
			return nil
		}
		_, err = s.Mutate(identity, Mutation{
			Namespace: schema.MemoryNamespace, Key: key, Revision: current.Revision(),
			OperationID: home.NewID("op_"), DaemonID: identity.DaemonID, Delete: true,
		})
		if errors.Is(err, crdt.ErrConflict) {
			continue
		}
		return err
	}
	return crdt.ErrConflict
}
