package kv

import (
	"encoding/json"
	"strings"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/replica"
)

// Mutation writes, deletes or moves one record of a namespace. OperationID makes
// it idempotent; Revision is the observed record revision.
type Mutation struct {
	Namespace, Key, Revision, OperationID, DaemonID string
	Value                                           json.RawMessage
	Delete                                          bool
	Move                                            *Move
}

// Move places the record between siblings of Parent (empty anchors: the end).
type Move struct{ Parent, After, Before string }

// Mutate acknowledges durable local state. Its receipt is committed in the
// same transaction, and is only valid on this admitting daemon/account.
func (s *Store) Mutate(identity replica.PeerIdentity, m Mutation) (crdt.Record, error) {
	var zero crdt.Record
	kind, err := schema.KVKind(m.Namespace)
	if err != nil {
		return zero, err
	}
	if !crdt.ValidID(m.Key) || !crdt.ValidID(m.OperationID) || m.DaemonID != identity.DaemonID {
		return zero, fault.New(fault.Invalid, "valid key, operation ID and accepting daemon ID required")
	}
	if len(m.Value) > crdt.MaxValueBytes {
		return zero, crdt.ErrCapacity
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return zero, err
	}
	defer release()
	if err = s.replica.CheckPeerIdentity(identity); err != nil {
		return zero, err
	}
	fingerprint := crdt.Revision(m)
	previous, raw, found, err := s.replica.LookupReceipt(identity.Account, m.OperationID)
	if err != nil {
		return zero, err
	}
	if found {
		if previous != fingerprint {
			return zero, fault.New(fault.Invalid, "operation ID reused with different input")
		}
		err = json.Unmarshal(raw, &zero)
		return zero, err
	}
	data, err := s.replica.OpenPeerView(identity.Account)
	if err != nil {
		return zero, err
	}
	data.State = replica.ClonePeerState(data.State)
	key := crdt.Key(kind, m.Key)
	old := data.Record(key)
	if old.Revision() != m.Revision {
		return zero, crdt.ErrConflict
	}
	if m.Move != nil {
		var position schema.KVPosition
		position.Parent = m.Move.Parent
		anchor := func(id string) (string, error) {
			if id == "" {
				return "", nil
			}
			if id == m.Key {
				return "", fault.New(fault.Invalid, "cannot move relative to itself")
			}
			v := schema.SelectedKV(data.Record(crdt.Key(kind, id)))
			var p schema.KVPosition
			if v.Deleted || json.Unmarshal(v.Value, &p) != nil || p.Parent != position.Parent || !schema.ValidPosition(p) {
				return "", crdt.ErrConflict
			}
			return p.Rank, nil
		}
		left, e := anchor(m.Move.After)
		if e != nil {
			return zero, e
		}
		right, e := anchor(m.Move.Before)
		if e != nil {
			return zero, e
		}
		if m.Move.After == "" && m.Move.Before == "" {
			// Namespace may contain several ordered lists. Their key prefix and parent
			// jointly identify the list (e.g. projects-folder, projects-item, pinned).
			prefix := ""
			if index := strings.IndexByte(m.Key, '.'); index >= 0 {
				prefix = m.Key[:index+1]
			}
			err = data.Each(kind+"/"+prefix, func(r crdt.Record) error {
				if r.Kind != kind || r.ID == m.Key || !strings.HasPrefix(r.ID, prefix) {
					return nil
				}
				v := schema.SelectedKV(r)
				var p schema.KVPosition
				if !v.Deleted && json.Unmarshal(v.Value, &p) == nil && p.Parent == position.Parent && schema.ValidPosition(p) && p.Rank > left {
					left = p.Rank
				}
				return nil
			})
			if err != nil {
				return zero, err
			}
		}
		if right != "" && left >= right {
			return zero, crdt.ErrConflict
		}
		position.Rank, err = replica.OrderBetween(left, right)
		if err != nil {
			return zero, err
		}
		if !schema.ValidPosition(position) {
			return zero, fault.New(fault.Invalid, "invalid ordered position")
		}
		m.Value, _ = json.Marshal(position)
	}
	record, err := crdt.Put(old, kind, m.Key, identity.Actor, m.Revision, m.Value, m.Delete)
	if err != nil {
		return zero, err
	}
	if err = schema.Validate(record); err != nil {
		return zero, err
	}
	data.Records[key], data.Dirty[key] = record, true
	raw, err = json.Marshal(record)
	if err != nil {
		return zero, err
	}
	err = s.replica.WritePeerStateReceipt(identity.Account, data, &replica.Receipt{ID: m.OperationID, Fingerprint: fingerprint, Value: raw})
	return record, err
}
