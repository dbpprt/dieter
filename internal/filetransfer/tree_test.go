package filetransfer

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

func write(t *testing.T, root, p, content string, mode os.FileMode) {
	t.Helper()
	full := filepath.Join(root, p)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(full, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
}

func TestScanObservationsMatchStatRevisions(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	write(t, root, "a.txt", "alpha", 0o644)
	write(t, root, "bin/run.sh", "#!/bin/sh", 0o755)
	write(t, root, "deep/er/x", "x", 0o600)
	write(t, root, ".git/config", "git", 0o644)
	write(t, root, "node_modules/pkg/index.js", "js", 0o644)
	write(t, root, TemporaryPrefix+"partial", "p", 0o600)
	if err := os.Symlink("a.txt", filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	result, err := Scan(ctx, root, ScanOptions{Exclude: func(p string) bool { return p == "node_modules" }})
	if err != nil {
		t.Fatal(err)
	}
	var paths []string
	for _, entry := range result.Entries {
		paths = append(paths, entry.Path)
		stat, err := Stat(ctx, root, entry.Path, false)
		if err != nil {
			t.Fatal(err)
		}
		if stat.Revision != entry.Revision || stat.Kind != entry.Kind || stat.Mode != entry.Mode || stat.Modified != entry.Modified {
			t.Errorf("%s: scan %+v, stat %+v", entry.Path, entry, stat)
		}
	}
	slices.Sort(paths)
	want := []string{"a.txt", "bin", "bin/run.sh", "deep", "deep/er", "deep/er/x"}
	if !slices.Equal(paths, want) {
		t.Fatalf("paths = %v, want %v", paths, want)
	}
	if len(result.Skipped) != 1 || result.Skipped[0].Path != "link" {
		t.Fatalf("skipped = %+v", result.Skipped)
	}
	if _, err := Scan(ctx, root, ScanOptions{Limit: 2}); err == nil {
		t.Fatal("scan ignored its limit")
	} else if kind, _ := fault.KindOf(err); kind != fault.ResourceExhausted {
		t.Fatalf("limit error kind %v", kind)
	}
}

func TestDirectoriesRenameAndMoveOut(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	if err := Mkdir(root, "x/y/z"); err != nil {
		t.Fatal(err)
	}
	if err := Mkdir(root, "x/y/z"); err != nil {
		t.Fatalf("existing directory: %v", err)
	}
	write(t, root, "x/y/z/f", "content", 0o644)
	if err := RemoveEmptyDir(root, "x/y/z"); err == nil {
		t.Fatal("removed a non-empty directory")
	}
	entry, err := Stat(ctx, root, "x/y/z/f", false)
	if err != nil {
		t.Fatal(err)
	}
	write(t, root, "taken", "other", 0o644)
	if err := Rename(ctx, root, "x/y/z/f", entry.Revision, "taken"); err == nil {
		t.Fatal("rename replaced an existing file")
	}
	if err := Rename(ctx, root, "x/y/z/f", "stale", "copy"); err == nil {
		t.Fatal("rename ignored a stale revision")
	}
	if err := Rename(ctx, root, "x/y/z/f", entry.Revision, "copies/f (conflict)"); err != nil {
		t.Fatal(err)
	}
	if err := RemoveEmptyDir(root, "x/y/z"); err != nil {
		t.Fatal(err)
	}
	moved, err := Stat(ctx, root, "copies/f (conflict)", false)
	if err != nil || moved.Kind != "file" {
		t.Fatalf("renamed file: %+v %v", moved, err)
	}
	trash := filepath.Join(t.TempDir(), "trash")
	if _, err := MoveOut(ctx, root, "copies/f (conflict)", moved.Revision, trash, "item"); err != nil {
		t.Fatal(err)
	}
	if b, err := os.ReadFile(filepath.Join(trash, "item")); err != nil || string(b) != "content" {
		t.Fatalf("trash content %q %v", b, err)
	}
	if gone, _ := Stat(ctx, root, "copies/f (conflict)", false); gone.Kind != Missing {
		t.Fatal("moved file still present")
	}
}

func TestBlocksAndQuarantinePublish(t *testing.T) {
	ctx := context.Background()
	root := t.TempDir()
	data := bytes.Repeat([]byte("0123456789abcdef"), (ChunkSize*2+100)/16)
	write(t, root, "big", string(data), 0o644)
	entry, err := Stat(ctx, root, "big", false)
	if err != nil {
		t.Fatal(err)
	}
	blocks, whole, err := Blocks(ctx, root, "big", entry.Revision)
	if err != nil {
		t.Fatal(err)
	}
	if len(blocks) != 3 || whole != Digest(data) || blocks[0] != Digest(data[:ChunkSize]) {
		t.Fatalf("blocks %d whole %s", len(blocks), whole)
	}
	source := Entry{Size: 5, SHA256: Digest([]byte("hello")), Mode: 0o755, Modified: entry.Modified}
	if _, err := PublishWith(ctx, root, "new/file", Missing, source, strings.NewReader("hello"), PublishOptions{Quarantine: true}); err != nil {
		t.Fatal(err)
	}
	published, err := Stat(ctx, root, "new/file", true)
	if err != nil || published.SHA256 != source.SHA256 || published.Mode != 0o755 {
		t.Fatalf("published %+v %v", published, err)
	}
}
