package replica_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/kv"
	"github.com/dbpprt/dieter/internal/store/replica"
	"github.com/dbpprt/dieter/internal/testkit"
)

// Use a real SQLite history exceeding both former replica limits and both
// former receipt limits. Seeding bypasses fsync-per-operation but stores valid
// causal records, exact revisions, and accurate durable accounting.
func seedPeerCapacity(t *testing.T, s *store.Store, account string) {
	t.Helper()
	db, err := s.Replica.Database(account)
	if err != nil {
		t.Fatal(err)
	}
	tx, err := db.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	insert, err := tx.Prepare("INSERT INTO peer_records(key,revision,sequence,value) VALUES(?,?,?,?)")
	if err != nil {
		t.Fatal(err)
	}
	defer insert.Close()
	var seq uint64
	if err = tx.QueryRow("SELECT sequence FROM peer_metadata WHERE id=1").Scan(&seq); err != nil {
		t.Fatal(err)
	}
	payload := replica.RawValue(strings.Repeat("x", 512))
	for i := 0; i <= crdt.MaxRecords; i++ {
		r := crdt.Record{Kind: "kv.capacity", ID: fmt.Sprintf("r_%06d", i), Versions: []crdt.Version{{Clock: crdt.Clock{"retired_actor": 1}, Value: payload}}}
		raw, _ := json.Marshal(r)
		seq++
		if _, err = insert.Exec(crdt.Key(r.Kind, r.ID), r.Revision(), seq, raw); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = tx.Exec("UPDATE peer_metadata SET sequence=?,record_count=(SELECT count(*) FROM peer_records),record_bytes=(SELECT sum(length(value)) FROM peer_records) WHERE id=1", seq); err != nil {
		t.Fatal(err)
	}
	receipt := crdt.Record{Kind: "kv.capacity", ID: "receipt", Versions: []crdt.Version{{Clock: crdt.Clock{"retired_actor": 1}, Value: replica.RawValue(strings.Repeat("r", 1100))}}}
	raw, _ := json.Marshal(receipt)
	if _, err = tx.Exec("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<65536) INSERT INTO kv_receipts SELECT printf('retained_%06d',x),'retained-fingerprint',? FROM n", raw); err != nil {
		t.Fatal(err)
	}
	if err = tx.Commit(); err != nil {
		t.Fatal(err)
	}
	var records, bytes, receipts, receiptBytes int64
	if err = db.QueryRow("SELECT record_count,record_bytes,(SELECT count(*) FROM kv_receipts),(SELECT sum(length(value)) FROM kv_receipts) FROM peer_metadata WHERE id=1").Scan(&records, &bytes, &receipts, &receiptBytes); err != nil {
		t.Fatal(err)
	}
	if records <= crdt.MaxRecords || bytes <= crdt.MaxStateBytes || receipts <= 65536 || receiptBytes <= 64<<20 {
		t.Fatalf("fixture did not cross every old limit: %d/%d records/bytes %d/%d receipts/bytes", records, bytes, receipts, receiptBytes)
	}
	t.Logf("retained %d records / %d bytes, %d receipts / %d bytes", records, bytes, receipts, receiptBytes)
}

func TestPeerCapacityHistoryDoesNotExhaustWrites(t *testing.T) {
	t.Parallel()
	if os.Getenv("DIETER_PEER_CAPACITY") != "1" {
		t.Skip("set DIETER_PEER_CAPACITY=1 for the above-capacity SQLite qualification")
	}
	root := t.TempDir()
	s := store.New(root)
	identity, err := s.Replica.BindPeerAccount("account", "github:1", "daemon", "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	mutation := kv.Mutation{Namespace: "capacity", Key: "control", OperationID: "first_operation", DaemonID: identity.DaemonID, Value: []byte(`"original"`)}
	original, err := s.KV.Mutate(identity, mutation)
	if err != nil {
		t.Fatal(err)
	}
	seedPeerCapacity(t, s, identity.Account)
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	s = store.New(root)
	defer s.Close()
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	current, err := s.Replica.ReadPeerRecord(t.Context(), identity.Account, "kv.capacity", "r_000000")
	if err != nil {
		t.Fatal(err)
	}
	deleted, err := s.Replica.PutPeerRecord(identity, current.Kind, current.ID, current.Revision(), nil, true)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Replica.MergePeerRecords(identity, []crdt.Record{current}); err != nil {
		t.Fatal(err)
	}
	retained, err := s.Replica.ReadPeerRecord(t.Context(), identity.Account, current.Kind, current.ID)
	if err != nil || retained.Revision() != deleted.Revision() {
		t.Fatalf("stale peer resurrected deletion: %+v %v", retained, err)
	}
	created, err := s.KV.Mutate(identity, kv.Mutation{Namespace: "capacity", Key: "new", OperationID: "new_operation", DaemonID: identity.DaemonID, Value: []byte(`"after exhaustion"`)})
	if err != nil {
		t.Fatal(err)
	}
	if created.ID != "new" {
		t.Fatal(created)
	}
	replay, err := s.KV.Mutate(identity, mutation)
	if err != nil || replay.Revision() != original.Revision() {
		t.Fatalf("old durable receipt lost: %+v %v", replay, err)
	}
	changed := mutation
	changed.Value = []byte(`"different"`)
	if _, err = s.KV.Mutate(identity, changed); err == nil {
		t.Fatal("old operation ID reused with new input")
	}
	stats, err := s.Replica.PeerStoreInfo(t.Context(), identity.Account)
	if err != nil || stats.Records != crdt.MaxRecords+3 {
		t.Fatalf("status: %+v %v", stats, err)
	}
	page, err := s.Replica.ListPeerRecordPage(t.Context(), identity.Account, "kv.capacity", "r_", "", "", nil)
	if err != nil || len(page.Records) != crdt.PageSize || page.NextKey == "" {
		t.Fatalf("bounded snapshot: %+v %v", page, err)
	}
	next, err := s.Replica.ListPeerRecordPage(t.Context(), identity.Account, "kv.capacity", "r_", page.NextKey, page.Revision, nil)
	if err != nil || len(next.Records) != crdt.PageSize || next.Records[0].ID <= page.Records[len(page.Records)-1].ID {
		t.Fatalf("continued snapshot: %v", err)
	}
	runtime.ReadMemStats(&after)
	if allocated := after.TotalAlloc - before.TotalAlloc; allocated > 32<<20 {
		t.Fatalf("small operations loaded retained history: allocated %d bytes", allocated)
	} else {
		t.Logf("cold read/write/replay/status/two pages allocated %d bytes", allocated)
	}
	// SQLite reuses rows; a new write has one latest change, never a history scan.
	changes, err := s.Replica.PeerChanges(identity.Account, "", uint64(crdt.MaxRecords+2))
	if err != nil || len(changes.Records) != 2 {
		t.Fatalf("incremental updates: %+v %v", changes, err)
	}
}

func TestPeerViewBoundsAndRejectsMixedRevisions(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	defer s.Close()
	identity, err := s.Replica.BindPeerAccount("account", "github:1", "daemon", "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	for start := 0; start < 600; start += crdt.PageSize {
		var records []crdt.Record
		for i := start; i < min(start+crdt.PageSize, 600); i++ {
			r, err := crdt.Put(crdt.Record{}, "kv.cache", fmt.Sprintf("r_%04d", i), "actor", "", replica.RawValue(strings.Repeat("x", 30000)), false)
			if err != nil {
				t.Fatal(err)
			}
			records = append(records, r)
		}
		if err = s.Replica.MergePeerRecords(identity, records); err != nil {
			t.Fatal(err)
		}
	}
	view, err := s.Replica.OpenPeerView(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 600; i++ {
		if r := view.Record(crdt.Key("kv.cache", fmt.Sprintf("r_%04d", i))); r.ID == "" {
			t.Fatal(view.Err())
		}
		if records, bytes := view.ViewCache(); records > replica.ViewCacheRecords || bytes > replica.ViewCacheBytes {
			t.Fatal("unbounded cache")
		}
	}
	if _, err = s.Replica.PutPeerRecord(identity, "kv.cache", "later", "", []byte(`1`), false); err != nil {
		t.Fatal(err)
	}
	_ = view.Record("kv.cache/later")
	if !errors.Is(view.Err(), crdt.ErrConflict) {
		t.Fatalf("mixed revisions: %v", view.Err())
	}
	// A stale or failed read cannot acknowledge an otherwise empty write.
	release, err := s.BeginWriteLock()
	if err != nil {
		t.Fatal(err)
	}
	err = s.Replica.SavePeerData(identity.Account, view)
	release()
	if !errors.Is(err, crdt.ErrConflict) {
		t.Fatalf("failed view committed: %v", err)
	}
}

func TestPeerReceiptFailureRollsBackPageAndRecovers(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	defer s.Close()
	identity, err := s.Replica.BindPeerAccount("account", "github:1", "daemon", "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	db, err := s.Replica.Database(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("CREATE TRIGGER fail_receipt BEFORE INSERT ON kv_receipts BEGIN SELECT RAISE(ABORT,'injected receipt failure'); END"); err != nil {
		t.Fatal(err)
	}
	mutation := kv.Mutation{Namespace: "capacity", Key: "atomic", OperationID: "atomic_operation", DaemonID: identity.DaemonID, Value: []byte(`true`)}
	if _, err = s.KV.Mutate(identity, mutation); err == nil {
		t.Fatal("receipt failure acknowledged")
	}
	stats, err := s.Replica.PeerStoreInfo(t.Context(), identity.Account)
	if err != nil || stats.Records != 0 {
		t.Fatalf("partial page: %+v %v", stats, err)
	}
	if _, err = db.Exec("DROP TRIGGER fail_receipt"); err != nil {
		t.Fatal(err)
	}
	first, err := s.KV.Mutate(identity, mutation)
	if err != nil {
		t.Fatal(err)
	}
	second, err := s.KV.Mutate(identity, mutation)
	if err != nil || first.Revision() != second.Revision() {
		t.Fatalf("receipt replay: %+v %v", second, err)
	}
}

func TestPeerTransactionProcessInterruption(t *testing.T) {
	t.Parallel()
	if root := os.Getenv("DIETER_PEER_CRASH_FIXTURE"); root != "" {
		s := store.New(root)
		db, err := s.Replica.Database("account")
		if err != nil {
			t.Fatal(err)
		}
		release, err := s.BeginWriteLock()
		if err != nil {
			t.Fatal(err)
		}
		defer release()
		tx, err := db.Begin()
		if err != nil {
			t.Fatal(err)
		}
		if _, err = tx.Exec("UPDATE peer_metadata SET record_count=999,sequence=999"); err != nil {
			t.Fatal(err)
		}
		if _, err = tx.Exec("DELETE FROM peer_records"); err != nil {
			t.Fatal(err)
		}
		if _, err = tx.Exec("DELETE FROM kv_receipts"); err != nil {
			t.Fatal(err)
		}
		os.Exit(42) // SQLite and the OS release uncommitted state and the central lock.
	}
	s := store.New(t.TempDir())
	identity, err := s.Replica.BindPeerAccount("account", "github:1", "daemon", "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	mutation := kv.Mutation{Namespace: "crash", Key: "retained", OperationID: "retained_operation", DaemonID: identity.DaemonID, Value: []byte(`true`)}
	original, err := s.KV.Mutate(identity, mutation)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Close(); err != nil {
		t.Fatal(err)
	}
	cmd := exec.CommandContext(t.Context(), os.Args[0], "-test.run=^TestPeerTransactionProcessInterruption$")
	cmd.Env = append(os.Environ(), "DIETER_PEER_CRASH_FIXTURE="+s.Root)
	err = cmd.Run()
	var exit *exec.ExitError
	if !errors.As(err, &exit) || exit.ExitCode() != 42 {
		t.Fatalf("crash worker: %v", err)
	}
	s = store.New(s.Root)
	defer s.Close()
	replay, err := s.KV.Mutate(identity, mutation)
	if err != nil || replay.Revision() != original.Revision() {
		t.Fatalf("interruption lost receipt: %+v %v", replay, err)
	}
	stats, err := s.Replica.PeerStoreInfo(context.Background(), identity.Account)
	if err != nil || stats.Records != 1 {
		t.Fatalf("interrupted accounting: %+v %v", stats, err)
	}
	if _, err = s.Replica.PutPeerRecord(identity, "kv.crash", "after", "", []byte(`true`), false); err != nil {
		t.Fatal(err)
	}
}

func TestPeerRetentionKeepsConcurrentDeleteAndActorHistory(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	defer s.Close()
	identity, err := s.Replica.BindPeerAccount("account", "github:1", "daemon", "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	old, err := s.Replica.PutPeerRecord(identity, "kv.retention", "offline", "", []byte(`"old"`), false)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Replica.PutPeerRecord(identity, old.Kind, old.ID, old.Revision(), nil, true)
	if err != nil {
		t.Fatal(err)
	}
	edited, err := crdt.Put(old, old.Kind, old.ID, "long_offline_actor", old.Revision(), []byte(`"offline edit"`), false)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.Replica.MergePeerRecords(identity, []crdt.Record{edited}); err != nil {
		t.Fatal(err)
	}
	conflict, err := s.Replica.ReadPeerRecord(t.Context(), identity.Account, old.Kind, old.ID)
	if err != nil || len(conflict.Versions) != 2 || !schema.SelectedKV(conflict).Deleted {
		t.Fatalf("conflict lost: %+v %v", conflict, err)
	}
	resolved, err := s.Replica.PutPeerRecord(identity, old.Kind, old.ID, conflict.Revision(), []byte(`"intentional restore"`), false)
	if err != nil {
		t.Fatal(err)
	}
	if len(resolved.Versions) != 1 || resolved.Versions[0].Clock["long_offline_actor"] == 0 {
		t.Fatal("discarded old actor frontier")
	}
	if err = s.Replica.MergePeerRecords(identity, []crdt.Record{edited, old}); err != nil {
		t.Fatal(err)
	}
	after, err := s.Replica.ReadPeerRecord(t.Context(), identity.Account, old.Kind, old.ID)
	if err != nil || after.Revision() != resolved.Revision() {
		t.Fatalf("old frontier resurrected: %+v %v", after, err)
	}
}

func TestPeerPagedAdoptionResumesWithSameActor(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	defer s.Close()
	p, err := s.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Repo", Path: testkit.ProjectDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := s.Kanban.CreateChat(kanban.CreateCardInput{Project: p.ID, Title: "Keep owner", WorkspaceMode: "project"})
	if err != nil {
		t.Fatal(err)
	}
	identity, err := s.Replica.PeerIdentity()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 70; i++ {
		if _, err = s.Replica.PutPeerRecord(identity, "kv.adoption", fmt.Sprintf("r_%03d", i), "", []byte(`true`), false); err != nil {
			t.Fatal(err)
		}
	}
	db, err := s.Replica.Database("account")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = db.Exec("CREATE TRIGGER fail_adoption BEFORE INSERT ON peer_records WHEN new.key='kv.adoption/r_060' BEGIN SELECT RAISE(ABORT,'injected late page failure'); END"); err != nil {
		t.Fatal(err)
	}
	pending, err := s.Replica.BindPeerAccount("account", "github:1", "machine_a", "https://gateway.test")
	if err == nil {
		t.Fatal("expected failed adoption")
	}
	var count int
	if err = db.QueryRow("SELECT count(*) FROM peer_records").Scan(&count); err != nil || count == 0 {
		t.Fatalf("no committed first page: %d %v", count, err)
	}
	if _, err = db.Exec("DROP TRIGGER fail_adoption"); err != nil {
		t.Fatal(err)
	}
	resumed, err := s.Replica.BindPeerAccount("account", "github:1", "machine_a", "https://gateway.test")
	if err != nil || resumed.Actor != pending.Actor {
		t.Fatalf("retry changed adoption actor: %+v %+v %v", pending, resumed, err)
	}
	card, err := s.Kanban.CardDetail(chat.ID)
	if err != nil || card.Card.OwnerDaemonID != "machine_a" || len(card.Card.ConflictKeys) > 0 {
		t.Fatalf("retry corrupted identity: %+v %v", card, err)
	}
}

func TestPeerSnapshotPinsRevisionAcrossConcurrentWritesAndNestedReads(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	defer s.Close()
	identity, err := s.Replica.BindPeerAccount("account", "github:1", "daemon", "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"first", "second"} {
		if _, err := s.Replica.PutPeerRecord(identity, "kv.snapshot", id, "", []byte(`"old"`), false); err != nil {
			t.Fatal(err)
		}
	}
	view, err := s.Replica.OpenPeerSnapshot(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	defer view.Close()
	first := view.Record("kv.snapshot/first")
	if _, err = s.Replica.PutPeerRecord(identity, first.Kind, first.ID, first.Revision(), []byte(`"new"`), false); err != nil {
		t.Fatal(err)
	}
	second, err := s.Replica.ReadPeerRecord(t.Context(), identity.Account, "kv.snapshot", "second")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Replica.PutPeerRecord(identity, second.Kind, second.ID, second.Revision(), []byte(`"new"`), false); err != nil {
		t.Fatal(err)
	}
	// A previously unread dependency and an evicted cache entry must both use
	// the original snapshot, even while the writer and nested projections run.
	view.ClearViewCache()
	count := 0
	if err = view.Each("kv.snapshot/", func(record crdt.Record) error {
		count++
		if string(schema.SelectedKV(record).Value) != `"old"` {
			t.Fatal("snapshot mixed revisions")
		}
		nested, err := s.Replica.OpenPeerSnapshot(identity.Account)
		if err != nil {
			return err
		}
		defer nested.Close()
		if string(schema.SelectedKV(nested.Record(crdt.Key(record.Kind, record.ID))).Value) != `"new"` {
			t.Fatal("nested snapshot did not see committed write")
		}
		return nested.Err()
	}); err != nil || count != 2 {
		t.Fatalf("snapshot page: count=%d err=%v", count, err)
	}
	if string(schema.SelectedKV(view.Record("kv.snapshot/second")).Value) != `"old"` || view.Err() != nil {
		t.Fatalf("snapshot point read: %v", view.Err())
	}
	// Pinning a read never permits committing a stale mutation baseline.
	release, err := s.BeginWriteLock()
	if err != nil {
		t.Fatal(err)
	}
	err = s.Replica.SavePeerData(identity.Account, view)
	release()
	if !errors.Is(err, crdt.ErrConflict) {
		t.Fatalf("stale snapshot committed: %v", err)
	}
	view.Close()
	if inUse := s.Replica.ReadPoolInUse(identity.Account); inUse != 0 {
		t.Fatalf("snapshot leaked %d connections", inUse)
	}
}

func TestPeerSnapshotAdmissionReleasesCapacity(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	defer s.Close()
	identity, err := s.Replica.BindPeerAccount("account", "github:1", "daemon", "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	var views []replica.PeerData
	defer func() {
		for _, view := range views {
			view.Close()
		}
	}()
	for range s.Replica.SnapshotSlots() {
		view, err := s.Replica.OpenPeerSnapshot(identity.Account)
		if err != nil {
			t.Fatal(err)
		}
		views = append(views, view)
	}
	if _, err := s.Replica.OpenPeerSnapshot(identity.Account); !errors.Is(err, crdt.ErrCapacity) {
		t.Fatalf("snapshot admission did not enforce its bound: %v", err)
	}
	views[0].Close()
	replacement, err := s.Replica.OpenPeerSnapshot(identity.Account)
	if err != nil {
		t.Fatalf("closed snapshot did not release capacity: %v", err)
	}
	replacement.Close()
}
