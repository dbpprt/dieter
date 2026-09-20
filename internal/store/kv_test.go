package store

import (
	"encoding/json"
	"errors"
	"fmt"
	"testing"

	"github.com/dbpprt/dieter/internal/peerstore"
)

func TestKVReplicationReceiptsAndDeletion(t *testing.T) {
	stores := []*Store{New(t.TempDir()), New(t.TempDir()), New(t.TempDir())}
	ids := make([]PeerIdentity, 3)
	for i, s := range stores {
		var err error
		ids[i], err = s.BindPeerAccount("account", "github:1", fmt.Sprint("daemon", i), "https://gateway.test")
		if err != nil {
			t.Fatal(err)
		}
	}
	write := func(i int, key, revision, value, op string, deleted bool) peerstore.Record {
		t.Helper()
		r, e := stores[i].MutateKV(ids[i], KVMutation{Namespace: "navigation", Key: key, Revision: revision, Value: json.RawMessage(value), OperationID: op, DaemonID: ids[i].DaemonID, Delete: deleted})
		if e != nil {
			t.Fatal(e)
		}
		return r
	}
	join := func(from, to int) {
		t.Helper()
		data, e := stores[from].PeerData(ids[from].Account)
		if e != nil {
			t.Fatal(e)
		}
		if e = stores[to].MergePeerRecords(ids[to], data.Sorted()); e != nil {
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
		data, e := s.PeerData(ids[i].Account)
		if e != nil {
			t.Fatal(e)
		}
		r := data.Records["kv.navigation/projects-folder.f.name"]
		if len(r.Versions) != 2 || !peerstore.SelectedKV(r).Deleted {
			t.Fatal(r)
		}
		next := peerstore.Revision(data.State)
		if hash != "" && hash != next {
			t.Fatal("replicas diverged")
		}
		hash = next
	}
	// A lost acknowledgement retried after restart returns the original admission,
	// even after newer edits and joins, without resurrecting the folder.
	restart := New(stores[0].Root)
	replay, e := restart.MutateKV(ids[0], KVMutation{Namespace: "navigation", Key: "projects-folder.f.name", Value: json.RawMessage(`"Research"`), OperationID: "create", DaemonID: ids[0].DaemonID})
	if e != nil || replay.Revision() != original.Revision() {
		t.Fatal(replay, e)
	}
	_, e = restart.MutateKV(ids[0], KVMutation{Namespace: "navigation", Key: "projects-folder.f.name", Value: json.RawMessage(`"Different"`), OperationID: "create", DaemonID: ids[0].DaemonID})
	if e == nil {
		t.Fatal("reused receipt accepted different input")
	}
	_, e = restart.MutateKV(ids[0], KVMutation{Namespace: "navigation", Key: "projects-folder.f.name", Value: json.RawMessage(`"Stale"`), OperationID: "stale", DaemonID: ids[0].DaemonID})
	if !errors.Is(e, peerstore.ErrConflict) {
		t.Fatal(e)
	}
	_, e = restart.MutateKV(ids[0], KVMutation{Namespace: "navigation", Key: "projects-folder.g.name", Value: json.RawMessage(`"Wrong daemon"`), OperationID: "wrong", DaemonID: ids[1].DaemonID})
	if e == nil {
		t.Fatal("wrong accepting daemon admitted")
	}
}

func TestKVOrderedMovesRetainNeighborsAndAtomicParent(t *testing.T) {
	s := New(t.TempDir())
	identity, e := s.KVIdentity()
	if e != nil {
		t.Fatal(e)
	}
	move := func(key, rev, parent, after, before, op string) peerstore.Record {
		t.Helper()
		r, e := s.MutateKV(identity, KVMutation{Namespace: "navigation", Key: key, Revision: rev, OperationID: op, DaemonID: identity.DaemonID, Move: &KVMove{parent, after, before}})
		if e != nil {
			t.Fatal(e)
		}
		return r
	}
	a := move("projects-item.a.position", "", "folder", "", "", "a")
	b := move("projects-item.b.position", "", "folder", "", "", "b")
	c := move("projects-item.c.position", "", "folder", a.ID, b.ID, "c")
	rank := func(r peerstore.Record) peerstore.KVPosition {
		var p peerstore.KVPosition
		if e := json.Unmarshal(peerstore.SelectedKV(r).Value, &p); e != nil {
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
	data, e := s.PeerData(identity.Account)
	if e != nil {
		t.Fatal(e)
	}
	if data.Records[peerstore.Key(a.Kind, a.ID)].Revision() != a.Revision() || data.Records[peerstore.Key(b.Kind, b.ID)].Revision() != b.Revision() {
		t.Fatal("move rewrote neighbors")
	}
}
