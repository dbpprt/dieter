package kv_test

import (
	"encoding/json"
	"errors"
	"fmt"
	"testing"

	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kv"
	"github.com/dbpprt/dieter/internal/store/replica"
)

func TestKVReplicationReceiptsAndDeletion(t *testing.T) {
	t.Parallel()
	stores := []*store.Store{store.New(t.TempDir()), store.New(t.TempDir()), store.New(t.TempDir())}
	ids := make([]replica.PeerIdentity, 3)
	for i, s := range stores {
		var err error
		ids[i], err = s.Replica.BindPeerAccount("account", "github:1", fmt.Sprint("daemon", i), "https://gateway.test")
		if err != nil {
			t.Fatal(err)
		}
	}
	write := func(i int, key, revision, value, op string, deleted bool) crdt.Record {
		t.Helper()
		r, e := stores[i].KV.Mutate(ids[i], kv.Mutation{Namespace: "navigation", Key: key, Revision: revision, Value: json.RawMessage(value), OperationID: op, DaemonID: ids[i].DaemonID, Delete: deleted})
		if e != nil {
			t.Fatal(e)
		}
		return r
	}
	join := func(from, to int) {
		t.Helper()
		data, e := stores[from].Replica.PeerData(ids[from].Account)
		if e != nil {
			t.Fatal(e)
		}
		if e = stores[to].Replica.MergePeerRecords(ids[to], data.Sorted()); e != nil {
			t.Fatal(e)
		}
	}
	original := write(0, "projects-folder.f.name", "", `"Research"`, "create", false)
	join(0, 1)
	join(0, 2)
	write(0, "projects-folder.f.name", original.Revision(), `"Mac"`, "rename", false)
	write(1, "projects-folder.f.name", original.Revision(), "", "delete", true)
	write(2, "projects-folder.f.expanded", "", `false`, "collapse", false)
	join(0, 1)
	join(1, 2)
	join(2, 0)
	join(0, 1)
	var hash string
	for i, s := range stores {
		data, e := s.Replica.PeerData(ids[i].Account)
		if e != nil {
			t.Fatal(e)
		}
		r := data.Records["kv.navigation/projects-folder.f.name"]
		if len(r.Versions) != 2 || !schema.SelectedKV(r).Deleted {
			t.Fatal(r)
		}
		next := crdt.Revision(data.State)
		if hash != "" && hash != next {
			t.Fatal("replicas diverged")
		}
		hash = next
	}
	// A lost acknowledgement retried after restart returns the original admission,
	// even after newer edits and joins, without resurrecting the folder.
	restart := store.New(stores[0].Root)
	replay, e := restart.KV.Mutate(ids[0], kv.Mutation{Namespace: "navigation", Key: "projects-folder.f.name", Value: json.RawMessage(`"Research"`), OperationID: "create", DaemonID: ids[0].DaemonID})
	if e != nil || replay.Revision() != original.Revision() {
		t.Fatal(replay, e)
	}
	_, e = restart.KV.Mutate(ids[0], kv.Mutation{Namespace: "navigation", Key: "projects-folder.f.name", Value: json.RawMessage(`"Different"`), OperationID: "create", DaemonID: ids[0].DaemonID})
	if e == nil {
		t.Fatal("reused receipt accepted different input")
	}
	_, e = restart.KV.Mutate(ids[0], kv.Mutation{Namespace: "navigation", Key: "projects-folder.f.name", Value: json.RawMessage(`"Stale"`), OperationID: "stale", DaemonID: ids[0].DaemonID})
	if !errors.Is(e, crdt.ErrConflict) {
		t.Fatal(e)
	}
	_, e = restart.KV.Mutate(ids[0], kv.Mutation{Namespace: "navigation", Key: "projects-folder.g.name", Value: json.RawMessage(`"Wrong daemon"`), OperationID: "wrong", DaemonID: ids[1].DaemonID})
	if e == nil {
		t.Fatal("wrong accepting daemon admitted")
	}
}

func TestKVOrderedMovesRetainNeighborsAndAtomicParent(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	identity, e := s.Replica.EnsureIdentity()
	if e != nil {
		t.Fatal(e)
	}
	move := func(key, rev, parent, after, before, op string) crdt.Record {
		t.Helper()
		r, e := s.KV.Mutate(identity, kv.Mutation{Namespace: "navigation", Key: key, Revision: rev, OperationID: op, DaemonID: identity.DaemonID, Move: &kv.Move{parent, after, before}})
		if e != nil {
			t.Fatal(e)
		}
		return r
	}
	a := move("projects-item.a.position", "", "folder", "", "", "a")
	b := move("projects-item.b.position", "", "folder", "", "", "b")
	c := move("projects-item.c.position", "", "folder", a.ID, b.ID, "c")
	rank := func(r crdt.Record) schema.KVPosition {
		var p schema.KVPosition
		if e := json.Unmarshal(schema.SelectedKV(r).Value, &p); e != nil {
			t.Fatal(e)
		}
		return p
	}
	if !(rank(a).Rank < rank(c).Rank && rank(c).Rank < rank(b).Rank) {
		t.Fatal(a, b, c)
	}
	moved := move(c.ID, c.Revision(), "another", "", "", "move")
	if rank(moved).Parent != "another" {
		t.Fatal(moved)
	}
	data, e := s.Replica.PeerData(identity.Account)
	if e != nil {
		t.Fatal(e)
	}
	if data.Records[crdt.Key(a.Kind, a.ID)].Revision() != a.Revision() || data.Records[crdt.Key(b.Kind, b.ID)].Revision() != b.Revision() {
		t.Fatal("move rewrote neighbors")
	}
}
