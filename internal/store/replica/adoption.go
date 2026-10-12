package replica

import (
	"encoding/json"

	"github.com/dbpprt/dieter/internal/replication/crdt"
)

func (s *Store) adoptLocalReplica(old, next PeerIdentity) error {
	source, err := s.OpenPeerView(old.Account)
	if err != nil {
		return err
	}
	target, err := s.OpenPeerView(next.Account)
	target.State = ClonePeerState(target.State)
	if err != nil {
		return err
	}
	flush := func() error {
		if len(target.Dirty) == 0 {
			return target.Err()
		}
		if err := s.SavePeerData(next.Account, target); err != nil {
			return err
		}
		var err error
		target, err = s.OpenPeerView(next.Account)
		return err
	}
	err = source.Each("", func(record crdt.Record) error {
		key := crdt.Key(record.Kind, record.ID)
		entity, field := crdt.SplitField(record.ID)
		if (record.Kind == "item" && field == "identity") || (record.Kind == "checkout" && field == "registration") || record.Kind == "schedule" {
			raw, ok := crdt.Selected(record)
			if !ok {
				return nil
			}
			var value map[string]any
			if err = json.Unmarshal(raw, &value); err != nil {
				return err
			}
			ownerKey := "ownerDaemonId"
			if record.Kind == "checkout" {
				ownerKey = "daemonId"
			}
			if value[ownerKey] == old.DaemonID {
				value[ownerKey] = next.DaemonID
				record, err = crdt.Put(record, record.Kind, record.ID, next.Actor, record.Revision(), RawValue(value), false)
				if err != nil {
					return err
				}
				if s.peerHooks.AdoptRecord != nil {
					if err = s.peerHooks.AdoptRecord(record.Kind, entity, old, next); err != nil {
						return err
					}
				}
			}
		}
		merged, e := crdt.Merge(target.Record(key), record)
		if e != nil {
			return e
		}
		target.Records[key] = merged
		target.Dirty[key] = true
		if len(target.Dirty) >= crdt.PageSize {
			return flush()
		}
		return nil
	})
	if err != nil {
		return err
	}
	if err = flush(); err != nil {
		return err
	}
	if s.peerHooks.AdoptLocal != nil {
		if err = s.peerHooks.AdoptLocal(old, next); err != nil {
			return err
		}
	}
	return source.Err()
}
