package filetransfer

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPublishIntegrityConflictAndContainment(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	root := t.TempDir()
	payload := bytes.Repeat([]byte{0, 1, 255, 3}, ChunkSize/2+17)
	source := Entry{Size: int64(len(payload)), SHA256: Digest(payload), Modified: time.Now().Add(-time.Hour).UnixNano(), Mode: 0o640}
	if err := Publish(ctx, root, "nested/data.bin", Missing, source, bytes.NewReader(payload)); err != nil {
		t.Fatal(err)
	}
	got, err := Stat(ctx, root, "nested/data.bin", true)
	if err != nil || got.SHA256 != source.SHA256 || got.Modified != source.Modified || got.Mode != source.Mode {
		t.Fatalf("stat %+v: %v", got, err)
	}
	for _, test := range []struct {
		name, expected string
		data           []byte
	}{{"stale", Missing, payload}, {"corrupt", got.Revision, []byte("bad")}} {
		t.Run(test.name, func(t *testing.T) {
			if err := Publish(ctx, root, "nested/data.bin", test.expected, source, bytes.NewReader(test.data)); err == nil {
				t.Fatal("accepted invalid replacement")
			}
			after, _ := Stat(ctx, root, "nested/data.bin", true)
			if after.SHA256 != source.SHA256 {
				t.Fatal("damaged destination")
			}
		})
	}
	outside := t.TempDir()
	if err = os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	for _, p := range []string{"../escape", ".git/config", "escape/file"} {
		if err = Publish(ctx, root, p, Missing, source, bytes.NewReader(payload)); err == nil {
			t.Fatalf("accepted %s", p)
		}
	}
	if err = Remove(ctx, root, "nested/data.bin", Missing); err == nil {
		t.Fatal("accepted unobserved deletion")
	}
	if err = Remove(ctx, root, "nested/data.bin", got.Revision); err != nil {
		t.Fatal(err)
	}
}
func TestPaginationChangesAndReadRevision(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	for _, n := range []string{"c", "a", "b", ".hidden"} {
		if err := os.WriteFile(filepath.Join(root, n), []byte(n), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	entries, next, revision, err := List(t.Context(), root, ".", "", "", 2)
	if err != nil || len(entries) != 2 || next != "a" {
		t.Fatalf("%v %s %v", entries, next, err)
	}
	entries, next, _, err = List(t.Context(), root, ".", next, revision, 2)
	if err != nil || len(entries) != 2 || next != "" {
		t.Fatalf("page 2: %v %s %v", entries, next, err)
	}
	if err = os.WriteFile(filepath.Join(root, "d"), []byte("d"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, _, err = List(t.Context(), root, ".", "a", revision, 2); err == nil {
		t.Fatal("accepted changed directory")
	}
	e, err := Stat(t.Context(), root, "a", true)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(root, "a"), []byte("changed"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err = Read(t.Context(), root, "a", e.Revision, 0, ChunkSize); err == nil {
		t.Fatal("accepted stale read")
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err = Stat(ctx, root, "a", true); err == nil {
		t.Fatal("ignored cancellation")
	}
}
func TestPlanFiltersComparisonAndDeletion(t *testing.T) {
	t.Parallel()
	source := map[string]Entry{"a": {Kind: "file", Size: 4, Modified: 2, SHA256: "new"}, "nested/b": {Kind: "file", Size: 2}}
	dest := map[string]Entry{"a": {Kind: "file", Size: 4, Modified: 2, SHA256: "old"}, "keep.secret": {Kind: "file"}, "gone": {Kind: "file"}}
	opts := PlanOptions{Sync: true, Delete: true, Checksum: true, Rules: []Rule{{"*", false}, {"a", true}, {"nested/*", true}, {"gone", true}}}
	plan, err := Plan(source, dest, opts)
	if err != nil {
		t.Fatal(err)
	}
	if len(plan) != 3 || plan[0].Kind != "copy" || plan[1].Kind != "delete" || plan[2].Path != "nested/b" {
		t.Fatalf("%+v", plan)
	}
	opts.Checksum = false
	plan, err = Plan(source, dest, opts)
	if err != nil || plan[0].Kind != "skip" {
		t.Fatalf("%+v %v", plan, err)
	}
	opts.Rules = []Rule{{"nested/*", false}, {"nested/b", true}}
	if !Included("nested/b", opts.Rules) || Included("nested/deep/c", opts.Rules) {
		t.Fatal("ordered AWS-style globs failed")
	}
	source["gone"] = Entry{Kind: "directory"}
	if _, err = Plan(source, dest, opts); err == nil {
		t.Fatal("accepted type conflict")
	}
}
