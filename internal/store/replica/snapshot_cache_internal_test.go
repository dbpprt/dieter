package replica

import (
	"fmt"
	"testing"

	"github.com/dbpprt/dieter/internal/replication/crdt"
)

func TestSharedSnapshotCacheIsBoundedAndRevisionIsolated(t *testing.T) {
	t.Parallel()
	c := &snapshotRecordCache{}
	v := &peerView{account: "one", epoch: "epoch", sequence: 2}
	for i := range peerViewCacheRecords + 1 {
		c.remember(v, fmt.Sprint(i), crdt.Record{}, 1)
	}
	if len(c.records) > peerViewCacheRecords || c.bytes > peerViewCacheBytes {
		t.Fatal("record bound exceeded")
	}
	c.remember(v, "large", crdt.Record{}, peerViewCacheBytes)
	if len(c.records) != 1 || c.bytes != peerViewCacheBytes {
		t.Fatal("byte bound exceeded")
	}
	older := &peerView{account: "one", epoch: "epoch", sequence: 1}
	c.remember(older, "stale", crdt.Record{}, 1)
	if _, _, ok := c.record(older, "large"); ok {
		t.Fatal("older view read newer cached record")
	}
	if _, _, ok := c.record(v, "large"); !ok {
		t.Fatal("older view displaced newer cache")
	}
	for _, other := range []*peerView{{account: "two", epoch: "epoch", sequence: 2}, {account: "one", epoch: "replaced", sequence: 2}, {account: "one", epoch: "epoch", sequence: 3}} {
		if _, _, ok := c.record(other, "large"); ok {
			t.Fatal("cache crossed revision boundary")
		}
	}
}
