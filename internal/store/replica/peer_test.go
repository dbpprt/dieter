package replica_test

import (
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/store"
)

func TestPeerPersistenceAtomicConflictAndAccountIsolation(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	a, e := s.Replica.BindPeerAccount("account-a", "github:1", "daemon-a", "https://gateway.test")
	if e != nil {
		t.Fatal(e)
	}
	original, e := s.Replica.PutPeerRecord(a, "project-settings", "id", "", []byte(`{"name":"Initial"}`), false)
	if e != nil {
		t.Fatal(e)
	}
	var wg sync.WaitGroup
	success := make(chan bool, 2)
	for n := 0; n < 2; n++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := s.Replica.PutPeerRecord(a, "project-settings", "id", original.Revision(), []byte(`{"name":"Updated"}`), false)
			success <- err == nil
		}()
	}
	wg.Wait()
	close(success)
	count := 0
	for ok := range success {
		if ok {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("%d stale writers succeeded", count)
	}
	restarted := store.New(s.Root)
	data, e := restarted.Replica.PeerData(a.Account)
	if e != nil || len(data.Records) != 1 {
		t.Fatal(data, e)
	}
	stat, e := os.Stat(filepath.Join(s.Root, "peers", "identity.json"))
	if e != nil || stat.Mode().Perm() != 0600 {
		t.Fatal(stat, e)
	}
	b, e := s.Replica.BindPeerAccount("account-b", "github:2", "daemon-b", "https://gateway.test")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.Replica.PutPeerRecord(a, "project-settings", "id", "", []byte(`{}`), false); e == nil {
		t.Fatal("stale account wrote")
	}
	empty, e := s.Replica.PeerData(b.Account)
	if e != nil || len(empty.Records) != 0 {
		t.Fatal(empty, e)
	}
}
func TestPeerMergePageIsAtomic(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	identity, e := s.Replica.BindPeerAccount("account", "github:1", "daemon", "https://gateway.test")
	if e != nil {
		t.Fatal(e)
	}
	good, e := crdt.Put(crdt.Record{}, "project-settings", "ok", "a", "", []byte(`{}`), false)
	if e != nil {
		t.Fatal(e)
	}
	bad := good
	bad.ID = "bad"
	bad.Versions = nil
	if e = s.Replica.MergePeerRecords(identity, []crdt.Record{good, bad}); e == nil {
		t.Fatal("bad page accepted")
	}
	data, e := s.Replica.PeerData(identity.Account)
	if e != nil || len(data.Records) != 0 {
		t.Fatal(data, e)
	}
}

func TestPeerProgressDoesNotRewriteReplica(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	identity, err := s.Replica.BindPeerAccount("a", "github:1", "d", "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Replica.PeerSynced(identity, "remote", "webrtc-direct"); err != nil {
		t.Fatal(err)
	}
	empty, err := s.Replica.PeerData("a")
	if err != nil || empty.LastRoute != "webrtc-direct" {
		t.Fatal(empty, err)
	}
	if _, err = s.Replica.PutPeerRecord(identity, "project-settings", "p", "", []byte(`{}`), false); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(s.Replica.Path("a"))
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Replica.PeerSynced(identity, "remote", "webrtc-turn"); err != nil {
		t.Fatal(err)
	}
	after, err := os.Stat(s.Replica.Path("a"))
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, after) {
		t.Fatal("idle sync replaced the replica file")
	}
	data, err := s.Replica.PeerData("a")
	if err != nil || data.LastRoute != "webrtc-turn" || len(data.Records) != 1 {
		t.Fatal(data, err)
	}
}
