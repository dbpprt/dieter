package store

import "github.com/dbpprt/dieter/internal/replication/crdt"

// This file is the root API that aggregate subpackages (store/vaults,
// store/daemonstate) build on: the central writer lock, the replicated peer
// records of this machine's account, and private JSON files. Aggregates never
// bypass the lock or write peer records outside SavePeerData.

// BeginWrite acquires the central writer lock and records a durable pending
// change. The returned function commits the change and releases the lock.
func (s *Store) BeginWrite() (func(), error) { return s.beginWrite() }

// BeginWriteLock acquires the central writer lock without recording a change,
// for daemon-local files outside the change stream.
func (s *Store) BeginWriteLock() (func(), error) { return s.beginWriteLock() }

// CheckPeerIdentity fails when the account binding changed since expected was
// read. Call it while holding the writer lock.
func (s *Store) CheckPeerIdentity(expected PeerIdentity) error { return s.checkPeerIdentity(expected) }

// OpenPeerView reads the account's records for a mutation; hold the writer
// lock and close the view.
func (s *Store) OpenPeerView(account string) (PeerData, error) { return s.openPeerView(account) }

// OpenPeerSnapshot pins a consistent read-only snapshot; close it.
func (s *Store) OpenPeerSnapshot(account string) (PeerData, error) {
	return s.openPeerSnapshot(account)
}

// SavePeerData commits the dirty records of data. Hold the writer lock.
func (s *Store) SavePeerData(account string, data PeerData) error {
	return s.savePeerData(account, data)
}

// Record returns one record of the view, or the zero record.
func (d PeerData) Record(key string) crdt.Record { return d.record(key) }

// Each visits the records whose key starts with prefix.
func (d PeerData) Each(prefix string, visit func(crdt.Record) error) error {
	return d.each(prefix, visit)
}

// ClonePeerState copies a state's records so a mutation can mark them dirty
// without touching the view's cache.
func ClonePeerState(source crdt.State) crdt.State { return clonePeerState(source) }

// WriteJSON atomically writes a private (0600) JSON file.
func WriteJSON(path string, value any) error { return writeJSON(path, value) }
