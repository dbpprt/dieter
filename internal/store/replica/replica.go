// Package replica is this daemon's replica of its account's peer records: the
// per-account SQLite database, bounded views and pinned snapshots, the local
// write-ahead effects that commit with the records, owner provenance, merges,
// change feeds, checkpoints, diagnostics, identity binding and adoption, the
// per-field codec of domain entities, and fractional order keys. Every write
// holds the central writer lock of home.Dir; a write acknowledges local
// durability, not a quorum.
package replica

import (
	"database/sql"
	"sync"

	"github.com/dbpprt/dieter/internal/store/home"
)

// Store is the peer replica of one DIETER_HOME.
type Store struct {
	home *home.Dir
	// peerSnapshotSlots bounds concurrent peer read transactions.
	peerSnapshotSlots chan struct{}

	peerWakeOnce     sync.Once
	peerWake         chan struct{}
	peerCacheMu      sync.Mutex
	peerCacheAccount string
	peerDBMu         sync.Mutex
	peerDBs          map[string]*sql.DB
	peerReadDBs      map[string]*sql.DB
	peerCacheData    PeerData
	peerHooks        Hooks
	ownerKeyCache    ownerKeyCache
	snapshotRecords  snapshotRecordCache
}

// New returns the replica of dir.
func New(dir *home.Dir) *Store {
	return &Store{home: dir, peerSnapshotSlots: make(chan struct{}, maxPeerSnapshots)}
}
