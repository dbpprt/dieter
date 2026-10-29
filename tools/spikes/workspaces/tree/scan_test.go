//go:build darwin || linux

package tree

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"dieter.spike/workspaces/core"
	"golang.org/x/sys/unix"
)

// testXattr is a user-settable xattr name; noiseXattr one the oracle ignores.
func testXattr() (name, noise string) {
	if runtime.GOOS == "darwin" {
		return "com.dieter.spike", "com.apple.quarantine"
	}
	return "user.spike", "user.overlay.spike"
}

func mkfile(t *testing.T, root, rel, content string) {
	t.Helper()
	p := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func mustScan(t *testing.T, root string) core.Tree {
	t.Helper()
	tr, _, err := Scan(root, ScanOptions{})
	if err != nil {
		t.Fatalf("Scan(%s): %v", root, err)
	}
	return tr
}

func checkChanges(t *testing.T, got core.ChangeSet, want map[string]core.ChangeKind) {
	t.Helper()
	gotKinds := map[string]core.ChangeKind{}
	for p, c := range got {
		gotKinds[p] = c.Kind
	}
	if want == nil {
		want = map[string]core.ChangeKind{}
	}
	if !reflect.DeepEqual(gotKinds, want) {
		t.Fatalf("changes = %v, want %v", gotKinds, want)
	}
}

func TestScanDiff(t *testing.T) {
	xname, noise := testXattr()
	nfd := "café.txt" // decomposed é
	nfc := "café.txt"  // composed é
	cases := []struct {
		name   string
		setup  func(t *testing.T, root string)
		mutate func(t *testing.T, root string)
		want   map[string]core.ChangeKind
	}{
		{
			name:   "add",
			mutate: func(t *testing.T, root string) { mkfile(t, root, "dir/new.txt", "new\n") },
			want:   map[string]core.ChangeKind{"dir/new.txt": core.Added},
		},
		{
			name:   "modify",
			mutate: func(t *testing.T, root string) { mkfile(t, root, "a.txt", "two\n") },
			want:   map[string]core.ChangeKind{"a.txt": core.Modified},
		},
		{
			name: "delete",
			mutate: func(t *testing.T, root string) {
				must(t, os.Remove(filepath.Join(root, "a.txt")))
			},
			want: map[string]core.ChangeKind{"a.txt": core.Deleted},
		},
		{
			name:   "chmod +x",
			mutate: func(t *testing.T, root string) { must(t, os.Chmod(filepath.Join(root, "a.txt"), 0o755)) },
			want:   map[string]core.ChangeKind{"a.txt": core.ModeChanged},
		},
		{
			name: "file to symlink",
			mutate: func(t *testing.T, root string) {
				must(t, os.Remove(filepath.Join(root, "a.txt")))
				must(t, os.Symlink("b.txt", filepath.Join(root, "a.txt")))
			},
			want: map[string]core.ChangeKind{"a.txt": core.TypeChanged},
		},
		{
			name: "dir to file",
			mutate: func(t *testing.T, root string) {
				must(t, os.RemoveAll(filepath.Join(root, "sub")))
				mkfile(t, root, "sub", "now a file\n")
			},
			want: map[string]core.ChangeKind{"sub": core.TypeChanged, "sub/c.txt": core.Deleted},
		},
		{
			name: "symlink retarget",
			mutate: func(t *testing.T, root string) {
				must(t, os.Remove(filepath.Join(root, "link")))
				must(t, os.Symlink("b.txt", filepath.Join(root, "link"))) // same length as a.txt
			},
			want: map[string]core.ChangeKind{"link": core.Modified},
		},
		{
			name: "xattr only",
			mutate: func(t *testing.T, root string) {
				must(t, unix.Lsetxattr(filepath.Join(root, "a.txt"), xname, []byte("v1"), 0))
			},
			want: map[string]core.ChangeKind{"a.txt": core.XattrChanged},
		},
		{
			name: "xattr value change",
			setup: func(t *testing.T, root string) {
				must(t, unix.Lsetxattr(filepath.Join(root, "a.txt"), xname, []byte("v1"), 0))
			},
			mutate: func(t *testing.T, root string) {
				must(t, unix.Lsetxattr(filepath.Join(root, "a.txt"), xname, []byte("v2"), 0))
			},
			want: map[string]core.ChangeKind{"a.txt": core.XattrChanged},
		},
		{
			name: "noise xattr ignored",
			mutate: func(t *testing.T, root string) {
				must(t, unix.Lsetxattr(filepath.Join(root, "a.txt"), noise, []byte("0081;00000000;spike;"), 0))
			},
		},
		{
			name:   "NFD name keyed as NFC",
			mutate: func(t *testing.T, root string) { mkfile(t, root, nfd, "accent\n") },
			want:   map[string]core.ChangeKind{nfc: core.Added},
		},
		{
			name: "touch without change",
			mutate: func(t *testing.T, root string) {
				now := time.Now().Add(time.Hour)
				must(t, os.Chtimes(filepath.Join(root, "a.txt"), now, now))
			},
		},
		{
			name:   "identical rewrite",
			mutate: func(t *testing.T, root string) { mkfile(t, root, "a.txt", "one\n") },
		},
		{
			name:   "empty dir added",
			mutate: func(t *testing.T, root string) { must(t, os.Mkdir(filepath.Join(root, "empty"), 0o755)) },
		},
		{
			name: "hard link edit shows on both paths",
			setup: func(t *testing.T, root string) {
				must(t, os.Link(filepath.Join(root, "b.txt"), filepath.Join(root, "b-hard.txt")))
			},
			mutate: func(t *testing.T, root string) {
				f, err := os.OpenFile(filepath.Join(root, "b-hard.txt"), os.O_WRONLY|os.O_APPEND, 0)
				must(t, err)
				_, err = f.WriteString("more\n")
				must(t, err)
				must(t, f.Close())
			},
			want: map[string]core.ChangeKind{"b.txt": core.Modified, "b-hard.txt": core.Modified},
		},
		{
			name: "fifo is other",
			mutate: func(t *testing.T, root string) {
				must(t, unix.Mkfifo(filepath.Join(root, "pipe"), 0o644))
			},
			want: map[string]core.ChangeKind{"pipe": core.Added},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			mkfile(t, root, "a.txt", "one\n")
			mkfile(t, root, "b.txt", "bee\n")
			mkfile(t, root, "sub/c.txt", "sea\n")
			must(t, os.Symlink("a.txt", filepath.Join(root, "link")))
			if tc.setup != nil {
				tc.setup(t, root)
			}
			before := mustScan(t, root)
			tc.mutate(t, root)
			after := mustScan(t, root)
			checkChanges(t, core.DiffTrees(before, after), tc.want)
			if tc.name == "NFD name keyed as NFC" {
				if _, ok := after[nfc]; !ok {
					t.Fatalf("NFC key %q missing", nfc)
				}
				if _, ok := after[nfd]; ok {
					t.Fatalf("NFD key %q present", nfd)
				}
			}
			if tc.name == "fifo is other" && after["pipe"].Type != core.Other {
				t.Fatalf("pipe type = %s", after["pipe"].Type)
			}
		})
	}
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func TestScanEntries(t *testing.T) {
	root := t.TempDir()
	mkfile(t, root, "a.txt", "hello\n")
	mkfile(t, root, ".git/HEAD", "ref: refs/heads/main\n")
	mkfile(t, root, "vendor/x/.git", "gitdir: elsewhere\n") // nested .git is kept
	mkfile(t, root, "bin/run", "#!/bin/sh\n")
	must(t, os.Chmod(filepath.Join(root, "bin/run"), 0o755))
	must(t, os.Symlink("../a.txt", filepath.Join(root, "bin/link")))
	for _, p := range []string{"vendor", "vendor/x", "bin"} {
		must(t, os.Chmod(filepath.Join(root, p), 0o755)) // independent of umask
	}
	for _, p := range []string{"a.txt", "vendor/x/.git"} {
		must(t, os.Chmod(filepath.Join(root, p), 0o644))
	}

	tr, st, err := Scan(root, ScanOptions{Workers: 3})
	must(t, err)
	want := core.Tree{
		"a.txt":         {Type: core.File, Mode: 0o644, Size: 6, Hash: "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"},
		"vendor":        {Type: core.Dir, Mode: 0o755},
		"vendor/x":      {Type: core.Dir, Mode: 0o755},
		"vendor/x/.git": {Type: core.File, Mode: 0o644, Size: 18, Hash: tr["vendor/x/.git"].Hash},
		"bin":           {Type: core.Dir, Mode: 0o755},
		"bin/run":       {Type: core.File, Mode: 0o755, Size: 10, Hash: tr["bin/run"].Hash},
		"bin/link":      {Type: core.Symlink, Size: 8, Target: "../a.txt"},
	}
	if !reflect.DeepEqual(tr, want) {
		t.Fatalf("tree =\n%v\nwant\n%v", tr, want)
	}
	if st.Entries != 7 || st.Files != 3 || st.Bytes != 6+18+10 {
		t.Fatalf("stats = %+v", st)
	}
	// A symlinked root is followed; links below it are not.
	alias := filepath.Join(t.TempDir(), "alias")
	must(t, os.Symlink(root, alias))
	if viaLink := mustScan(t, alias); !reflect.DeepEqual(viaLink, tr) {
		t.Fatalf("scan via symlinked root differs: %v", core.DiffTrees(tr, viaLink).Paths())
	}
	h, err := HashFile(filepath.Join(root, "bin/link")) // follows the link
	must(t, err)
	if h != tr["a.txt"].Hash {
		t.Fatalf("HashFile = %s, want %s", h, tr["a.txt"].Hash)
	}
}

// TestScanSurvivesChurn deletes and recreates files and directories while
// scanning; entries that vanish must be skipped, never reported as errors.
func TestScanSurvivesChurn(t *testing.T) {
	root := t.TempDir()
	for d := range 20 {
		for f := range 20 {
			mkfile(t, root, fmt.Sprintf("d%02d/f%02d.txt", d, f), "x")
		}
	}
	var stop atomic.Bool
	var wg sync.WaitGroup
	for w := range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; !stop.Load(); i++ {
				d := filepath.Join(root, fmt.Sprintf("d%02d", (i*4+w)%20))
				os.RemoveAll(d)
				os.MkdirAll(d, 0o755)
				for f := range 20 {
					os.WriteFile(filepath.Join(d, fmt.Sprintf("f%02d.txt", f)), []byte("y"), 0o644)
				}
				p := filepath.Join(root, fmt.Sprintf("swap%d", w))
				os.Remove(p)
				if i%2 == 0 {
					os.Symlink("d00", p)
				} else {
					unix.Mkfifo(p, 0o644)
				}
			}
		}()
	}
	deadline := time.Now().Add(400 * time.Millisecond)
	scans := 0
	for time.Now().Before(deadline) {
		if _, _, err := Scan(root, ScanOptions{}); err != nil {
			stop.Store(true)
			wg.Wait()
			t.Fatalf("Scan during churn: %v", err)
		}
		if _, _, err := BuildManifest(root, nil); err != nil {
			stop.Store(true)
			wg.Wait()
			t.Fatalf("BuildManifest during churn: %v", err)
		}
		scans++
	}
	stop.Store(true)
	wg.Wait()
	if scans == 0 {
		t.Fatal("no scan completed")
	}
}
