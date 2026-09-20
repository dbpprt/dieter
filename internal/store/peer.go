package store

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/peerstore"
)

type PeerIdentity struct {
	Account  string `json:"account"`
	Subject  string `json:"subject"`
	DaemonID string `json:"daemonId"`
	Gateway  string `json:"gateway"`
	Actor    string `json:"actor"`
}
type peerProgress struct {
	LastSyncAt string `json:"lastSyncAt,omitempty"`
	LastPeerID string `json:"lastPeerId,omitempty"`
	LastRoute  string `json:"lastRoute,omitempty"`
}

type PeerData struct {
	Epoch      string              `json:"-"`
	Sequence   uint64              `json:"-"`
	EntityIDs  map[string][]string `json:"-"`
	Membership map[string][]string `json:"-"`
	peerstore.State
	LastSyncAt string `json:"lastSyncAt,omitempty"`
	LastPeerID string `json:"lastPeerId,omitempty"`
	LastRoute  string `json:"lastRoute,omitempty"`
}

func (s *Store) peerPath(account string) string {
	return filepath.Join(s.Root, "peers", peerstore.Revision(account)+".sqlite")
}
func (s *Store) PeerIdentity() (PeerIdentity, error) {
	var v PeerIdentity
	err := readPeerJSON(filepath.Join(s.Root, "peers", "identity.json"), &v)
	return v, err
}

// BindPeerAccount is called only after GetAccount succeeds through authenticated
// enrollment proof. A new account/enrollment gets an isolated actor and store.
func (s *Store) BindPeerAccount(account, subject, daemon, gateway string) (PeerIdentity, error) {
	release, err := s.beginWriteLock()
	if err != nil {
		return PeerIdentity{}, err
	}
	defer release()
	old, err := s.PeerIdentity()
	if err == nil && old.Account == account && old.Subject == subject && old.DaemonID == daemon && old.Gateway == gateway {
		return old, nil
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return PeerIdentity{}, err
	}
	next := PeerIdentity{account, subject, daemon, gateway, newID("actor_")}
	if _, err = s.peerDatabase(account); err != nil {
		return next, err
	}
	if old.Account == "local" {
		if err = s.adoptLocalReplica(old, next); err != nil {
			return next, err
		}
	}
	raw, err := json.Marshal(next)
	if err != nil {
		return next, err
	}
	err = atomicWrite(filepath.Join(s.Root, "peers", "identity.json"), raw)
	return next, err
}
func readPeerJSON(path string, v any) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, peerstore.MaxStateBytes+1))
	if err != nil {
		return err
	}
	if len(raw) > peerstore.MaxStateBytes {
		return peerstore.ErrCapacity
	}
	return json.Unmarshal(raw, v)
}
func (s *Store) PeerData(account string) (PeerData, error) {
	data, err := s.readPeerState(account)
	if err != nil {
		return data, err
	}
	var progress peerProgress
	if err = readPeerJSON(s.peerPath(account)+".status", &progress); err != nil && !errors.Is(err, os.ErrNotExist) {
		return data, err
	}
	if err == nil {
		data.LastSyncAt, data.LastPeerID, data.LastRoute = progress.LastSyncAt, progress.LastPeerID, progress.LastRoute
	}
	return data, nil
}
func (s *Store) savePeerData(account string, data PeerData) error {
	return s.writePeerState(account, data)
}
func (s *Store) checkPeerIdentity(expected PeerIdentity) error {
	current, err := s.PeerIdentity()
	if err != nil {
		return err
	}
	if current != expected {
		return errors.New("peer account changed")
	}
	return nil
}
func (s *Store) PutPeerRecord(identity PeerIdentity, kind, id, expected string, value []byte, deleted bool) (peerstore.Record, error) {
	release, err := s.beginWrite()
	if err != nil {
		return peerstore.Record{}, err
	}
	defer release()
	if err = s.checkPeerIdentity(identity); err != nil {
		return peerstore.Record{}, err
	}
	data, err := s.PeerData(identity.Account)
	data.State = clonePeerState(data.State)
	if err != nil {
		return peerstore.Record{}, err
	}
	if err := s.validateDomainWrite(identity, data, kind, id, value, deleted); err != nil {
		return peerstore.Record{}, err
	}
	record, err := peerstore.Put(data.Records[peerstore.Key(kind, id)], kind, id, identity.Actor, expected, value, deleted)
	if err != nil {
		return record, err
	}
	if err = peerstore.ValidateSettings(record); err != nil {
		return record, err
	}
	data.Records[peerstore.Key(kind, id)] = record
	data.Dirty[peerstore.Key(kind, id)] = true
	if err = s.savePeerData(identity.Account, data); err != nil {
		return peerstore.Record{}, err
	}
	committed, err := s.PeerData(identity.Account)
	return committed.Records[peerstore.Key(kind, id)], err
}
func (s *Store) MergePeerRecords(identity PeerIdentity, records []peerstore.Record) error {
	page, err := json.Marshal(records)
	if err != nil {
		return err
	}
	if len(records) > peerstore.PageSize || len(page) > peerstore.MaxPageBytes {
		return peerstore.ErrCapacity
	}
	release, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer release()
	if err = s.checkPeerIdentity(identity); err != nil {
		return err
	}
	data, err := s.PeerData(identity.Account)
	data.State = clonePeerState(data.State)
	if err != nil {
		return err
	}
	changed := false
	for _, record := range records {
		if err = peerstore.ValidateSettings(record); err != nil {
			return err
		}
		key := peerstore.Key(record.Kind, record.ID)
		if err = s.validatePeerDomainMerge(data, data.Records[key], record); err != nil {
			return err
		}
		merged, e := peerstore.Merge(data.Records[key], record)
		if e != nil {
			return e
		}
		if data.Records[key].Revision() != merged.Revision() {
			data.Records[key] = merged
			data.Dirty[key] = true
			changed = true
		}
	}
	if !changed {
		return nil
	}
	return s.savePeerData(identity.Account, data)
}
func (s *Store) PeerSynced(identity PeerIdentity, peer, route string) error {
	release, err := s.beginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	if err = s.checkPeerIdentity(identity); err != nil {
		return err
	}
	// Progress is diagnostic, not replicated state. Updating it must not rewrite
	// an unchanged account snapshot (up to 32 MiB) on every idle sync round.
	progress := peerProgress{time.Now().UTC().Format(time.RFC3339Nano), peer, route}
	raw, err := json.Marshal(progress)
	if err != nil {
		return err
	}
	return atomicWrite(s.peerPath(identity.Account)+".status", raw)
}

// Cached snapshots are immutable; writers replace only their own map.
func clonePeerState(source peerstore.State) peerstore.State {
	records := make(map[string]peerstore.Record, len(source.Records))
	for key, record := range source.Records {
		records[key] = record
	}
	return peerstore.State{Records: records, Dirty: map[string]bool{}}
}

func indexPeerData(data *PeerData) {
	data.EntityIDs = map[string][]string{}
	data.Membership = map[string][]string{}
	for _, record := range data.Records {
		entity, field := peerstore.SplitField(record.ID)
		if _, ok := peerstore.Selected(record); !ok {
			continue
		}
		key := record.Kind + "/" + field
		data.EntityIDs[key] = append(data.EntityIDs[key], entity)
		if record.Kind == "assignment" {
			card, _, _ := strings.Cut(entity, ".")
			data.Membership[card] = append(data.Membership[card], entity)
		}
	}
	for _, ids := range data.EntityIDs {
		sort.Strings(ids)
	}
}

// PeerChangesAvailable coalesces committed changes into one pending wakeup for
// the serve-owned replication worker. Periodic rounds cover other processes.
func (s *Store) PeerChangesAvailable() <-chan struct{} {
	s.peerWakeOnce.Do(func() { s.peerWake = make(chan struct{}, 1) })
	return s.peerWake
}
func (s *Store) notifyPeerChanges() {
	s.PeerChangesAvailable()
	select {
	case s.peerWake <- struct{}{}:
	default:
	}
}
