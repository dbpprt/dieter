//go:build linux

package linuxfs

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"

	"dieter.spike/workspaces/core"
	"golang.org/x/sys/unix"
)

// TestMain doubles as the in-namespace scanner: with LINUXFS_HELPER_SCAN set
// the test binary scans that directory and writes the tree as JSON to
// LINUXFS_HELPER_OUT. Sessions run it after their operation, so the merged
// view the kernel shows is the ground truth.
func TestMain(m *testing.M) {
	if root := os.Getenv("LINUXFS_HELPER_SCAN"); root != "" {
		tree, err := ScanTree(root)
		if err == nil {
			var data []byte
			if data, err = json.Marshal(tree); err == nil {
				err = os.WriteFile(os.Getenv("LINUXFS_HELPER_OUT"), data, 0o600)
			}
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "helper scan:", err)
			os.Exit(97)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func requireBwrap(t testing.TB) {
	t.Helper()
	if _, err := exec.LookPath(BwrapPath); err != nil {
		t.Skip("bwrap not installed")
	}
}

// cleanEnv is the environment for child processes, without Dieter's
// session variables.
func cleanEnv(extra ...string) []string {
	var out []string
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		switch k {
		case "DIETER_TURN_TOKEN", "DIETER_HOME", "DIETER_CARD_ID", "LINUXFS_HELPER_SCAN", "LINUXFS_HELPER_OUT":
			continue
		}
		out = append(out, kv)
	}
	return append(out, extra...)
}

// testDir is a scratch directory (under LINUXFS_TEST_DIR when set, to run on
// a specific filesystem) removed with RemoveAll.
func testDir(t testing.TB) string {
	t.Helper()
	var dir string
	if base := os.Getenv("LINUXFS_TEST_DIR"); base != "" {
		if err := os.MkdirAll(base, 0o700); err != nil {
			t.Fatal(err)
		}
		d, err := os.MkdirTemp(base, "t-")
		if err != nil {
			t.Fatal(err)
		}
		dir = d
	} else {
		dir = t.TempDir()
	}
	t.Cleanup(func() {
		if err := RemoveAll(dir); err != nil {
			t.Errorf("cleanup: %v", err)
		}
	})
	return dir
}

// session runs script with sh inside the overlay, then scans the merged
// view from inside the same namespace. It returns combined output, the
// script's exit status and the merged tree.
func session(t testing.TB, o Overlay, script string, extra ...string) (string, int, core.Tree) {
	t.Helper()
	return sessionEnv(t, o, nil, script, extra...)
}

// sessionEnv is session with extra environment for the script.
func sessionEnv(t testing.TB, o Overlay, env []string, script string, extra ...string) (string, int, core.Tree) {
	t.Helper()
	if err := o.Prepare(); err != nil {
		t.Fatalf("prepare: %v", err)
	}
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	out := filepath.Join(filepath.Dir(o.Upper), "merged-"+strconv.Itoa(os.Getpid())+".json")
	argv := append(o.WrapWith(extra...), "sh", "-c",
		`sh -c "$LINUXFS_OP"; rc=$?; LINUXFS_HELPER_SCAN="$PWD" "$LINUXFS_SELF" || exit 99; exit $rc`)
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = o.Mount
	cmd.Env = cleanEnv(append(env, "LINUXFS_OP="+script, "LINUXFS_SELF="+self, "LINUXFS_HELPER_OUT="+out)...)
	var buf bytes.Buffer
	cmd.Stdout, cmd.Stderr = &buf, &buf
	err = cmd.Run()
	rc := 0
	var ee *exec.ExitError
	switch {
	case errors.As(err, &ee):
		rc = ee.ExitCode()
	case err != nil:
		t.Fatalf("bwrap: %v", err)
	}
	if rc == 99 {
		t.Fatalf("in-namespace scan failed: %s", buf.String())
	}
	data, err := os.ReadFile(out)
	if err != nil {
		t.Fatalf("merged tree: %v (output %s)", err, buf.String())
	}
	os.Remove(out)
	var merged core.Tree
	if err := json.Unmarshal(data, &merged); err != nil {
		t.Fatal(err)
	}
	return buf.String(), rc, merged
}

type fixture struct {
	dir, checkout, lower string
	lowerTree            core.Tree
	xattrs               bool
}

func writeFile(t testing.TB, path, content string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

// newFixture builds a small checkout and a frozen lower copied from it with
// ReflinkTree (FICLONE on btrfs, the copy fallback on tmpfs).
func newFixture(t *testing.T) *fixture {
	t.Helper()
	requireBwrap(t)
	f := &fixture{dir: testDir(t)}
	f.checkout = filepath.Join(f.dir, "checkout")
	f.lower = filepath.Join(f.dir, "lower")
	files := map[string]string{
		"a.txt": "alpha\n", "b.txt": "bravo\n", "x.txt": "xattr\n",
		"sub/c.txt": "charlie\n", "sub/deep/d.txt": "delta\n",
		"dir/x.txt": "x-ray\n", "dir/y.txt": "yankee\n",
		"opq/o1.txt": "one\n", "opq/o2.txt": "two\n",
	}
	for p, c := range files {
		writeFile(t, filepath.Join(f.checkout, p), c, 0o644)
	}
	writeFile(t, filepath.Join(f.checkout, "run.sh"), "#!/bin/sh\n", 0o755)
	if err := os.Symlink("a.txt", filepath.Join(f.checkout, "link")); err != nil {
		t.Fatal(err)
	}
	f.xattrs = unix.Lsetxattr(filepath.Join(f.checkout, "sub/c.txt"), "user.keep", []byte("1"), 0) == nil
	took, fallbacks, err := ReflinkTree(f.checkout, f.lower)
	if err != nil {
		t.Fatalf("reflink: %v", err)
	}
	t.Logf("ReflinkTree %v, %d copy fallbacks", took, fallbacks)
	if f.lowerTree, err = ScanTree(f.lower); err != nil {
		t.Fatal(err)
	}
	if ct := f.scanCheckout(t); !maps.Equal(ct, f.lowerTree) {
		t.Fatalf("reflinked lower differs from checkout: %v", kinds(core.DiffTrees(ct, f.lowerTree)))
	}
	return f
}

func (f *fixture) scanCheckout(t testing.TB) core.Tree {
	t.Helper()
	tree, err := ScanTree(f.checkout)
	if err != nil {
		t.Fatal(err)
	}
	return tree
}

func (f *fixture) overlay(name string) Overlay {
	s := filepath.Join(f.dir, "s-"+name)
	return Overlay{Lower: f.lower, Upper: filepath.Join(s, "upper"), Work: filepath.Join(s, "work"), Mount: f.checkout}
}

func TestOverlayScenarios(t *testing.T) {
	f := newFixture(t)
	type check func(t *testing.T, upper map[string]UpperEntry, st CopyUpStats, out string)
	cases := []struct {
		name   string
		script string
		want   map[string]core.ChangeKind
		needs  string // required tool or "xattr"
		check  check
	}{
		{name: "add", script: "echo new > new.txt && mkdir -p n/m && echo q > n/m/q.txt",
			want: map[string]core.ChangeKind{"new.txt": core.Added, "n/m/q.txt": core.Added}},
		{name: "modify", script: "echo more >> a.txt", want: map[string]core.ChangeKind{"a.txt": core.Modified}},
		{name: "delete", script: "rm b.txt", want: map[string]core.ChangeKind{"b.txt": core.Deleted},
			check: func(t *testing.T, u map[string]UpperEntry, _ CopyUpStats, _ string) {
				if !u["b.txt"].Deleted {
					t.Errorf("b.txt not a whiteout: %+v", u["b.txt"])
				}
			}},
		{name: "chmod", script: "chmod +x a.txt", want: map[string]core.ChangeKind{"a.txt": core.ModeChanged}},
		{name: "symlink retarget", script: "ln -sfn b.txt link", want: map[string]core.ChangeKind{"link": core.Modified}},
		{name: "dir rename", script: "mv dir dir2", want: map[string]core.ChangeKind{
			"dir/x.txt": core.Deleted, "dir/y.txt": core.Deleted, "dir2/x.txt": core.Added, "dir2/y.txt": core.Added}},
		{name: "opaque dir recreate", script: "rm -rf opq && mkdir opq && echo z > opq/o3.txt",
			want: map[string]core.ChangeKind{"opq/o1.txt": core.Deleted, "opq/o2.txt": core.Deleted, "opq/o3.txt": core.Added},
			check: func(t *testing.T, u map[string]UpperEntry, _ CopyUpStats, _ string) {
				if !u["opq"].Opaque {
					t.Errorf("opq not opaque: %+v", u["opq"])
				}
			}},
		{name: "delete dir", script: "rm -rf sub", want: map[string]core.ChangeKind{
			"sub/c.txt": core.Deleted, "sub/deep/d.txt": core.Deleted}},
		{name: "file over dir", script: "rm -rf dir && echo f > dir", want: map[string]core.ChangeKind{
			"dir": core.TypeChanged, "dir/x.txt": core.Deleted, "dir/y.txt": core.Deleted}},
		{name: "touch no change", script: "touch a.txt", want: map[string]core.ChangeKind{},
			check: identicalAtLeast(1)},
		{name: "identical rewrite", script: "cp a.txt a.tmp && cat a.tmp > a.txt && rm a.tmp",
			want: map[string]core.ChangeKind{}, check: identicalAtLeast(1)},
		{name: "chmod back", script: "chmod 644 run.sh && chmod 755 run.sh",
			want: map[string]core.ChangeKind{}, check: identicalAtLeast(1)},
		{name: "chmod 000", script: "chmod 000 b.txt", want: map[string]core.ChangeKind{"b.txt": core.ModeChanged}},
		{name: "hardlink", script: "ln a.txt a2.txt", want: map[string]core.ChangeKind{"a2.txt": core.Added}},
		{name: "xattr only", script: "setfattr -n user.spike -v 1 x.txt", needs: "setfattr",
			want: map[string]core.ChangeKind{"x.txt": core.XattrChanged}},
		{name: "xattr preserved by copy-up", script: "echo more >> sub/c.txt", needs: "xattr",
			want: map[string]core.ChangeKind{"sub/c.txt": core.Modified}},
		{name: "rename(2) of lower dir", needs: "python3",
			script: `python3 -c 'import os
try:
    os.rename("dir", "dir3")
except OSError as e:
    print("errno", e.errno)'`,
			want: map[string]core.ChangeKind{},
			check: func(t *testing.T, _ map[string]UpperEntry, _ CopyUpStats, out string) {
				if !strings.Contains(out, fmt.Sprintf("errno %d", unix.EXDEV)) {
					t.Errorf("rename output %q, want EXDEV", out)
				}
			}},
		{name: "identity", script: `test "$(id -u)" = "` + strconv.Itoa(os.Getuid()) + `" && test "$(id -g)" = "` +
			strconv.Itoa(os.Getgid()) + `"`, want: map[string]core.ChangeKind{}},
	}
	before := f.scanCheckout(t)
	for i, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			switch c.needs {
			case "":
			case "xattr":
				if !f.xattrs {
					t.Skip("filesystem lacks user xattrs")
				}
			default:
				if _, err := exec.LookPath(c.needs); err != nil {
					t.Skipf("%s not installed", c.needs)
				}
			}
			o := f.overlay(strconv.Itoa(i))
			out, rc, merged := session(t, o, c.script)
			if rc != 0 {
				t.Fatalf("script exit %d: %s", rc, out)
			}
			cs, st, err := o.Changes(f.lowerTree)
			if err != nil {
				t.Fatal(err)
			}
			if got := kinds(cs); !maps.Equal(got, c.want) {
				t.Errorf("Changes = %v, want %v", got, c.want)
			}
			if truth := kinds(core.DiffTrees(f.lowerTree, merged)); !maps.Equal(truth, c.want) {
				t.Errorf("merged-view diff = %v, want %v", truth, c.want)
			}
			upper, _, err := o.ReadUpper()
			if err != nil {
				t.Fatal(err)
			}
			if eff := o.Effective(f.lowerTree, upper); !maps.Equal(eff, merged) {
				t.Errorf("Effective differs from the merged view: %v", kinds(core.DiffTrees(merged, eff)))
			}
			if c.check != nil {
				c.check(t, upper, st, out)
			}
			if st.Upper.Redirects+st.Upper.Metacopy != 0 {
				t.Errorf("unexpected redirect/metacopy: %+v", st.Upper)
			}
		})
	}
	if after := f.scanCheckout(t); !maps.Equal(after, before) {
		t.Errorf("host checkout changed: %v", kinds(core.DiffTrees(before, after)))
	}
}

func identicalAtLeast(n int) func(t *testing.T, _ map[string]UpperEntry, st CopyUpStats, _ string) {
	return func(t *testing.T, _ map[string]UpperEntry, st CopyUpStats, _ string) {
		if st.Identical < n {
			t.Errorf("identical copy-ups = %d, want >= %d", st.Identical, n)
		}
	}
}

func TestChangesBetweenTurns(t *testing.T) {
	f := newFixture(t)
	o := f.overlay("turns")
	turns := []struct {
		script string
		want   map[string]core.ChangeKind
	}{
		{"echo t1 >> a.txt && echo n > new.txt && rm b.txt",
			map[string]core.ChangeKind{"a.txt": core.Modified, "new.txt": core.Added, "b.txt": core.Deleted}},
		{"printf 'alpha\\n' > a.txt && rm new.txt && rm -rf opq && mkdir opq && echo z > opq/z.txt",
			map[string]core.ChangeKind{"a.txt": core.Modified, "new.txt": core.Deleted, "opq/o1.txt": core.Deleted,
				"opq/o2.txt": core.Deleted, "opq/z.txt": core.Added}},
		{"mv dir dir2 && chmod +x x.txt && echo b > b.txt",
			map[string]core.ChangeKind{"dir/x.txt": core.Deleted, "dir/y.txt": core.Deleted, "dir2/x.txt": core.Added,
				"dir2/y.txt": core.Added, "x.txt": core.ModeChanged, "b.txt": core.Added}},
	}
	prev, prevTree := map[string]UpperEntry{}, f.lowerTree
	for i, tc := range turns {
		out, rc, merged := session(t, o, tc.script)
		if rc != 0 {
			t.Fatalf("turn %d exit %d: %s", i+1, rc, out)
		}
		cur, _, err := o.ReadUpper()
		if err != nil {
			t.Fatal(err)
		}
		if got := kinds(ChangesBetween(prev, cur, f.lowerTree)); !maps.Equal(got, tc.want) {
			t.Errorf("turn %d ChangesBetween = %v, want %v", i+1, got, tc.want)
		}
		if truth := kinds(core.DiffTrees(prevTree, merged)); !maps.Equal(truth, tc.want) {
			t.Errorf("turn %d merged diff = %v, want %v", i+1, truth, tc.want)
		}
		cs, _, err := o.Changes(f.lowerTree)
		if err != nil {
			t.Fatal(err)
		}
		if truth := kinds(core.DiffTrees(f.lowerTree, merged)); !maps.Equal(kinds(cs), truth) {
			t.Errorf("turn %d cumulative = %v, want %v", i+1, kinds(cs), truth)
		}
		prev, prevTree = cur, merged
	}
	// Cumulative after turn 2 reverted a.txt: only the identical copy-up remains.
	cs, st, _ := o.Changes(f.lowerTree)
	if _, ok := cs["a.txt"]; ok || st.Identical < 1 {
		t.Errorf("reverted a.txt reported: %v (identical %d)", kinds(cs), st.Identical)
	}
}

func TestPrepareRejectsOverlap(t *testing.T) {
	d := testDir(t)
	for _, o := range []Overlay{
		{Lower: d + "/l", Upper: d + "/m/u", Work: d + "/w", Mount: d + "/m"},
		{Lower: d + "/l", Upper: d + "/u", Work: d + "/u/w", Mount: d + "/m"},
		{Lower: d + "/l", Upper: "rel/u", Work: d + "/w", Mount: d + "/m"},
	} {
		os.MkdirAll(o.Lower, 0o755)
		os.MkdirAll(o.Mount, 0o755)
		if err := o.Prepare(); err == nil {
			t.Errorf("Prepare(%+v) accepted an invalid layout", o)
		}
	}
}

func TestRemoveAllModeZero(t *testing.T) {
	d := t.TempDir()
	p := filepath.Join(d, "x")
	if err := os.MkdirAll(filepath.Join(p, "work/work/inner"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.Chmod(filepath.Join(p, "work/work/inner"), 0)
	os.Chmod(filepath.Join(p, "work/work"), 0)
	if err := RemoveAll(p); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(p); !os.IsNotExist(err) {
		t.Fatalf("still there: %v", err)
	}
}

func TestBtrfsSubvolumes(t *testing.T) {
	d := testDir(t)
	if _, err := exec.LookPath(BtrfsPath); err != nil {
		t.Skip("btrfs-progs missing")
	}
	var sfs unix.Statfs_t
	if unix.Statfs(d, &sfs) != nil || uint32(sfs.Type) != btrfsSuperMagic {
		t.Skip("test dir is not on btrfs (set LINUXFS_TEST_DIR)")
	}
	sv, snap := filepath.Join(d, "sv"), filepath.Join(d, "snap")
	if err := SubvolumeCreate(sv); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(sv, "a/b.txt"), "b\n", 0o644)
	if _, err := Snapshot(sv, snap, true); err != nil {
		t.Fatal(err)
	}
	if !IsSubvolume(sv) || !IsSubvolume(snap) || IsSubvolume(d) || IsSubvolume(filepath.Join(sv, "a")) {
		t.Fatal("IsSubvolume wrong")
	}
	if err := os.WriteFile(filepath.Join(snap, "x"), nil, 0o644); !errors.Is(err, unix.EROFS) {
		t.Fatalf("write to read-only snapshot: %v", err)
	}
	for _, p := range []string{snap, sv} {
		if err := DeleteSubvolume(p); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Lstat(p); !os.IsNotExist(err) {
			t.Fatalf("%s survived: %v", p, err)
		}
	}
}

// sortedKeys is a small debugging aid for reports.
func sortedKeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
