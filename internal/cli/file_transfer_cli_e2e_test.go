//go:build e2e

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	files "github.com/dbpprt/dieter/internal/filetransfer"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/testkit/topology"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestFileTransferCLILocal(t *testing.T) {
	t.Parallel()
	client, out, data := daemonCLIForTest(t)
	repo := initTestRepository(t, "transfer")
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Path: repo, Name: "Transfers"})
	if err != nil {
		t.Fatal(err)
	}
	assertFileTransfers(t, client, out, repo, project.ID)
}
func TestFileTransferCLIRoutes(t *testing.T) {
	for _, route := range []string{"direct", "relay"} {
		t.Run(route, func(t *testing.T) {
			t.Parallel()
			g := topology.StartGateway(t, topology.GatewayOptions{Issuer: "https://transfer.example.test"})
			identity := topology.Machine(t, g, "transfer", topology.Account)
			data := testkit.Store(t)
			repo := initTestRepository(t, "transfer-route")
			project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Path: repo, Name: "Transfers"})
			if err != nil {
				t.Fatal(err)
			}
			topology.StartDaemon(t, g, topology.DaemonOptions{Identity: identity, Store: data, Direct: route == "direct"})
			client := New(identity.Root)
			defer client.Close()
			client.Machine = identity.ID
			client.GatewayURL = g.URL
			client.Timeout = testkit.Budget(60 * time.Second)
			var out bytes.Buffer
			client.Out = &out
			client.Err = &out
			assertFileTransfers(t, client, &out, repo, project.ID)
			if client.transport.route != route {
				t.Fatalf("route %s, want %s", client.transport.route, route)
			}
		})
	}
}
func assertFileTransfers(t *testing.T, c *CLI, out *bytes.Buffer, repo, project string) {
	t.Helper()
	src := t.TempDir()
	dst := filepath.Join(t.TempDir(), "new", "nested")
	payload := bytes.Repeat([]byte{0, 255, 3, 17}, (6<<20)/4+3)
	write := func(p string, b []byte) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, b, 0o640); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(src, "data.bin"), payload)
	write(filepath.Join(src, ".hidden"), []byte("hidden"))
	write(filepath.Join(src, "nested", "small"), []byte("small"))
	write(filepath.Join(src, ".git", "config"), []byte("protected"))
	run := func(args ...string) string {
		t.Helper()
		out.Reset()
		if err := c.Run(append([]string{"file"}, args...)); err != nil {
			t.Fatal(err)
		}
		return out.String()
	}
	common := []string{"--project", project, "--no-progress", "--format", "jsonl"}
	syncArgs := func(extra ...string) []string { return append(append([]string{"sync"}, common...), extra...) }
	raw := run(syncArgs("--dryrun", src, "remote:transfers/")...)
	if !strings.Contains(raw, "planned") {
		t.Fatal(raw)
	}
	if _, err := os.Stat(filepath.Join(repo, "transfers")); !os.IsNotExist(err) {
		t.Fatal("dry run wrote destination")
	}
	run(syncArgs(src, "remote:transfers/")...)
	actual, err := os.ReadFile(filepath.Join(repo, "transfers", "data.bin"))
	if err != nil || !bytes.Equal(actual, payload) {
		t.Fatalf("upload %v", err)
	}
	if _, err = os.Stat(filepath.Join(repo, "transfers", ".git")); !os.IsNotExist(err) {
		t.Fatal("copied .git")
	}
	raw = run(syncArgs("--checksum", src, "remote:transfers/")...)
	for _, line := range strings.Split(strings.TrimSpace(raw), "\n") {
		var e struct{ Action string }
		if err = json.Unmarshal([]byte(line), &e); err != nil || e.Action != "skip" {
			t.Fatalf("second sync: %s %v", line, err)
		}
	}
	run(syncArgs("remote:transfers/", dst)...)
	actual, err = os.ReadFile(filepath.Join(dst, "data.bin"))
	if err != nil || !bytes.Equal(actual, payload) {
		t.Fatalf("download %v", err)
	}
	// Equal sizes and modification times can still contain different bytes.
	originalInfo, err := os.Stat(filepath.Join(src, ".hidden"))
	if err != nil {
		t.Fatal(err)
	}
	write(filepath.Join(src, ".hidden"), []byte("change"))
	if err = os.Chtimes(filepath.Join(src, ".hidden"), originalInfo.ModTime(), originalInfo.ModTime()); err != nil {
		t.Fatal(err)
	}
	run(syncArgs("--checksum", src, "remote:transfers/")...)
	changed, err := os.ReadFile(filepath.Join(repo, "transfers", ".hidden"))
	if err != nil || string(changed) != "change" {
		t.Fatal("checksum missed equal-size/equal-time change")
	}
	// Existing and not-yet-created nested endpoints must not recurse into self.
	out.Reset()
	overlap := append([]string{"file"}, syncArgs(filepath.Join(repo, "transfers"), "remote:transfers/child")...)
	if err = c.Run(overlap); err == nil {
		t.Fatal("accepted overlapping trees")
	}
	// Copy uses the same chunk protocol and accepts a directory destination.
	run(append(append([]string{"cp"}, common...), filepath.Join(src, "data.bin"), "remote:single.bin")...)
	downloaded := filepath.Join(t.TempDir(), "copied.bin")
	run(append(append([]string{"cp"}, common...), "remote:single.bin", downloaded)...)
	actual, err = os.ReadFile(downloaded)
	if err != nil || !bytes.Equal(actual, payload) {
		t.Fatalf("copy %v", err)
	}
	// Destination-only and excluded files exercise the deletion barrier.
	write(filepath.Join(repo, "transfers", "gone"), []byte("delete"))
	write(filepath.Join(repo, "transfers", "keep.secret"), []byte("keep"))
	run(syncArgs("--delete", "--exclude", "*.secret", src, "remote:transfers/")...)
	if _, err = os.Stat(filepath.Join(repo, "transfers", "gone")); !os.IsNotExist(err) {
		t.Fatal("did not delete destination-only file")
	}
	if _, err = os.Stat(filepath.Join(repo, "transfers", "keep.secret")); err != nil {
		t.Fatal("deleted exclusion")
	}
	write(filepath.Join(repo, "transfers", "survivor"), []byte("keep on failed scan"))
	if err = os.Symlink("data.bin", filepath.Join(src, "link")); err != nil {
		t.Fatal(err)
	}
	out.Reset()
	if err = c.Run(append([]string{"file"}, syncArgs("--delete", src, "remote:transfers/")...)); err == nil {
		t.Fatal("accepted unsupported symlink")
	}
	if _, err = os.Stat(filepath.Join(repo, "transfers", "survivor")); err != nil {
		t.Fatal("failed scan deleted destination")
	}
	// Exercise all explicit session lifecycle commands across each route.
	chunkPath := filepath.Join(t.TempDir(), "chunk")
	write(chunkPath, []byte("chunk"))
	raw = run("upload", "begin", "--project", project, "--operation", "protocol-test", "--revision", "missing", "--size", "5", "--sha256", files.Digest([]byte("chunk")), "protocol.bin")
	var u dieterv1.FileUpload
	if err = protojson.Unmarshal([]byte(raw), &u); err != nil {
		t.Fatal(err)
	}
	run("upload", "chunk", "--file", chunkPath, u.Id)
	run("upload", "show", u.Id)
	run("upload", "commit", u.Id)
	run("upload", "commit", u.Id)
	raw = run("upload", "begin", "--project", project, "--operation", "abort-test", "--revision", "missing", "--size", "0", "--sha256", files.Digest(nil), "aborted.bin")
	if err = protojson.Unmarshal([]byte(raw), &u); err != nil {
		t.Fatal(err)
	}
	run("upload", "abort", u.Id)
	run("stat", "--project", project, "--checksum", "protocol.bin")
	run("scan", "--project", project, "--page-size", "2", ".")
	// Range requests reject stale revisions and unbounded chunks over the wire.
	ctx, cancel := context.WithTimeout(context.Background(), testkit.Budget(10*time.Second))
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		t.Fatal(err)
	}
	target := &dieterv1.TransferPath{ProjectId: project, Path: "protocol.bin"}
	if _, err = client.ReadFileChunk(rpcCtx, &dieterv1.ReadFileChunkRequest{Target: target, Revision: "stale", Length: files.ChunkSize}); err == nil {
		t.Fatal("accepted stale range")
	}
}
