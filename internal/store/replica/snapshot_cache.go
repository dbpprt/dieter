package replica

import (
	"bytes"
	"maps"
	"sync"

	"github.com/dbpprt/dieter/internal/replication/crdt"
)

type cachedSnapshotRecord struct {
	record crdt.Record
	bytes  int
}

// Repeated conversation writes resolve the same shared dependencies between
// metadata changes. Reuse bounded immutable point reads only after a real MVCC
// snapshot established exactly the same account, epoch and sequence. A view of
// an older revision must still read its own snapshot. Writer views never share.
type snapshotRecordCache struct {
	mu             sync.Mutex
	account, epoch string
	sequence       uint64
	bytes          int
	records        map[string]cachedSnapshotRecord
}

func (c *snapshotRecordCache) record(v *peerView, key string) (crdt.Record, int, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.account != v.account || c.epoch != v.epoch || c.sequence != v.sequence {
		return crdt.Record{}, 0, false
	}
	r, ok := c.records[key]
	if !ok {
		return crdt.Record{}, 0, false
	}
	return cloneSnapshotRecord(r.record), r.bytes, true
}

func (c *snapshotRecordCache) remember(v *peerView, key string, r crdt.Record, size int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.account == v.account && c.epoch == v.epoch && c.sequence > v.sequence {
		return
	}
	if c.account != v.account || c.epoch != v.epoch || c.sequence != v.sequence {
		c.account, c.epoch, c.sequence = v.account, v.epoch, v.sequence
		c.records = make(map[string]cachedSnapshotRecord)
		c.bytes = 0
	}
	if old, ok := c.records[key]; ok {
		c.bytes -= old.bytes
		delete(c.records, key)
	}
	if c.bytes+size > peerViewCacheBytes || len(c.records) >= peerViewCacheRecords {
		clear(c.records)
		c.bytes = 0
	}
	c.records[key] = cachedSnapshotRecord{cloneSnapshotRecord(r), size}
	c.bytes += size
}

func cloneSnapshotRecord(r crdt.Record) crdt.Record {
	versions := make([]crdt.Version, len(r.Versions))
	for i, v := range r.Versions {
		versions[i] = v
		versions[i].Clock = maps.Clone(v.Clock)
		versions[i].Value = bytes.Clone(v.Value)
		versions[i].Provenance = bytes.Clone(v.Provenance)
	}
	r.Versions = versions
	return r
}
