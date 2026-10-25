package kv

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"

	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/home"
)

// ChannelDaemon is the ID agent channel records name as their writer: this
// daemon's enrolled ID, or its local writer identity before enrollment, which
// it creates when missing.
func (s *Store) ChannelDaemon() (string, error) {
	identity, err := s.replica.EnsureIdentity()
	if err != nil {
		return "", err
	}
	return identity.DaemonID, nil
}

// KnownChannelDaemon is ChannelDaemon without creating an identity: empty
// while this daemon has none, so reading channels never writes.
func (s *Store) KnownChannelDaemon() (string, error) {
	identity, err := s.replica.PeerIdentity()
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return identity.DaemonID, nil
}

// PutChannel writes one agent channel record this daemon owns: a message slot,
// a receipt, or its pins or claims of a project. An unchanged value is not
// rewritten; a concurrent rewrite of the same key retries on its revision.
func (s *Store) PutChannel(namespace, key string, value any) error {
	if !schema.ChannelNamespaceKind(namespace) {
		return errors.New("not an agent channel namespace")
	}
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	identity, err := s.replica.EnsureIdentity()
	if err != nil {
		return err
	}
	kind := schema.KVKindPrefix + namespace
	for attempt := 0; attempt < 4; attempt++ {
		_, data, err := s.replica.Snapshot()
		if err != nil {
			return err
		}
		current := data.Record(crdt.Key(kind, key))
		data.Close()
		selected := schema.SelectedKV(current)
		if len(current.Versions) == 1 && !selected.Deleted && bytes.Equal(selected.Value, raw) {
			return nil
		}
		_, err = s.Mutate(identity, Mutation{
			Namespace: namespace, Key: key, Revision: current.Revision(),
			OperationID: home.NewID("op_"), DaemonID: identity.DaemonID, Value: raw,
		})
		if errors.Is(err, crdt.ErrConflict) {
			continue
		}
		return err
	}
	return crdt.ErrConflict
}

// EachChannel visits the records of an agent channel namespace whose keys
// start with prefix, in key order, with their record revision and selected
// value. Deleted records are skipped.
func (s *Store) EachChannel(namespace, prefix string, visit func(key, revision string, value []byte) error) error {
	if !schema.ChannelNamespaceKind(namespace) {
		return errors.New("not an agent channel namespace")
	}
	_, data, err := s.replica.Snapshot()
	if err != nil {
		return err
	}
	defer data.Close()
	kind := schema.KVKindPrefix + namespace
	err = data.Each(crdt.Key(kind, prefix), func(record crdt.Record) error {
		if record.Kind != kind {
			return nil
		}
		version := schema.SelectedKV(record)
		if version.Deleted || len(version.Value) == 0 {
			return nil
		}
		return visit(record.ID, record.Revision(), version.Value)
	})
	if err == nil {
		err = data.Err()
	}
	return err
}
