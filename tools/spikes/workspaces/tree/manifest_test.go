//go:build darwin || linux

package tree

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
	"time"

	"dieter.spike/workspaces/core"
	"golang.org/x/sys/unix"
)

// settle waits past the racy window so entries written so far are trusted
// by the next manifest built from them.
func settle() { time.Sleep(time.Duration(racySlackNs) + 20*time.Millisecond) }

func manifestFixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for i := range 30 {
		mkfile(t, root, fmt.Sprintf("d%d/f%02d.txt", i%3, i), fmt.Sprintf("content %d\n", i))
	}
	mkfile(t, root, "bin/run", "#!/bin/sh\n")
	must(t, os.Chmod(filepath.Join(root, "bin/run"), 0o755))
	must(t, os.Symlink("../d0/f00.txt", filepath.Join(root, "bin/link")))
	xname, _ := testXattr()
	must(t, unix.Lsetxattr(filepath.Join(root, "d1/f01.txt"), xname, []byte("tagged"), 0))
	mkfile(t, root, ".git/config", "[core]\n")
	settle()
	return root
}

func mustBuild(t *testing.T, root string, prev *Manifest) (*Manifest, ManifestStats) {
	t.Helper()
	m, st, err := BuildManifest(root, prev)
	if err != nil {
		t.Fatalf("BuildManifest(%s): %v", root, err)
	}
	return m, st
}

func TestManifestMatchesScan(t *testing.T) {
	root := manifestFixture(t)
	m, st := mustBuild(t, root, nil)
	if st.Rehashed != 31 || st.Files != 31 {
		t.Fatalf("cold stats = %+v, want 31 files hashed", st)
	}
	if got, want := m.Tree(), mustScan(t, root); !reflect.DeepEqual(got, want) {
		t.Fatalf("manifest tree differs from Scan:\n%v\n%v", got, want)
	}
	if m.Tree()["d1/f01.txt"].Xattrs == "" {
		t.Fatal("xattr not recorded")
	}
}

func TestManifestTouchWithoutChange(t *testing.T) {
	root := manifestFixture(t)
	m1, _ := mustBuild(t, root, nil)
	now := time.Now()
	must(t, os.Chtimes(filepath.Join(root, "d0/f00.txt"), now, now))
	settle()
	m2, st := mustBuild(t, root, m1)
	if st.Rehashed != 1 {
		t.Fatalf("rehashed = %d, want 1", st.Rehashed)
	}
	checkChanges(t, core.DiffTrees(m1.Tree(), m2.Tree()), nil)
	m3, st := mustBuild(t, root, m2)
	if st.Rehashed != 0 {
		t.Fatalf("warm rehashed = %d, want 0", st.Rehashed)
	}
	checkChanges(t, core.DiffTrees(m1.Tree(), m3.Tree()), nil)
}

func TestManifestSameSizeRewriteRestoredMtime(t *testing.T) {
	root := manifestFixture(t)
	p := filepath.Join(root, "d2/f02.txt")
	m1, _ := mustBuild(t, root, nil)
	fi, err := os.Stat(p)
	must(t, err)
	must(t, os.WriteFile(p, []byte("CONTENT 2\n"), 0o644)) // same size
	must(t, os.Chtimes(p, fi.ModTime(), fi.ModTime()))
	m2, st := mustBuild(t, root, m1)
	before, after := m1.Entries["d2/f02.txt"], m2.Entries["d2/f02.txt"]
	if before.Size != after.Size || before.MtimeNs != after.MtimeNs || before.Ino != after.Ino {
		t.Fatalf("setup: size/mtime/ino should be unchanged: %+v vs %+v", before, after)
	}
	if before.CtimeNs == after.CtimeNs {
		t.Fatal("setup: ctime did not change")
	}
	if st.Rehashed != 1 {
		t.Fatalf("rehashed = %d, want 1", st.Rehashed)
	}
	checkChanges(t, core.DiffTrees(m1.Tree(), m2.Tree()), map[string]core.ChangeKind{"d2/f02.txt": core.Modified})
}

func TestManifestXattrOnlyChange(t *testing.T) {
	root := manifestFixture(t)
	m1, _ := mustBuild(t, root, nil)
	xname, _ := testXattr()
	must(t, unix.Lsetxattr(filepath.Join(root, "d0/f03.txt"), xname, []byte("v"), 0))
	must(t, unix.Lsetxattr(filepath.Join(root, "d2"), xname, []byte("v"), 0))
	m2, _ := mustBuild(t, root, m1)
	checkChanges(t, core.DiffTrees(m1.Tree(), m2.Tree()), map[string]core.ChangeKind{"d0/f03.txt": core.XattrChanged})
	if m2.Entries["d2"].Xattrs == "" {
		t.Fatal("directory xattr not re-read after its ctime changed")
	}
}

// TestManifestRacyEntryRehashed: an entry stamped at or after the walk that
// recorded it cannot be trusted by the stat comparison and is re-read.
func TestManifestRacyEntryRehashed(t *testing.T) {
	root := manifestFixture(t)
	future := time.Now().Add(time.Hour)
	must(t, os.Chtimes(filepath.Join(root, "d0/f06.txt"), future, future))
	m1, _ := mustBuild(t, root, nil)
	_, st := mustBuild(t, root, m1)
	if st.Rehashed != 1 {
		t.Fatalf("rehashed = %d, want 1 (the racy entry)", st.Rehashed)
	}
}

func cloneTree(t *testing.T, src, dst string) {
	t.Helper()
	var cmd *exec.Cmd
	if runtime.GOOS == "darwin" {
		cmd = exec.Command("/bin/cp", "-c", "-R", src, dst)
	} else {
		cmd = exec.Command("cp", "-a", src, dst)
	}
	cmd.Env = gitEnv()
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("%v: %v: %s", cmd.Args, err, out)
	}
}

func TestInheritManifest(t *testing.T) {
	root := manifestFixture(t)
	base, _ := mustBuild(t, root, nil)
	view := filepath.Join(t.TempDir(), "view")
	cloneTree(t, root, view)
	settle() // clone ctimes must not be racy for the later warm build

	inh, st, err := InheritManifest(base, view)
	must(t, err)
	if st.Rehashed != 0 {
		t.Fatalf("inherit rehashed = %d, want 0", st.Rehashed)
	}
	if inh.Root == base.Root {
		t.Fatal("inherited manifest kept the base root")
	}
	if inh.Entries["d0/f00.txt"].Ino == base.Entries["d0/f00.txt"].Ino {
		t.Fatal("inherited entry kept the base inode")
	}
	checkChanges(t, core.DiffTrees(base.Tree(), inh.Tree()), nil)
	if got, want := inh.Tree(), mustScan(t, view); !reflect.DeepEqual(got, want) {
		t.Fatalf("inherited tree differs from Scan of the view:\n%v\n%v", got, want)
	}

	// The view's own manifest is warm: a later change costs one hash.
	settle()
	f, err := os.OpenFile(filepath.Join(view, "d1/f04.txt"), os.O_WRONLY|os.O_APPEND, 0)
	must(t, err)
	_, err = f.WriteString("agent edit\n")
	must(t, err)
	must(t, f.Close())
	after, st := mustBuild(t, view, inh)
	if st.Rehashed != 1 {
		t.Fatalf("rehashed after edit = %d, want 1", st.Rehashed)
	}
	checkChanges(t, core.DiffTrees(base.Tree(), after.Tree()), map[string]core.ChangeKind{"d1/f04.txt": core.Modified})
}

func TestInheritManifestHashesDifferences(t *testing.T) {
	root := manifestFixture(t)
	base, _ := mustBuild(t, root, nil)
	view := filepath.Join(t.TempDir(), "view")
	cloneTree(t, root, view)
	mkfile(t, view, "d0/f00.txt", "changed in the view before inheriting\n")
	mkfile(t, view, "new.txt", "new\n")
	inh, st, err := InheritManifest(base, view)
	must(t, err)
	if st.Rehashed != 2 {
		t.Fatalf("rehashed = %d, want 2", st.Rehashed)
	}
	checkChanges(t, core.DiffTrees(base.Tree(), inh.Tree()), map[string]core.ChangeKind{
		"d0/f00.txt": core.Modified, "new.txt": core.Added,
	})
}

func TestManifestSaveLoad(t *testing.T) {
	root := manifestFixture(t)
	m, _ := mustBuild(t, root, nil)
	p := filepath.Join(t.TempDir(), "m.json")
	must(t, m.Save(p))
	got, err := LoadManifest(p)
	must(t, err)
	if got.Root != m.Root || !got.CreatedAt.Equal(m.CreatedAt) || !reflect.DeepEqual(got.Entries, m.Entries) {
		t.Fatal("manifest did not round-trip")
	}
	_, st := mustBuild(t, root, got)
	if st.Rehashed != 0 {
		t.Fatalf("rehashed with loaded manifest = %d, want 0", st.Rehashed)
	}
}
