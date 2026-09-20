package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"os"
	"strings"

	"github.com/dbpprt/dieter/internal/peerstore"
)

type kvReceipt struct {
	ID, Fingerprint string
	Value           []byte
}

type KVMutation struct {
	Namespace, Key, Revision, OperationID, DaemonID string
	Value                                           json.RawMessage
	Delete                                          bool
	Move                                            *KVMove
}
type KVMove struct{ Parent, After, Before string }

// MutateKV acknowledges durable local state. Its receipt is committed in the
// same transaction, and is only valid on this admitting daemon/account.
func (s *Store) MutateKV(identity PeerIdentity, m KVMutation) (peerstore.Record, error) {
	var zero peerstore.Record
	kind, err := peerstore.KVKind(m.Namespace)
	if err != nil {
		return zero, err
	}
	if !peerstore.ValidID(m.Key) || !peerstore.ValidID(m.OperationID) || m.DaemonID != identity.DaemonID {
		return zero, errors.New("valid key, operation ID and accepting daemon ID required")
	}
	if len(m.Value) > peerstore.MaxValueBytes {
		return zero, peerstore.ErrCapacity
	}
	release, err := s.beginWrite()
	if err != nil {
		return zero, err
	}
	defer release()
	if err = s.checkPeerIdentity(identity); err != nil {
		return zero, err
	}
	db, err := s.peerDatabase(identity.Account)
	if err != nil {
		return zero, err
	}
	fingerprint := peerstore.Revision(m)
	var previous string
	var raw []byte
	err = db.QueryRow("SELECT fingerprint,value FROM kv_receipts WHERE id=?", m.OperationID).Scan(&previous, &raw)
	if err == nil {
		if previous != fingerprint {
			return zero, errors.New("operation ID reused with different input")
		}
		err = json.Unmarshal(raw, &zero)
		return zero, err
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return zero, err
	}
	data, err := s.PeerData(identity.Account)
	if err != nil {
		return zero, err
	}
	data.State = clonePeerState(data.State)
	key := peerstore.Key(kind, m.Key)
	old := data.Records[key]
	if old.Revision() != m.Revision {
		return zero, peerstore.ErrConflict
	}
	if m.Move != nil {
		var position peerstore.KVPosition
		position.Parent = m.Move.Parent
		anchor := func(id string) (string, error) {
			if id == "" {
				return "", nil
			}
			if id == m.Key {
				return "", errors.New("cannot move relative to itself")
			}
			v := peerstore.SelectedKV(data.Records[peerstore.Key(kind, id)])
			var p peerstore.KVPosition
			if v.Deleted || json.Unmarshal(v.Value, &p) != nil || p.Parent != position.Parent || !peerstore.ValidPosition(p) {
				return "", peerstore.ErrConflict
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
			for _, r := range data.Records {
				if r.Kind != kind || r.ID == m.Key || !strings.HasPrefix(r.ID, prefix) {
					continue
				}
				v := peerstore.SelectedKV(r)
				var p peerstore.KVPosition
				if !v.Deleted && json.Unmarshal(v.Value, &p) == nil && p.Parent == position.Parent && peerstore.ValidPosition(p) && p.Rank > left {
					left = p.Rank
				}
			}
		}
		if right != "" && left >= right {
			return zero, peerstore.ErrConflict
		}
		position.Rank, err = orderBetween(left, right)
		if err != nil {
			return zero, err
		}
		if !peerstore.ValidPosition(position) {
			return zero, errors.New("invalid ordered position")
		}
		m.Value, _ = json.Marshal(position)
	}
	record, err := peerstore.Put(old, kind, m.Key, identity.Actor, m.Revision, m.Value, m.Delete)
	if err != nil {
		return zero, err
	}
	if err = peerstore.ValidateSettings(record); err != nil {
		return zero, err
	}
	data.Records[key], data.Dirty[key] = record, true
	raw, err = json.Marshal(record)
	if err != nil {
		return zero, err
	}
	err = s.writePeerStateReceipt(identity.Account, data, &kvReceipt{m.OperationID, fingerprint, raw})
	return record, err
}

// KVIdentity initializes a local replica under the central mutation lock.
func (s *Store) KVIdentity() (PeerIdentity, error) {
	if identity, err := s.PeerIdentity(); err == nil {
		return identity, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return identity, err
	}
	release, err := s.beginWrite()
	if err != nil {
		return PeerIdentity{}, err
	}
	defer release()
	identity, err := s.sharedIdentity()
	if err != nil {
		return identity, err
	}
	_, err = s.peerDatabase(identity.Account)
	return identity, err
}
