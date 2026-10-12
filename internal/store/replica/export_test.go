package replica

import "database/sql"

// Test seams for the external replica tests, which run against the composed store.

const (
	ViewCacheRecords = peerViewCacheRecords
	ViewCacheBytes   = peerViewCacheBytes
)

// Database is the account's single writer connection (fault injection).
func (s *Store) Database(account string) (*sql.DB, error) { return s.peerDatabase(account) }

// Path is the account's replica database file.
func (s *Store) Path(account string) string { return s.peerPath(account) }

// ReadPoolInUse counts the open connections of the account's read pool.
func (s *Store) ReadPoolInUse(account string) int {
	s.peerDBMu.Lock()
	defer s.peerDBMu.Unlock()
	return s.peerReadDBs[account].Stats().InUse
}

// SnapshotSlots is the bound on concurrent read snapshots.
func (s *Store) SnapshotSlots() int { return cap(s.peerSnapshotSlots) }

// ViewCache reports the size of a view's point-read cache.
func (d PeerData) ViewCache() (records, bytes int) { return len(d.view.cache), d.view.bytes }

// ClearViewCache drops a view's point-read cache.
func (d PeerData) ClearViewCache() { clear(d.view.cache) }
