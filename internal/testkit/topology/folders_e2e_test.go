//go:build e2e

package topology_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	"github.com/dbpprt/dieter/internal/daemon"
	core "github.com/dbpprt/dieter/internal/folders"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	hostfolders "github.com/dbpprt/dieter/internal/host/folders"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/peersync"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/testkit/topology"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

type folderMachine struct {
	name   string
	daemon *topology.Daemon
	engine *hostfolders.Engine
	dir    string
}

// startFolderMachine runs a daemon whose synced folder engine reaches its
// peers through the gateway exactly as in production, with short intervals.
func startFolderMachine(t *testing.T, ctx context.Context, g *topology.Gateway, name string, direct bool) *folderMachine {
	t.Helper()
	identity := topology.Machine(t, g, name, 42)
	data := store.New(identity.Root)
	machine := &folderMachine{name: name, dir: filepath.Join(t.TempDir(), "folder")}
	runner := &testkit.FakeRunner{}
	options := topology.DaemonOptions{Name: name, Identity: identity, Store: data, Direct: direct, API: api.Options{Runner: runner, Catalog: testkit.MockCatalog()}}
	// The engine is created before the daemon so the API serves it; it
	// learns the daemon's device trust once the daemon started.
	var trusted *topology.Daemon
	engine := hostfolders.New(hostfolders.Options{
		Store: data, Name: name, PeerPoll: 150 * time.Millisecond, Walk: 150 * time.Millisecond, Supervise: 100 * time.Millisecond, DeleteSettle: time.Second,
		Dial: func(ctx context.Context, daemonID string) (dieterclient.Client, func(), error) {
			return daemon.FolderPeerDialer(identity, trusted.Trust)(ctx, daemonID)
		},
	})
	options.API.Folders = engine
	machine.daemon = topology.StartDaemon(t, g, options)
	trusted = machine.daemon
	machine.engine = engine
	scope := crdt.Revision([]string{identity.Issuer(), "github:42"})
	if _, err := data.Replica.BindPeerAccount(scope, "github:42", identity.ID, identity.Issuer()); err != nil {
		t.Fatal(err)
	}
	runCtx, stop := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		engine.Run(runCtx)
	}()
	t.Cleanup(func() {
		stop()
		<-done
	})
	return machine
}

// syncRecords replicates shared records (folder definitions and membership)
// between the machines in the background, as peer sync does in a daemon.
func syncRecords(t *testing.T, ctx context.Context, machines ...*folderMachine) {
	t.Helper()
	ctx, stop := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for ctx.Err() == nil {
			for _, m := range machines {
				syncer := &peersync.PeerSync{Identity: m.daemon.Identity, Trust: m.daemon.Trust, Store: m.daemon.Store}
				round, cancel := context.WithTimeout(ctx, 20*time.Second)
				_ = syncer.Round(round)
				cancel()
			}
			select {
			case <-ctx.Done():
			case <-time.After(200 * time.Millisecond):
			}
		}
	}()
	t.Cleanup(func() {
		stop()
		<-done
	})
}

func writeFile(t *testing.T, dir, path, content string, modified time.Time) {
	t.Helper()
	full := filepath.Join(dir, path)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	if !modified.IsZero() {
		if err := os.Chtimes(full, modified, modified); err != nil {
			t.Fatal(err)
		}
	}
}

func readFile(dir, path string) (string, bool) {
	b, err := os.ReadFile(filepath.Join(dir, path))
	return string(b), err == nil
}

func waitContent(t *testing.T, timeout time.Duration, dir, path, want string) {
	t.Helper()
	testkit.Eventually(t, testkit.Budget(timeout), func() bool {
		got, ok := readFile(dir, path)
		return ok && got == want
	}, "%s in %s to be %q", path, dir, want)
}

func waitGone(t *testing.T, timeout time.Duration, dir, path string) {
	t.Helper()
	testkit.Eventually(t, testkit.Budget(timeout), func() bool {
		_, ok := readFile(dir, path)
		return !ok
	}, "%s in %s to be deleted", path, dir)
}

func conflictCopies(dir string) []string {
	var out []string
	_ = filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err == nil && !info.IsDir() && strings.Contains(info.Name(), " (conflict, ") {
			rel, _ := filepath.Rel(dir, path)
			out = append(out, rel)
		}
		return nil
	})
	return out
}

func pause(t *testing.T, ctx context.Context, m *folderMachine, folderID string, paused bool) {
	t.Helper()
	if _, err := m.engine.UpdateMember(ctx, folderID, hostfolders.MemberChange{Paused: &paused}); err != nil {
		t.Fatal(err)
	}
}

// Two daemons keep a folder the same through the gateway: new files and
// edits travel both ways, a replaced version lands in the trash, concurrent
// edits keep exactly one conflict copy everywhere, a deletion travels and can
// be restored, and a mass deletion waits for a person.
func TestSyncedFoldersConvergeBetweenDaemons(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(t.Context(), testkit.Budget(4*time.Minute))
	defer cancel()
	g := topology.StartGateway(t, topology.GatewayOptions{})
	a := startFolderMachine(t, ctx, g, "Folder desk A", false)
	b := startFolderMachine(t, ctx, g, "Folder desk B", true)
	syncRecords(t, ctx, a, b)

	definition, err := a.engine.CreateFolder(hostfolders.DefinitionChange{Name: ptr("Inbox")})
	if err != nil {
		t.Fatal(err)
	}
	writeFile(t, a.dir, "notes/plan.md", "plan v1", time.Time{})
	if _, err := a.engine.Attach(ctx, hostfolders.AttachRequest{FolderID: definition.ID, Path: a.dir}); err != nil {
		t.Fatal(err)
	}
	testkit.Eventually(t, testkit.Budget(30*time.Second), func() bool {
		_, err := b.engine.Definition(definition.ID)
		return err == nil
	}, "B to learn the folder")
	// B joins with a file of its own; merge keeps both.
	writeFile(t, b.dir, "from-b.txt", "hello from B", time.Time{})
	if _, err := b.engine.Attach(ctx, hostfolders.AttachRequest{FolderID: definition.ID, Path: b.dir}); err != nil {
		t.Fatal(err)
	}
	waitContent(t, 60*time.Second, b.dir, "notes/plan.md", "plan v1")
	waitContent(t, 60*time.Second, a.dir, "from-b.txt", "hello from B")

	// An edit on B replaces A's copy; A keeps the old version in its trash.
	writeFile(t, b.dir, "notes/plan.md", "plan v2", time.Time{})
	waitContent(t, 60*time.Second, a.dir, "notes/plan.md", "plan v2")
	testkit.Eventually(t, testkit.Budget(10*time.Second), func() bool {
		trash, _, _, err := a.engine.TrashPage(definition.ID, "", 100)
		return err == nil && len(trash) == 1 && trash[0].Path == "notes/plan.md" && trash[0].Reason == "replaced"
	}, "A to keep the replaced version in its trash")

	// Concurrent edits while both are paused: the later one keeps the name and
	// the earlier one becomes the same conflict copy on both machines.
	writeFile(t, a.dir, "shared.txt", "base", time.Time{})
	waitContent(t, 60*time.Second, b.dir, "shared.txt", "base")
	pause(t, ctx, a, definition.ID, true)
	pause(t, ctx, b, definition.ID, true)
	early := time.Now().Add(-time.Hour).Truncate(time.Second)
	writeFile(t, a.dir, "shared.txt", "edited on A", early)
	writeFile(t, b.dir, "shared.txt", "edited on B", early.Add(time.Minute))
	pause(t, ctx, a, definition.ID, false)
	pause(t, ctx, b, definition.ID, false)
	waitContent(t, 90*time.Second, a.dir, "shared.txt", "edited on B")
	copyName := core.ConflictName("shared.txt", "Folder desk A", early.UnixNano())
	waitContent(t, 90*time.Second, a.dir, copyName, "edited on A")
	waitContent(t, 90*time.Second, b.dir, copyName, "edited on A")
	if got := conflictCopies(a.dir); len(got) != 1 {
		t.Fatalf("A's conflict copies = %v", got)
	}
	if got := conflictCopies(b.dir); len(got) != 1 {
		t.Fatalf("B's conflict copies = %v", got)
	}

	// A deletion travels; B keeps the file in its trash and restores it.
	if err := os.Remove(filepath.Join(a.dir, "from-b.txt")); err != nil {
		t.Fatal(err)
	}
	waitGone(t, 60*time.Second, b.dir, "from-b.txt")
	var restoreID string
	testkit.Eventually(t, testkit.Budget(10*time.Second), func() bool {
		trash, _, _, err := b.engine.TrashPage(definition.ID, "", 100)
		for _, item := range trash {
			if err == nil && item.Path == "from-b.txt" && item.Reason == "deleted" {
				restoreID = item.ID
			}
		}
		return restoreID != ""
	}, "B to keep the deleted file in its trash")
	if _, err := b.engine.RestoreTrash(ctx, definition.ID, restoreID); err != nil {
		t.Fatal(err)
	}
	waitContent(t, 60*time.Second, a.dir, "from-b.txt", "hello from B")

	// Deleting most of the folder on A holds the deletions; restoring brings
	// the files back from B, and nothing was deleted on B.
	// More files than one commit batch (64), so concurrent transfers flush.
	for i := range 80 {
		writeFile(t, a.dir, fmt.Sprintf("bulk/%02d.txt", i), fmt.Sprintf("bulk %d", i), time.Time{})
	}
	waitContent(t, 60*time.Second, b.dir, "bulk/79.txt", "bulk 79")
	if err := os.RemoveAll(filepath.Join(a.dir, "bulk")); err != nil {
		t.Fatal(err)
	}
	testkit.Eventually(t, testkit.Budget(30*time.Second), func() bool {
		status := a.engine.StatusOf(definition.ID)
		return status.Pending != nil && status.Pending.Source == "local"
	}, "A to hold the mass deletion")
	if _, ok := readFile(b.dir, "bulk/05.txt"); !ok {
		t.Fatal("a held deletion reached B")
	}
	if err := a.engine.ResolveDeletions(ctx, definition.ID, false); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(testkit.Budget(60 * time.Second))
	for {
		if got, ok := readFile(a.dir, "bulk/05.txt"); ok && got == "bulk 5" {
			break
		}
		if time.Now().After(deadline) {
			status := a.engine.StatusOf(definition.ID)
			t.Fatalf("bulk/05.txt was not restored on A; status %s %q pending=%+v errors=%+v", status.State, status.Detail, status.Pending, status.Errors)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// A phone member uploads through its home daemon with a version, reads by
// content hash, and the change reaches the other daemon. A stale version is
// refused, and the daemon never accepts a phone's registration for another
// device.
func TestPhoneMemberUploadsThroughItsHomeDaemon(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(t.Context(), testkit.Budget(3*time.Minute))
	defer cancel()
	g := topology.StartGateway(t, topology.GatewayOptions{})
	a := startFolderMachine(t, ctx, g, "Phone home A", false)
	b := startFolderMachine(t, ctx, g, "Phone peer B", false)
	syncRecords(t, ctx, a, b)
	definition, err := a.engine.CreateFolder(hostfolders.DefinitionChange{Name: ptr("Phone inbox")})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := a.engine.Attach(ctx, hostfolders.AttachRequest{FolderID: definition.ID, Path: a.dir}); err != nil {
		t.Fatal(err)
	}
	testkit.Eventually(t, testkit.Budget(30*time.Second), func() bool {
		_, err := b.engine.Definition(definition.ID)
		return err == nil
	}, "B to learn the folder")
	if _, err := b.engine.Attach(ctx, hostfolders.AttachRequest{FolderID: definition.ID, Path: b.dir}); err != nil {
		t.Fatal(err)
	}

	phone := topology.StartClient(t, g, a.daemon, "Pixel test")
	conn := topology.DialDaemon(t, phone, a.daemon, topology.Tunnel)
	client := dieterclient.New(conn)
	if _, err := client.RegisterFolderClient(ctx, &dieterv1.RegisterFolderClientRequest{FolderId: definition.ID, DeviceId: "someone-else", Name: "Pixel"}); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("registering another device: %v", err)
	}
	if _, err := client.RegisterFolderClient(ctx, &dieterv1.RegisterFolderClientRequest{FolderId: definition.ID, Name: "Pixel", Mode: dieterv1.FolderMode_FOLDER_MODE_TWO_WAY}); err != nil {
		t.Fatal(err)
	}
	content := []byte("scanned receipt")
	sum := sha256.Sum256(content)
	digest := hex.EncodeToString(sum[:])
	actor := core.ActorOf(phone.DeviceID())
	entry := &dieterv1.FolderEntry{Path: "receipts/scan.pdf", Kind: dieterv1.FolderEntryKind_FOLDER_ENTRY_KIND_FILE, Size: int64(len(content)), ModifiedNanos: time.Now().UnixNano(),
		Sha256: digest, Version: []*dieterv1.FolderCounter{{Actor: actor, Value: 1}}, AuthorId: phone.DeviceID(), AuthorName: "Pixel"}
	upload := func(entry *dieterv1.FolderEntry, operation string) error {
		begun, err := client.BeginFileUpload(ctx, &dieterv1.BeginFileUploadRequest{Target: &dieterv1.TransferPath{FolderId: definition.ID, Path: entry.GetPath()}, OperationId: operation,
			Size: entry.GetSize(), Sha256: entry.GetSha256(), ModifiedNanos: entry.GetModifiedNanos(), Mode: 0o644, FolderEntry: entry})
		if err != nil {
			return err
		}
		if _, err := client.WriteFileChunk(ctx, &dieterv1.WriteFileChunkRequest{Id: begun.GetId(), Offset: 0, Data: content, Sha256: digest}); err != nil {
			return err
		}
		_, err = client.CommitFileUpload(ctx, &dieterv1.FileUploadRequest{Id: begun.GetId()})
		return err
	}
	if err := upload(entry, "phone-upload-1"); err != nil {
		t.Fatal(err)
	}
	waitContent(t, 30*time.Second, a.dir, "receipts/scan.pdf", string(content))
	waitContent(t, 60*time.Second, b.dir, "receipts/scan.pdf", string(content))

	// The phone reads the file back by its content hash.
	chunk, err := client.ReadFileChunk(ctx, &dieterv1.ReadFileChunkRequest{Target: &dieterv1.TransferPath{FolderId: definition.ID, Path: "receipts/scan.pdf"}, Revision: digest, Length: 1 << 20})
	if err != nil || !bytes.Equal(chunk.GetData(), content) {
		t.Fatalf("read by hash: %v %q", err, chunk.GetData())
	}
	page, err := client.GetFolderIndex(ctx, &dieterv1.GetFolderIndexRequest{FolderId: definition.ID, MemberId: phone.DeviceID()})
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, e := range page.GetEntries() {
		found = found || e.GetPath() == "receipts/scan.pdf" && e.GetSha256() == digest
	}
	if !found {
		t.Fatalf("index page lacks the upload: %v", page.GetEntries())
	}

	// An edit on B, then a phone upload that did not see it, is refused.
	writeFile(t, b.dir, "receipts/scan.pdf", "edited on B", time.Time{})
	waitContent(t, 60*time.Second, a.dir, "receipts/scan.pdf", "edited on B")
	stale := proto.Clone(entry).(*dieterv1.FolderEntry)
	stale.Version = []*dieterv1.FolderCounter{{Actor: actor, Value: 2}}
	if err := upload(stale, "phone-upload-2"); status.Code(err) != codes.Aborted {
		t.Fatalf("stale upload: %v", err)
	}
}

func ptr[T any](v T) *T { return &v }
