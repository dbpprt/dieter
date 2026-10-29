//go:build darwin

package darwinfs

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"

	"dieter.spike/workspaces/core"
	"golang.org/x/sys/unix"
	"golang.org/x/text/unicode/norm"
)

const externalBase = "/Volumes/External/dieter-spike/darwinfs-dev"

// scratch returns a fresh directory on the external APFS volume when it is
// present (DARWINFS_SCRATCH overrides), else a test temp dir.
func scratch(t testing.TB) string {
	t.Helper()
	base := os.Getenv("DARWINFS_SCRATCH")
	if base == "" {
		base = externalBase
	}
	if fi, err := os.Stat(base); err != nil || !fi.IsDir() {
		return t.TempDir()
	}
	d, err := os.MkdirTemp(base, "test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(d) })
	return d
}

func write(t testing.TB, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// smallTree builds a tree with nested dirs, an executable, a symlink, a hard
// link, an xattr, an NFD name and a .git directory.
func smallTree(t testing.TB, root string) {
	t.Helper()
	write(t, filepath.Join(root, "a.txt"), "alpha\n")
	write(t, filepath.Join(root, "dir/b.txt"), strings.Repeat("b", 9000))
	write(t, filepath.Join(root, "dir/sub/c.txt"), "c")
	write(t, filepath.Join(root, "run.sh"), "#!/bin/sh\n")
	must(t, os.Chmod(filepath.Join(root, "run.sh"), 0o755))
	must(t, os.Symlink("dir/b.txt", filepath.Join(root, "link")))
	must(t, os.Link(filepath.Join(root, "a.txt"), filepath.Join(root, "hard.txt")))
	must(t, unix.Setxattr(filepath.Join(root, "a.txt"), "user.spike", []byte("v"), 0))
	write(t, filepath.Join(root, norm.NFD.String("café.txt")), "nfd")
	write(t, filepath.Join(root, ".git/HEAD"), "ref: refs/heads/main\n")
	write(t, filepath.Join(root, "dir/.git/keep"), "nested .git is not skipped")
	must(t, os.Mkdir(filepath.Join(root, "empty"), 0o700))
}

func must(t testing.TB, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func readTree(t testing.TB, root string) map[string]string {
	t.Helper()
	out := map[string]string{}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		if rel == "." {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		switch {
		case d.Type()&fs.ModeSymlink != 0:
			tgt, _ := os.Readlink(p)
			out[rel] = "link:" + tgt
		case d.IsDir():
			out[rel] = fmt.Sprintf("dir:%o", info.Mode().Perm())
		default:
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			out[rel] = fmt.Sprintf("file:%o:%s", info.Mode().Perm(), b)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func TestCloneTree(t *testing.T) {
	base := scratch(t)
	src, dst := filepath.Join(base, "src"), filepath.Join(base, "dst")
	smallTree(t, src)
	d, err := CloneTree(src, dst)
	if err != nil {
		t.Fatal(err)
	}
	if d <= 0 {
		t.Fatalf("elapsed %v", d)
	}
	if got, want := readTree(t, dst), readTree(t, src); !reflect.DeepEqual(got, want) {
		t.Fatalf("clone differs:\n got %v\nwant %v", got, want)
	}
	v, err := unix.Getxattr(filepath.Join(dst, "a.txt"), "user.spike", make([]byte, 8))
	if err != nil || v != 1 {
		t.Fatalf("xattr not cloned: %d %v", v, err)
	}
	if _, err := CloneTree(src, dst); !errors.Is(err, fs.ErrExist) {
		t.Fatalf("existing dst: got %v", err)
	}
	if _, err := CloneTree(filepath.Join(src, "a.txt"), filepath.Join(base, "x")); err == nil {
		t.Fatal("CloneTree accepted a file")
	}
	// The clone is independent of its source.
	write(t, filepath.Join(dst, "dir/b.txt"), "changed")
	if b, _ := os.ReadFile(filepath.Join(src, "dir/b.txt")); len(b) != 9000 {
		t.Fatal("write to clone leaked into source")
	}
}

func TestCloneTreeCrossVolume(t *testing.T) {
	if _, err := os.Stat(externalBase); err != nil {
		t.Skip("external volume not present")
	}
	src := filepath.Join(scratch(t), "src")
	write(t, filepath.Join(src, "f"), "x")
	other := t.TempDir()
	d1, _, err1 := VolumeOf(src)
	d2, _, err2 := VolumeOf(other)
	if err1 != nil || err2 != nil || d1 == d2 {
		t.Skipf("need two volumes: %v %v %d %d", err1, err2, d1, d2)
	}
	_, err := CloneTree(src, filepath.Join(other, "dst"))
	if !errors.Is(err, ErrCrossVolume) || !errors.Is(err, unix.EXDEV) {
		t.Fatalf("want EXDEV, got %v", err)
	}
	if err := CloneFile(filepath.Join(src, "f"), filepath.Join(other, "f")); !errors.Is(err, ErrCrossVolume) {
		t.Fatalf("CloneFile cross volume: %v", err)
	}
	if _, err := ClonePerFile(src, filepath.Join(other, "cp")); !errors.Is(err, ErrCrossVolume) || !errors.Is(err, unix.EXDEV) {
		t.Fatalf("ClonePerFile cross volume (cp -c would silently copy): %v", err)
	}
	if _, err := os.Lstat(filepath.Join(other, "dst")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("failed clone left %v", err)
	}
}

func TestClonePerFile(t *testing.T) {
	base := scratch(t)
	src, dst := filepath.Join(base, "src"), filepath.Join(base, "dst")
	smallTree(t, src)
	if _, err := ClonePerFile(src+"/", dst); err != nil {
		t.Fatal(err)
	}
	if got, want := readTree(t, dst), readTree(t, src); !reflect.DeepEqual(got, want) {
		t.Fatalf("clone differs:\n got %v\nwant %v", got, want)
	}
	if _, err := ClonePerFile(src, dst); !errors.Is(err, fs.ErrExist) {
		t.Fatalf("existing dst: %v", err)
	}
}

func TestCloneFile(t *testing.T) {
	base := scratch(t)
	src := filepath.Join(base, "f")
	write(t, src, strings.Repeat("z", 20000))
	if err := CloneFile(src, filepath.Join(base, "g")); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(base, "g"))
	if len(b) != 20000 {
		t.Fatalf("clone size %d", len(b))
	}
	if err := CloneFile(base, filepath.Join(base, "dir2")); err == nil {
		t.Fatal("CloneFile accepted a directory")
	}
	if err := CloneFile(src, filepath.Join(base, "g")); !errors.Is(err, unix.EEXIST) {
		t.Fatalf("existing dst: %v", err)
	}
	m, _, err := ScanClone(base, ScanOptions{})
	must(t, err)
	if m["f"].CloneID == 0 || m["f"].CloneID != m["g"].CloneID {
		t.Fatalf("clone ids f=%d g=%d", m["f"].CloneID, m["g"].CloneID)
	}
}

func TestScanCloneMatchesLstat(t *testing.T) {
	root := scratch(t)
	smallTree(t, root)
	for i := 0; i < 1500; i++ { // force several getattrlistbulk calls in one dir
		write(t, filepath.Join(root, "many", fmt.Sprintf("file-with-a-longish-name-%05d.txt", i)), "x")
	}
	got, st, err := ScanClone(root, ScanOptions{Workers: 1})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]CEntry{}
	err = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		if rel == "." {
			return nil
		}
		var s unix.Stat_t
		must(t, unix.Lstat(p, &s))
		e := CEntry{
			Path: core.NormPath(rel), Mode: uint32(s.Mode) & 0o7777, Ino: s.Ino,
			MtimeNs: s.Mtim.Nano(), CtimeNs: s.Ctim.Nano(),
		}
		switch s.Mode & syscall.S_IFMT {
		case syscall.S_IFDIR:
			e.Type = core.Dir
		case syscall.S_IFLNK:
			e.Type, e.Size, e.LinkCount = core.Symlink, s.Size, uint32(s.Nlink)
		default:
			e.Type, e.Size, e.LinkCount = core.File, s.Size, uint32(s.Nlink)
		}
		want[e.Path] = e
		return nil
	})
	must(t, err)
	if len(got) != len(want) || st.Entries != len(want) {
		t.Fatalf("entries: got %d (stats %d) want %d", len(got), st.Entries, len(want))
	}
	if st.Calls < 3 {
		t.Errorf("expected several bulk calls, got %d", st.Calls)
	}
	for p, w := range want {
		g, ok := got[p]
		if !ok {
			t.Errorf("missing %q", p)
			continue
		}
		if g.Type != w.Type || g.Mode != w.Mode || g.Ino != w.Ino || g.MtimeNs != w.MtimeNs || g.CtimeNs != w.CtimeNs {
			t.Errorf("%s: got %+v want %+v", p, g, w)
		}
		if w.Type != core.Dir && (g.Size != w.Size || g.LinkCount != w.LinkCount) {
			t.Errorf("%s: size/links got %d/%d want %d/%d", p, g.Size, g.LinkCount, w.Size, w.LinkCount)
		}
		if w.Type == core.File && g.Size > 0 && g.AllocSize < g.Size {
			t.Errorf("%s: alloc %d < size %d", p, g.AllocSize, g.Size)
		}
	}
	if _, ok := got["café.txt"]; !ok {
		t.Error("NFD name not normalised to NFC")
	}
	if got["hard.txt"].LinkCount != 2 || got["hard.txt"].Ino != got["a.txt"].Ino {
		t.Errorf("hard link: %+v vs %+v", got["hard.txt"], got["a.txt"])
	}

	par, _, err := ScanClone(root, ScanOptions{Workers: 8})
	must(t, err)
	if !reflect.DeepEqual(par, got) {
		t.Error("Workers=8 result differs from Workers=1")
	}
	noGit, _, err := ScanClone(root, ScanOptions{Workers: 4, SkipGit: true})
	must(t, err)
	for p := range noGit {
		if p == ".git" || strings.HasPrefix(p, ".git/") {
			t.Errorf("SkipGit kept %s", p)
		}
	}
	if _, ok := noGit["dir/.git/keep"]; !ok {
		t.Error("SkipGit dropped a nested .git")
	}
	if len(noGit) != len(got)-2 {
		t.Errorf("SkipGit: %d entries, want %d", len(noGit), len(got)-2)
	}
	if _, _, err := ScanClone(filepath.Join(root, "missing"), ScanOptions{}); err == nil {
		t.Error("missing root accepted")
	}
}

func TestScanCloneIDs(t *testing.T) {
	base := scratch(t)
	src, dst := filepath.Join(base, "src"), filepath.Join(base, "dst")
	write(t, filepath.Join(src, "same.bin"), strings.Repeat("s", 64<<10))
	write(t, filepath.Join(src, "edit.bin"), strings.Repeat("e", 64<<10))
	_, err := CloneTree(src, dst)
	must(t, err)
	f, err := os.OpenFile(filepath.Join(dst, "edit.bin"), os.O_WRONLY, 0)
	must(t, err)
	_, err = f.WriteAt([]byte("X"), 100)
	must(t, err)
	must(t, f.Close())
	a, _, err := ScanClone(src, ScanOptions{})
	must(t, err)
	b, _, err := ScanClone(dst, ScanOptions{})
	must(t, err)
	if a["same.bin"].CloneID == 0 || a["same.bin"].CloneID != b["same.bin"].CloneID {
		t.Errorf("untouched clone ids differ: %d %d", a["same.bin"].CloneID, b["same.bin"].CloneID)
	}
	if !b["same.bin"].SharesAllBlocks || b["same.bin"].PrivateSize != 0 {
		t.Errorf("untouched clone: %+v", b["same.bin"])
	}
	if a["edit.bin"].CloneID == b["edit.bin"].CloneID {
		t.Errorf("edited clone kept clone id %d", a["edit.bin"].CloneID)
	}
	if b["edit.bin"].SharesAllBlocks || b["edit.bin"].PrivateSize == 0 {
		t.Errorf("edited clone: %+v", b["edit.bin"])
	}
}

func TestScanCloneSkipBlockStats(t *testing.T) {
	base := scratch(t)
	write(t, filepath.Join(base, "a"), "x")
	must(t, CloneFile(filepath.Join(base, "a"), filepath.Join(base, "b")))
	m, _, err := ScanClone(base, ScanOptions{SkipBlockStats: true})
	must(t, err)
	if m["a"].CloneID == 0 || m["a"].CloneID != m["b"].CloneID {
		t.Errorf("clone ids: %+v %+v", m["a"], m["b"])
	}
	if m["b"].SharesAllBlocks || m["b"].Size != 1 {
		t.Errorf("SkipBlockStats entry: %+v", m["b"])
	}
}

func TestEventsSince(t *testing.T) {
	dir := scratch(t)
	id := CurrentEventID()
	if id == 0 {
		t.Fatal("CurrentEventID returned 0")
	}
	want := map[string]bool{}
	for i := 0; i < 20; i++ {
		p := filepath.Join(dir, fmt.Sprintf("f%02d", i))
		write(t, p, "x")
		rp, err := filepath.EvalSymlinks(p)
		must(t, err)
		want[rp] = true
	}
	start := time.Now()
	evs, err := EventsSince([]string{dir}, id, 10*time.Second)
	must(t, err)
	// A replay that starts right after the writes can miss events fseventsd
	// has not delivered yet: the event-id barrier taken at call time does not
	// cover writes still in flight. Callers need a settle delay or a marker
	// write; the test records the race and replays once more.
	if n := countPaths(evs, want); n < len(want) {
		t.Logf("first replay saw %d of %d paths; replaying after 500ms", n, len(want))
		time.Sleep(500 * time.Millisecond)
		evs, err = EventsSince([]string{dir}, id, 10*time.Second)
		must(t, err)
	}
	hd := false
	got := map[string]FSEvent{}
	for _, e := range evs {
		if e.HistoryDone() {
			hd = true
			continue
		}
		if e.ID <= id {
			t.Errorf("event %d not after %d", e.ID, id)
		}
		got[e.Path] = e
	}
	if !hd {
		t.Error("no HistoryDone sentinel")
	}
	for p := range want {
		e, ok := got[p]
		if !ok {
			t.Errorf("missing event for %s", p)
			continue
		}
		if !e.Created() || !e.ItemIsFile() {
			t.Errorf("%s flags %s", p, FlagString(e.Flags))
		}
	}
	t.Logf("%d events in %v", len(evs), time.Since(start))
	if _, err := EventsSince(nil, id, time.Second); err == nil {
		t.Error("empty paths accepted")
	}
	if _, err := EventsSince([]string{dir}, ^uint64(0), time.Second); err == nil {
		t.Error("SinceNow accepted")
	}
}

func TestVolumeOf(t *testing.T) {
	dev, mnt, err := VolumeOf(t.TempDir())
	must(t, err)
	if dev == 0 || mnt == "" {
		t.Fatalf("dev %d mount %q", dev, mnt)
	}
	if _, err := os.Stat(externalBase); err == nil {
		d2, m2, err := VolumeOf(externalBase)
		must(t, err)
		if m2 != "/Volumes/External" || d2 == dev {
			t.Errorf("external: dev %d mount %q (temp dev %d mount %q)", d2, m2, dev, mnt)
		}
	}
	if _, _, err := VolumeOf("/nonexistent/x"); err == nil {
		t.Error("missing path accepted")
	}
}

func TestFlagString(t *testing.T) {
	e := FSEvent{Flags: FlagItemCreated | FlagItemModified | FlagItemIsFile}
	if s := FlagString(e.Flags); s != "Created|Modified|IsFile" {
		t.Errorf("FlagString %q", s)
	}
	if !e.Created() || !e.Modified() || e.Removed() || e.Lossy() {
		t.Error("flag helpers")
	}
	if !(FSEvent{Flags: FlagMustScanSubDirs}).Lossy() {
		t.Error("MustScanSubDirs not lossy")
	}
}

func countPaths(evs []FSEvent, want map[string]bool) int {
	seen := map[string]bool{}
	for _, e := range evs {
		if want[e.Path] {
			seen[e.Path] = true
		}
	}
	return len(seen)
}
