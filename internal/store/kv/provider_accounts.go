package kv

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"strings"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/replica"
)

// ErrProviderAccountRemoved reports a write to a tombstoned account.
var ErrProviderAccountRemoved = fault.New(fault.NotFound, "the provider account was removed")

// ProviderAccountEntry is one account record with its record revision.
// Deleted entries are tombstones and carry no record.
type ProviderAccountEntry struct {
	ID, Revision string
	Deleted      bool
	Record       schema.ProviderAccountRecord
}

// ProviderLoginEntry is one machine's login record of an account.
type ProviderLoginEntry struct {
	AccountID, DaemonID string
	Deleted             bool
	Record              schema.ProviderLoginRecord
}

// providerIdentity is the replica identity provider writers publish as. They
// never create one: a machine without a replica identity cannot hold accounts.
func (s *Store) providerIdentity() (replica.PeerIdentity, error) {
	identity, err := s.replica.PeerIdentity()
	if errors.Is(err, os.ErrNotExist) {
		return identity, fault.New(fault.FailedPrecondition, "this machine has no replica identity yet")
	}
	return identity, err
}

// PutProviderAccount changes one account record with compare-and-set. update
// receives the current record (nil when absent) and returns the next one, or
// nil to leave it unchanged. A lost race re-reads and calls update again; a
// tombstoned account fails with ErrProviderAccountRemoved.
func (s *Store) PutProviderAccount(id string, update func(current *schema.ProviderAccountRecord) (*schema.ProviderAccountRecord, error)) (schema.ProviderAccountRecord, error) {
	var zero schema.ProviderAccountRecord
	if !schema.ValidProviderAccountID(id) {
		return zero, fault.New(fault.Invalid, "invalid provider account ID")
	}
	identity, err := s.providerIdentity()
	if err != nil {
		return zero, err
	}
	kind := schema.KVKindPrefix + schema.ProviderAccountsNamespace
	for attempt := 0; attempt < 4; attempt++ {
		current, err := s.currentRecord(kind, id)
		if err != nil {
			return zero, err
		}
		selected := schema.SelectedKV(current)
		var existing *schema.ProviderAccountRecord
		if len(current.Versions) > 0 {
			if selected.Deleted {
				return zero, ErrProviderAccountRemoved
			}
			record, err := schema.DecodeProviderAccount(id, selected.Value)
			if err != nil {
				return zero, err
			}
			existing = &record
		}
		next, err := update(existing)
		if err != nil {
			return zero, err
		}
		if next == nil {
			if existing == nil {
				return zero, fault.New(fault.NotFound, "provider account not found")
			}
			return *existing, nil
		}
		raw, err := json.Marshal(next)
		if err != nil {
			return zero, err
		}
		if same, err := unchanged(current, raw); err != nil || same {
			return *next, err
		}
		_, err = s.Mutate(identity, Mutation{
			Namespace: schema.ProviderAccountsNamespace, Key: id, Revision: current.Revision(),
			OperationID: home.NewID("op_"), DaemonID: identity.DaemonID, Value: raw,
		})
		if errors.Is(err, crdt.ErrConflict) {
			continue
		}
		if err != nil {
			return zero, err
		}
		return *next, nil
	}
	return zero, crdt.ErrConflict
}

// DeleteProviderAccount tombstones an account. Deleting an absent or removed
// account succeeds.
func (s *Store) DeleteProviderAccount(id string) error {
	if !schema.ValidProviderAccountID(id) {
		return fault.New(fault.Invalid, "invalid provider account ID")
	}
	return s.deleteProviderRecord(schema.ProviderAccountsNamespace, id)
}

// PutProviderDefault makes accountID the default account of provider.
func (s *Store) PutProviderDefault(provider, accountID string) error {
	if !schema.ValidProvider(provider) || !schema.ValidProviderAccountID(accountID) {
		return fault.New(fault.Invalid, "invalid provider default")
	}
	return s.putProviderRecord(schema.ProviderDefaultsNamespace, provider, schema.ProviderDefaultRecord{AccountID: accountID})
}

// DeleteProviderDefault clears provider's default account.
func (s *Store) DeleteProviderDefault(provider string) error {
	if !schema.ValidProvider(provider) {
		return fault.New(fault.Invalid, "invalid provider")
	}
	return s.deleteProviderRecord(schema.ProviderDefaultsNamespace, provider)
}

// PutProviderLogin writes this machine's login record of an account. Only the
// daemon named in the key writes it, so daemonID must be this replica's. An
// unchanged value is not rewritten.
func (s *Store) PutProviderLogin(accountID, daemonID string, value schema.ProviderLoginRecord) error {
	if err := s.ownLogin(accountID, daemonID); err != nil {
		return err
	}
	return s.putProviderRecord(schema.ProviderLoginsNamespace, schema.ProviderLoginKey(accountID, daemonID), value)
}

// DeleteProviderLogin tombstones this machine's login record of an account.
func (s *Store) DeleteProviderLogin(accountID, daemonID string) error {
	if err := s.ownLogin(accountID, daemonID); err != nil {
		return err
	}
	return s.deleteProviderRecord(schema.ProviderLoginsNamespace, schema.ProviderLoginKey(accountID, daemonID))
}

func (s *Store) ownLogin(accountID, daemonID string) error {
	if _, _, ok := schema.ParseProviderLoginKey(schema.ProviderLoginKey(accountID, daemonID)); !ok {
		return fault.New(fault.Invalid, "invalid provider login key")
	}
	identity, err := s.providerIdentity()
	if err != nil {
		return err
	}
	if identity.DaemonID != daemonID {
		return fault.New(fault.FailedPrecondition, "a provider login record is written only by its own machine")
	}
	return nil
}

// EachProviderAccount visits every account record in key order, including
// tombstones (Deleted) so cleanup can act on removed accounts. Records that
// fail validation are skipped.
func (s *Store) EachProviderAccount(visit func(ProviderAccountEntry) error) error {
	return s.eachProvider(schema.ProviderAccountsNamespace, "", true, func(record crdt.Record, selected crdt.Version) error {
		entry := ProviderAccountEntry{ID: record.ID, Revision: record.Revision(), Deleted: selected.Deleted}
		if !entry.Deleted {
			value, err := schema.DecodeProviderAccount(record.ID, selected.Value)
			if err != nil {
				return nil
			}
			entry.Record = value
		}
		return visit(entry)
	})
}

// EachProviderDefault visits the providers' default records.
func (s *Store) EachProviderDefault(visit func(provider string, value schema.ProviderDefaultRecord) error) error {
	return s.eachProvider(schema.ProviderDefaultsNamespace, "", false, func(record crdt.Record, selected crdt.Version) error {
		value, err := schema.DecodeProviderDefault(record.ID, selected.Value)
		if err != nil {
			return nil
		}
		return visit(record.ID, value)
	})
}

// EachProviderLogin visits login records whose key starts with prefix (an
// account ID plus "." selects one account). includeDeleted also visits
// tombstones.
func (s *Store) EachProviderLogin(prefix string, includeDeleted bool, visit func(ProviderLoginEntry) error) error {
	return s.eachProvider(schema.ProviderLoginsNamespace, prefix, includeDeleted, func(record crdt.Record, selected crdt.Version) error {
		accountID, daemonID, ok := schema.ParseProviderLoginKey(record.ID)
		if !ok {
			return nil
		}
		entry := ProviderLoginEntry{AccountID: accountID, DaemonID: daemonID, Deleted: selected.Deleted}
		if !entry.Deleted {
			value, err := schema.DecodeProviderLogin(record.ID, selected.Value)
			if err != nil {
				return nil
			}
			entry.Record = value
		}
		return visit(entry)
	})
}

func (s *Store) eachProvider(namespace, prefix string, includeDeleted bool, visit func(crdt.Record, crdt.Version) error) error {
	_, data, err := s.replica.Snapshot()
	if err != nil {
		return err
	}
	defer data.Close()
	kind := schema.KVKindPrefix + namespace
	err = data.Each(crdt.Key(kind, prefix), func(record crdt.Record) error {
		if record.Kind != kind || !strings.HasPrefix(record.ID, prefix) || len(record.Versions) == 0 {
			return nil
		}
		selected := schema.SelectedKV(record)
		if selected.Deleted && !includeDeleted || !selected.Deleted && len(selected.Value) == 0 {
			return nil
		}
		return visit(record, selected)
	})
	if err == nil {
		err = data.Err()
	}
	return err
}

// putProviderRecord writes a last-writer-wins record, retrying on a
// concurrent local rewrite. An unchanged value is not rewritten.
func (s *Store) putProviderRecord(namespace, key string, value any) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	identity, err := s.providerIdentity()
	if err != nil {
		return err
	}
	kind := schema.KVKindPrefix + namespace
	for attempt := 0; attempt < 4; attempt++ {
		current, err := s.currentRecord(kind, key)
		if err != nil {
			return err
		}
		if same, err := unchanged(current, raw); err != nil || same {
			return err
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

func (s *Store) deleteProviderRecord(namespace, key string) error {
	identity, err := s.providerIdentity()
	if err != nil {
		return err
	}
	kind := schema.KVKindPrefix + namespace
	for attempt := 0; attempt < 4; attempt++ {
		current, err := s.currentRecord(kind, key)
		if err != nil {
			return err
		}
		if len(current.Versions) == 0 || len(current.Versions) == 1 && current.Versions[0].Deleted {
			return nil
		}
		_, err = s.Mutate(identity, Mutation{
			Namespace: namespace, Key: key, Revision: current.Revision(),
			OperationID: home.NewID("op_"), DaemonID: identity.DaemonID, Delete: true,
		})
		if errors.Is(err, crdt.ErrConflict) {
			continue
		}
		return err
	}
	return crdt.ErrConflict
}

func (s *Store) currentRecord(kind, key string) (crdt.Record, error) {
	_, data, err := s.replica.Snapshot()
	if err != nil {
		return crdt.Record{}, err
	}
	defer data.Close()
	return data.Record(crdt.Key(kind, key)), data.Err()
}

// unchanged reports whether record holds exactly raw as its only version.
// Stored values are canonical JSON (sorted keys), so raw is canonicalized the
// same way before comparing.
func unchanged(record crdt.Record, raw []byte) (bool, error) {
	if len(record.Versions) != 1 || record.Versions[0].Deleted {
		return false, nil
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return false, err
	}
	canonical, err := json.Marshal(value)
	if err != nil {
		return false, err
	}
	return bytes.Equal(record.Versions[0].Value, canonical), nil
}
