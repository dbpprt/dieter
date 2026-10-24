package codexdrv

import (
	"os"
	"path/filepath"
	"testing"

	"dieter.spike/workspaces/core"
)

func TestRelativizer(t *testing.T) {
	dir := t.TempDir() // on macOS: /var/folders/... which resolves to /private/var/...
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "realdir"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("realdir", filepath.Join(dir, "linkdir")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "target.txt"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("target.txt", filepath.Join(dir, "link.txt")); err != nil {
		t.Fatal(err)
	}
	r := newRelativizer(dir)
	cases := []struct {
		in   string
		want string
		in2  bool
	}{
		{filepath.Join(dir, "a/b.txt"), "a/b.txt", true},
		{filepath.Join(real, "a/b.txt"), "a/b.txt", true},
		{filepath.Join(real, "gone/deeper/x.txt"), "gone/deeper/x.txt", true},
		{"sub/../y.txt", "y.txt", true},
		{"./z.txt", "z.txt", true},
		{"../escape.txt", "../escape.txt", false},
		{filepath.Join(dir, "linkdir/f.txt"), "realdir/f.txt", true},
		{filepath.Join(dir, "link.txt"), "link.txt", true}, // a reported symlink stays itself
		{"/definitely/elsewhere/f.txt", "/definitely/elsewhere/f.txt", false},
		{filepath.Join(dir, "café.txt"), core.NormPath("café.txt"), true},
	}
	for _, tc := range cases {
		got, in := r.rel(tc.in)
		if got != tc.want || in != tc.in2 {
			t.Errorf("rel(%q) = %q,%v; want %q,%v", tc.in, got, in, tc.want, tc.in2)
		}
	}
}

func TestSpellings(t *testing.T) {
	got := spellings("/private/tmp/x")
	if len(got) != 2 || got[1] != "/tmp/x" {
		t.Fatalf("got %q", got)
	}
	got = spellings("/var/folders/x")
	if len(got) != 2 || got[1] != "/private/var/folders/x" {
		t.Fatalf("got %q", got)
	}
	if got = spellings("/Volumes/External/x"); len(got) != 1 {
		t.Fatalf("got %q", got)
	}
}

func TestMergeChange(t *testing.T) {
	cs := core.ChangeSet{}
	mergeChange(cs, "a", core.Added)
	mergeChange(cs, "a", core.Modified)
	mergeChange(cs, "b", core.Added)
	mergeChange(cs, "b", core.Deleted)
	mergeChange(cs, "c", core.Deleted)
	mergeChange(cs, "c", core.Added)
	mergeChange(cs, "d", core.Modified)
	mergeChange(cs, "d", core.Deleted)
	mergeChange(cs, "e", core.Modified)
	mergeChange(cs, "e", core.Changed)
	want := map[string]core.ChangeKind{"a": core.Added, "c": core.Modified, "d": core.Deleted, "e": core.Modified}
	if len(cs) != len(want) {
		t.Fatalf("got %v", cs)
	}
	for p, k := range want {
		if cs[p].Kind != k {
			t.Errorf("%s: got %s want %s", p, cs[p].Kind, k)
		}
	}
}
