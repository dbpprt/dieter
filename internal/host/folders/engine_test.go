package folders_test

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	core "github.com/dbpprt/dieter/internal/folders"
	hostfolders "github.com/dbpprt/dieter/internal/host/folders"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func newEngine(t *testing.T) (*hostfolders.Engine, *store.Store) {
	t.Helper()
	data := testkit.Store(t)
	engine := hostfolders.New(hostfolders.Options{Store: data, Name: "Test desk", Walk: 50 * time.Millisecond, PeerPoll: time.Hour, Supervise: 50 * time.Millisecond, DeleteSettle: 150 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		engine.Run(ctx)
	}()
	t.Cleanup(func() {
		cancel()
		<-done
	})
	return engine, data
}

func create(t *testing.T, engine *hostfolders.Engine, name string) hostfolders.Definition {
	t.Helper()
	definition, err := engine.CreateFolder(hostfolders.DefinitionChange{Name: &name})
	if err != nil {
		t.Fatal(err)
	}
	return definition
}

func kindOf(err error) fault.Kind {
	kind, _ := fault.KindOf(err)
	return kind
}

func put(t *testing.T, dir, path, content string) {
	t.Helper()
	full := filepath.Join(dir, path)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestAttachRefusesLocationsThatAreNotFoldersOfTheirOwn(t *testing.T) {
	ctx := context.Background()
	engine, data := newEngine(t)
	definition := create(t, engine, "Docs")
	checkout := testkit.CheckoutDir(t)
	if _, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Repo", Path: checkout}); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/", "/usr/local/share", data.Root, filepath.Join(data.Root, "folders", "x"), checkout, filepath.Join(checkout, "docs"), "relative/path"} {
		if _, err := engine.Attach(ctx, hostfolders.AttachRequest{FolderID: definition.ID, Path: path}); err == nil {
			t.Errorf("attached %s", path)
		}
	}
	first := filepath.Join(t.TempDir(), "first")
	plan, err := engine.Attach(ctx, hostfolders.AttachRequest{FolderID: definition.ID, Path: first, DryRun: true})
	if err != nil || !plan.DryRun {
		t.Fatalf("dry run = %+v, %v", plan, err)
	}
	if _, err := data.Folders.Member(definition.ID); err == nil {
		t.Fatal("a dry run attached the folder")
	}
	if _, err := engine.Attach(ctx, hostfolders.AttachRequest{FolderID: definition.ID, Path: first, Mode: "sideways"}); err == nil {
		t.Fatal("attached with an invalid mode")
	}
	if _, err := engine.Attach(ctx, hostfolders.AttachRequest{FolderID: definition.ID, Path: first}); err != nil {
		t.Fatal(err)
	}
	other := create(t, engine, "Other")
	if _, err := engine.Attach(ctx, hostfolders.AttachRequest{FolderID: other.ID, Path: filepath.Join(first, "nested")}); err == nil {
		t.Fatal("attached inside another folder's location")
	}
	if _, err := engine.Attach(ctx, hostfolders.AttachRequest{FolderID: definition.ID, Path: t.TempDir()}); kindOf(err) != fault.AlreadyExists {
		t.Fatalf("second attach: %v", err)
	}
	archived := true
	if _, err := engine.UpdateFolder(other.ID, hostfolders.DefinitionChange{Archived: &archived}); err != nil {
		t.Fatal(err)
	}
	if _, err := engine.Attach(ctx, hostfolders.AttachRequest{FolderID: other.ID, Path: t.TempDir()}); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("attach archived: %v", err)
	}
	if _, err := engine.CreateFolder(hostfolders.DefinitionChange{Name: ptr("a/b")}); err == nil {
		t.Fatal("created a folder with a slash in its name")
	}
	bad := []string{"node_modules"}
	if _, err := engine.UpdateFolder(definition.ID, hostfolders.DefinitionChange{Rules: &bad}); err == nil {
		t.Fatal("accepted a rule without + or -")
	}
}

func entryOf(t *testing.T, data *store.Store, folderID, path string) (core.Entry, uint64, bool) {
	t.Helper()
	index, err := data.Folders.Index(folderID)
	if err != nil {
		t.Fatal(err)
	}
	local, ok := index.Get(path)
	return local.Entry, local.Sequence, ok
}

// A scan records new and modified files and directories with this daemon's
// counter, a touch without a content change keeps the version, a deletion is
// recorded once it settled, and a mass deletion waits for a person.
func TestScanRecordsChangesAndHoldsMassDeletions(t *testing.T) {
	ctx := context.Background()
	engine, data := newEngine(t)
	definition := create(t, engine, "Work")
	dir := t.TempDir()
	put(t, dir, "a.txt", "alpha")
	put(t, dir, "sub/b.txt", "beta")
	put(t, dir, ".DS_Store", "ignored")
	if _, err := engine.Attach(ctx, hostfolders.AttachRequest{FolderID: definition.ID, Path: dir}); err != nil {
		t.Fatal(err)
	}
	daemonID, err := engine.DaemonID()
	if err != nil {
		t.Fatal(err)
	}
	actor := core.ActorOf(daemonID)
	testkit.Eventually(t, testkit.Budget(5*time.Second), func() bool {
		_, _, ok := entryOf(t, data, definition.ID, "sub/b.txt")
		return ok
	}, "the first scan")
	a, sequence, _ := entryOf(t, data, definition.ID, "a.txt")
	if a.Version.Get(actor) != 1 || a.AuthorName != "Test desk" || a.Kind != core.KindFile {
		t.Fatalf("a.txt = %+v", a)
	}
	if dir, _, ok := entryOf(t, data, definition.ID, "sub"); !ok || dir.Kind != core.KindDirectory {
		t.Fatal("the directory was not recorded")
	}
	if _, _, ok := entryOf(t, data, definition.ID, ".DS_Store"); ok {
		t.Fatal("a default rule did not exclude .DS_Store")
	}
	// Touch only: same content, new times.
	later := time.Now().Add(time.Hour)
	if err := os.Chtimes(filepath.Join(dir, "a.txt"), later, later); err != nil {
		t.Fatal(err)
	}
	if err := engine.WaitCycle(ctx, definition.ID, true); err != nil {
		t.Fatal(err)
	}
	if touched, seq, _ := entryOf(t, data, definition.ID, "a.txt"); seq != sequence || touched.Version.Get(actor) != 1 {
		t.Fatalf("a touch changed the version: %+v at %d", touched, seq)
	}
	put(t, dir, "a.txt", "alpha 2")
	testkit.Eventually(t, testkit.Budget(5*time.Second), func() bool {
		edited, _, _ := entryOf(t, data, definition.ID, "a.txt")
		return edited.Version.Get(actor) == 2
	}, "the edit to be recorded")
	if err := os.Remove(filepath.Join(dir, "sub", "b.txt")); err != nil {
		t.Fatal(err)
	}
	testkit.Eventually(t, testkit.Budget(5*time.Second), func() bool {
		gone, _, _ := entryOf(t, data, definition.ID, "sub/b.txt")
		return gone.Kind == core.KindDeleted
	}, "the deletion to settle and be recorded")
	for i := range 30 {
		put(t, dir, fmt.Sprintf("many/%02d", i), "x")
	}
	testkit.Eventually(t, testkit.Budget(5*time.Second), func() bool {
		_, _, ok := entryOf(t, data, definition.ID, "many/29")
		return ok
	}, "the bulk files")
	if err := os.RemoveAll(filepath.Join(dir, "many")); err != nil {
		t.Fatal(err)
	}
	testkit.Eventually(t, testkit.Budget(5*time.Second), func() bool {
		return engine.StatusOf(definition.ID).Pending != nil
	}, "the guard to hold the deletions")
	if held, _, _ := entryOf(t, data, definition.ID, "many/05"); held.Kind != core.KindFile {
		t.Fatal("a held deletion was recorded")
	}
	if err := engine.ResolveDeletions(ctx, definition.ID, true); err != nil {
		t.Fatal(err)
	}
	testkit.Eventually(t, testkit.Budget(5*time.Second), func() bool {
		applied, _, _ := entryOf(t, data, definition.ID, "many/05")
		return applied.Kind == core.KindDeleted
	}, "applied deletions")
}

// Directories, deletions and uploads from phones and peers apply only over
// an entry their version dominates; a send-only member accepts none.
func TestRemoteChangesNeedDominatingVersions(t *testing.T) {
	ctx := context.Background()
	engine, data := newEngine(t)
	definition := create(t, engine, "Remote")
	dir := t.TempDir()
	put(t, dir, "doc.txt", "local")
	if _, err := engine.Attach(ctx, hostfolders.AttachRequest{FolderID: definition.ID, Path: dir}); err != nil {
		t.Fatal(err)
	}
	if err := engine.WaitCycle(ctx, definition.ID, true); err != nil {
		t.Fatal(err)
	}
	current, _, _ := entryOf(t, data, definition.ID, "doc.txt")
	phone := core.ActorOf("dev_phone")
	stale := core.Entry{Path: "doc.txt", Kind: core.KindDeleted, Version: core.Version{}.Bump(phone), AuthorID: "dev_phone"}
	if _, err := engine.ApplyEntry(ctx, definition.ID, stale); kindOf(err) != fault.Conflict {
		t.Fatalf("concurrent tombstone: %v", err)
	}
	if _, err := engine.ExpectFolderUpload(ctx, definition.ID, "doc.txt", core.Entry{Path: "doc.txt", Kind: core.KindFile, Size: 1, SHA256: "3333333333333333333333333333333333333333333333333333333333333333", Version: core.Version{}.Bump(phone)}); kindOf(err) != fault.Conflict {
		t.Fatalf("concurrent upload: %v", err)
	}
	newer := core.Entry{Path: "doc.txt", Kind: core.KindDeleted, Version: current.Version.Bump(phone), AuthorID: "dev_phone", AuthorName: "Pixel"}
	if _, err := engine.ApplyEntry(ctx, definition.ID, newer); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "doc.txt")); !os.IsNotExist(err) {
		t.Fatal("the dominating tombstone left the file")
	}
	items, _, _, err := engine.TrashPage(definition.ID, "", 10)
	if err != nil || len(items) != 1 || items[0].DeletedBy != "Pixel" {
		t.Fatalf("trash = %+v, %v", items, err)
	}
	directory := core.Entry{Path: "inbox", Kind: core.KindDirectory, Version: core.Version{}.Bump(phone), AuthorID: "dev_phone"}
	if _, err := engine.ApplyEntry(ctx, definition.ID, directory); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(filepath.Join(dir, "inbox")); err != nil || !info.IsDir() {
		t.Fatal("the directory was not created")
	}
	if _, err := engine.RestoreTrash(ctx, definition.ID, items[0].ID); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(filepath.Join(dir, "doc.txt")); err != nil || string(b) != "local" {
		t.Fatalf("restored %q, %v", b, err)
	}
	restored, _, _ := entryOf(t, data, definition.ID, "doc.txt")
	if core.Compare(restored.Version, newer.Version) != core.After {
		t.Fatalf("the restored version %v does not dominate the tombstone %v", restored.Version, newer.Version)
	}
	sendOnly := core.ModeSendOnly
	if _, err := engine.UpdateMember(ctx, definition.ID, hostfolders.MemberChange{Mode: &sendOnly}); err != nil {
		t.Fatal(err)
	}
	if _, err := engine.ApplyEntry(ctx, definition.ID, core.Entry{Path: "other", Kind: core.KindDirectory, Version: core.Version{}.Bump(phone)}); kindOf(err) != fault.FailedPrecondition {
		t.Fatalf("send-only member applied a remote change: %v", err)
	}
}

// A receive-only member never records a local change; it lists it.
func TestReceiveOnlyListsLocalChanges(t *testing.T) {
	ctx := context.Background()
	engine, data := newEngine(t)
	definition := create(t, engine, "Downloads")
	dir := t.TempDir()
	if _, err := engine.Attach(ctx, hostfolders.AttachRequest{FolderID: definition.ID, Path: dir, Mode: core.ModeReceiveOnly}); err != nil {
		t.Fatal(err)
	}
	put(t, dir, "mine.txt", "local only")
	testkit.Eventually(t, testkit.Budget(5*time.Second), func() bool {
		changes := engine.StatusOf(definition.ID).LocalChanges
		return len(changes) == 1 && changes[0] == "mine.txt"
	}, "the local change to be listed")
	if _, _, ok := entryOf(t, data, definition.ID, "mine.txt"); ok {
		t.Fatal("a receive-only member recorded a local change")
	}
}

func ptr[T any](v T) *T { return &v }
