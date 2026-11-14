package folders_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	core "github.com/dbpprt/dieter/internal/folders"
	"github.com/dbpprt/dieter/internal/store"
	sf "github.com/dbpprt/dieter/internal/store/folders"
)

func attached(t *testing.T) (*store.Store, sf.Member) {
	t.Helper()
	data := store.New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	var member sf.Member
	err := data.Folders.WithLock(context.Background(), func() error {
		var err error
		member, err = data.Folders.AttachLocked(sf.Member{FolderID: "fo_test", Path: t.TempDir(), Mode: core.ModeTwoWay})
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return data, member
}

func file(path, sha string, version core.Version) sf.Local {
	return sf.Local{Entry: core.Entry{Path: path, Kind: core.KindFile, Size: 1, SHA256: sha, Version: version}, Revision: "rev-" + path}
}

var (
	shaA = "1111111111111111111111111111111111111111111111111111111111111111"
	shaB = "2222222222222222222222222222222222222222222222222222222222222222"
	v1   = core.Version{{Actor: "aaaaaaaaaaaaaaaa", Value: 1}}
	v2   = core.Version{{Actor: "aaaaaaaaaaaaaaaa", Value: 2}}
)

// The index survives a reopen, pages by sequence without stale slots, keeps
// touches without new sequences, recovers from a torn last line and
// compacts; tombstones every member fetched are forgotten.
func TestIndexPersistsPagesTouchesRecoversAndForgets(t *testing.T) {
	ctx := context.Background()
	data, member := attached(t)
	if member.IndexID == "" || member.RescanSeconds != sf.DefaultRescanSeconds || member.Concurrency != sf.DefaultConcurrency {
		t.Fatalf("member defaults = %+v", member)
	}
	out, err := data.Folders.Commit(ctx, member.FolderID, []sf.Local{file("a", shaA, v1), file("b", shaA, v1)})
	if err != nil || len(out) != 2 || out[0].Sequence != 1 || out[1].Sequence != 2 {
		t.Fatalf("commit = %+v, %v", out, err)
	}
	if _, err := data.Folders.Commit(ctx, member.FolderID, []sf.Local{file("a", shaB, v2)}); err != nil {
		t.Fatal(err)
	}
	index, err := data.Folders.Index(member.FolderID)
	if err != nil {
		t.Fatal(err)
	}
	page, last, more := index.Page(0, 10)
	if len(page) != 2 || page[0].Path != "b" || page[1].Path != "a" || last != 3 || more {
		t.Fatalf("page = %+v last %d more %v", page, last, more)
	}
	if page, last, more = index.Page(0, 1); len(page) != 1 || last != 2 || !more {
		t.Fatalf("first page = %+v last %d more %v", page, last, more)
	}
	touched := page[0]
	touched.Revision = "rev-touched"
	if err := data.Folders.WithLock(ctx, func() error { return data.Folders.TouchLocked(member.FolderID, []sf.Local{touched}) }); err != nil {
		t.Fatal(err)
	}
	// A crash leaves half a line at the end of the log.
	logPath := filepath.Join(data.Root, "folders", member.FolderID, "index", "log.jsonl")
	f, err := os.OpenFile(logPath, os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(`{"path":"torn","kind":"fi`); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()
	reopened := store.New(data.Root)
	again, err := reopened.Folders.Index(member.FolderID)
	if err != nil {
		t.Fatal(err)
	}
	if again.Head() != 3 || again.Len() != 2 {
		t.Fatalf("reopened head %d len %d", again.Head(), again.Len())
	}
	if b, _ := again.Get("b"); b.Revision != "rev-touched" || b.Sequence != 2 {
		t.Fatalf("touched entry = %+v", b)
	}
	if a, _ := again.Get("a"); a.SHA256 != shaB || a.Sequence != 3 {
		t.Fatalf("replaced entry = %+v", a)
	}
	if _, ok := again.Get("torn"); ok {
		t.Fatal("a torn line was applied")
	}
	// Tombstones fetched by everyone go; live entries stay.
	tombstone := sf.Local{Entry: core.Entry{Path: "b", Kind: core.KindDeleted, Version: v2}}
	if _, err := reopened.Folders.Commit(ctx, member.FolderID, []sf.Local{tombstone}); err != nil {
		t.Fatal(err)
	}
	if err := reopened.Folders.WithLock(ctx, func() error {
		removed, err := reopened.Folders.ForgetLocked(member.FolderID, 4, time.Now().Add(-time.Hour))
		if removed != 1 {
			t.Errorf("forgot %d tombstones", removed)
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	final := store.New(data.Root)
	index, err = final.Folders.Index(member.FolderID)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := index.Get("b"); ok || index.Len() != 1 || index.Head() != 4 {
		t.Fatalf("after forgetting: len %d head %d", index.Len(), index.Head())
	}
}

func TestTrashCheckpointsClientsAndDetach(t *testing.T) {
	ctx := context.Background()
	data, member := attached(t)
	if err := os.MkdirAll(data.Folders.TrashDir(member.FolderID), 0o700); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-48 * time.Hour).UTC().Format(time.RFC3339Nano)
	for _, item := range []sf.TrashItem{{ID: "tr_old", Path: "x", Size: 5, DeletedAt: old, Reason: "deleted"}, {ID: "tr_new", Path: "y", Size: 5, DeletedAt: time.Now().UTC().Format(time.RFC3339Nano), Reason: "replaced"}} {
		if err := os.WriteFile(filepath.Join(data.Folders.TrashDir(member.FolderID), item.ID), []byte("12345"), 0o600); err != nil {
			t.Fatal(err)
		}
		if err := data.Folders.WithLock(ctx, func() error { return data.Folders.AddTrashLocked(member.FolderID, item) }); err != nil {
			t.Fatal(err)
		}
	}
	if items, err := data.Folders.Trash(member.FolderID); err != nil || len(items) != 2 || items[0].ID != "tr_new" {
		t.Fatalf("trash = %+v, %v", items, err)
	}
	if err := data.Folders.WithLock(ctx, func() error {
		return data.Folders.SweepTrashLocked(member.FolderID, 24*time.Hour, 1<<20, time.Now())
	}); err != nil {
		t.Fatal(err)
	}
	if items, _ := data.Folders.Trash(member.FolderID); len(items) != 1 || items[0].ID != "tr_new" {
		t.Fatalf("after sweep = %+v", items)
	}
	if _, err := os.Stat(filepath.Join(data.Folders.TrashDir(member.FolderID), "tr_old")); !os.IsNotExist(err) {
		t.Fatal("swept payload remains")
	}
	checkpoint := sf.Checkpoint{IndexID: "ix_peer", Sequence: 7}
	if err := data.Folders.WithLock(ctx, func() error { return data.Folders.SaveCheckpointLocked(member.FolderID, "d_peer", checkpoint) }); err != nil {
		t.Fatal(err)
	}
	if got, err := data.Folders.Checkpoint(member.FolderID, "d_peer"); err != nil || got != checkpoint {
		t.Fatalf("checkpoint = %+v, %v", got, err)
	}
	if err := data.Folders.WithLock(ctx, func() error {
		return data.Folders.UpdatePeersLocked(member.FolderID, func(acks map[string]sf.Ack, clients []sf.Client) ([]sf.Client, error) {
			acks["dev_phone"] = sf.Ack{IndexID: member.IndexID, Sequence: 3}
			return append(clients, sf.Client{DeviceID: "dev_phone", Mode: core.ModeTwoWay}), nil
		})
	}); err != nil {
		t.Fatal(err)
	}
	if clients, _ := data.Folders.Clients(member.FolderID); len(clients) != 1 {
		t.Fatalf("clients = %+v", clients)
	}
	if err := data.Folders.WithLock(ctx, func() error { return data.Folders.DetachLocked(member.FolderID) }); err != nil {
		t.Fatal(err)
	}
	if _, err := data.Folders.Member(member.FolderID); !errors.Is(err, sf.ErrNotAttached) {
		t.Fatalf("after detach: %v", err)
	}
	if _, err := os.Stat(member.Path); err != nil {
		t.Fatal("detach touched the member's directory")
	}
}
