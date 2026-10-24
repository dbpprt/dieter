//go:build linux

package linuxfs

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"dieter.spike/workspaces/core"
	"golang.org/x/sys/unix"
)

// TestExperiments runs the garuda experiments against a scratch directory
// (LINUXFS_EXP) and appends results to LINUXFS_EXP/report.txt. Select parts
// with -run 'TestExperiments/(base|git|ops|late|escape|concurrent|nesting|turns|cost)';
// LINUXFS_EXP_CLEAN=1 enables the final cleanup.
func TestExperiments(t *testing.T) {
	root := os.Getenv("LINUXFS_EXP")
	if root == "" {
		t.Skip("set LINUXFS_EXP to a scratch directory")
	}
	requireBwrap(t)
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	rep, err := os.OpenFile(filepath.Join(root, "report.txt"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer rep.Close()
	x := &exp{root: root, repo: root + "/repo", snap: root + "/base-snap", big: root + "/big", rep: rep}
	for _, s := range []struct {
		name string
		fn   func(*testing.T)
	}{
		{"base", x.base}, {"git", x.git}, {"ops", x.ops}, {"late", x.late}, {"escape", x.escape},
		{"concurrent", x.concurrent}, {"nesting", x.nesting}, {"turns", x.turns}, {"cost", x.cost},
		{"cleanup", x.cleanup},
	} {
		t.Run(s.name, s.fn)
	}
}

type exp struct {
	root, repo, snap, big string
	rep                   *os.File
	mu                    sync.Mutex
	lowerTree             core.Tree
}

var gitEnv = []string{
	"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1",
	"GIT_AUTHOR_NAME=spike", "GIT_AUTHOR_EMAIL=spike@example.invalid",
	"GIT_COMMITTER_NAME=spike", "GIT_COMMITTER_EMAIL=spike@example.invalid",
	// No background auto-gc/maintenance: it would be a late writer.
	"GIT_CONFIG_COUNT=2", "GIT_CONFIG_KEY_0=gc.auto", "GIT_CONFIG_VALUE_0=0",
	"GIT_CONFIG_KEY_1=maintenance.auto", "GIT_CONFIG_VALUE_1=false",
}

func (x *exp) logf(format string, a ...any) {
	x.mu.Lock()
	defer x.mu.Unlock()
	fmt.Fprintf(x.rep, format+"\n", a...)
}

func ms(d time.Duration) string { return fmt.Sprintf("%.0fms", float64(d.Microseconds())/1000) }

func exists(p string) bool { _, err := os.Lstat(p); return err == nil }

// drop removes a scratch path, deleting subvolumes properly.
func (x *exp) drop(t testing.TB, p string) time.Duration {
	t.Helper()
	start := time.Now()
	if !exists(p) {
		return 0
	}
	var err error
	if IsSubvolume(p) {
		err = DeleteSubvolume(p)
	} else {
		err = RemoveAll(p)
	}
	if err != nil {
		t.Fatalf("drop %s: %v", p, err)
	}
	return time.Since(start)
}

// genFiles writes nd*nf small files below root using pattern(d, f).
func genFiles(t testing.TB, root string, nd, nf int, pattern string, content func(d, f int) string) {
	t.Helper()
	err := parallel(nd, func(_ []byte, d int) error {
		for f := range nf {
			p := filepath.Join(root, fmt.Sprintf(pattern, d, f))
			if f == 0 {
				if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
					return err
				}
			}
			if err := os.WriteFile(p, []byte(content(d, f)), 0o644); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func run(dir string, env []string, name string, args ...string) (string, time.Duration, error) {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Env = cleanEnv(env...)
	start := time.Now()
	out, err := cmd.CombinedOutput()
	if err != nil {
		err = fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), time.Since(start), err
}

func mustRun(t testing.TB, dir string, env []string, name string, args ...string) (string, time.Duration) {
	t.Helper()
	out, d, err := run(dir, env, name, args...)
	if err != nil {
		t.Fatal(err)
	}
	return out, d
}

// ensureRepo builds the synthetic checkout (a subvolume): 20000 tracked
// files in src/, a 40000-file ignored node_modules/, committed; and its
// read-only snapshot, the frozen lower.
func (x *exp) ensureRepo(t testing.TB) {
	t.Helper()
	if exists(x.repo+"/.git/HEAD") && exists(x.snap) {
		return
	}
	x.drop(t, x.snap)
	x.drop(t, x.repo)
	if err := SubvolumeCreate(x.repo); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	genFiles(t, x.repo, 200, 100, "src/d%03d/f%03d.txt", func(d, f int) string {
		return fmt.Sprintf("file %d/%d\nline a\nline b\n", d, f)
	})
	genFiles(t, x.repo+"/node_modules", 400, 100, "pkg-%d/f%03d.js", func(d, f int) string {
		return fmt.Sprintf("module.exports = %d;\n", d*1000+f)
	})
	// The generator names packages pkg-0..pkg-399; pkg-1 is the one ops remove.
	writeFile(t, x.repo+"/.gitignore", "node_modules/\n", 0o644)
	writeFile(t, x.repo+"/bin/tool.sh", "#!/bin/sh\necho tool\n", 0o755)
	if err := os.Symlink("src/d000/f000.txt", x.repo+"/link-a"); err != nil {
		t.Fatal(err)
	}
	gen := time.Since(start)
	time.Sleep(2 * time.Second) // keep every file older than the index (racy git)
	mustRun(t, x.repo, gitEnv, "git", "init", "-q", "-b", "main")
	_, add := mustRun(t, x.repo, gitEnv, "git", "add", "-A")
	mustRun(t, x.repo, gitEnv, "git", "commit", "-q", "-m", "base")
	mustRun(t, x.repo, gitEnv, "git", "status", "--porcelain")
	took, err := Snapshot(x.repo, x.snap, true)
	if err != nil {
		t.Fatal(err)
	}
	x.lowerTree = nil
	x.logf("generated repo: files %s, git add %s, read-only snapshot %s", ms(gen), ms(add), ms(took))
}

func (x *exp) ensureBig(t testing.TB) {
	t.Helper()
	if exists(x.big + "/d1499/f099.txt") {
		return
	}
	x.drop(t, x.big)
	if err := SubvolumeCreate(x.big); err != nil {
		t.Fatal(err)
	}
	genFiles(t, x.big, 1500, 100, "d%04d/f%03d.txt", func(d, f int) string { return fmt.Sprintf("big %d %d\n", d, f) })
}

func (x *exp) lower(t testing.TB) core.Tree {
	t.Helper()
	x.ensureRepo(t)
	if x.lowerTree == nil {
		start := time.Now()
		tree, err := ScanTree(x.snap)
		if err != nil {
			t.Fatal(err)
		}
		x.lowerTree = tree
		x.logf("ScanTree(lower snapshot): %d entries in %s", len(tree), ms(time.Since(start)))
	}
	return x.lowerTree
}

// overlay returns a fresh session layout over lower mounted at the repo.
func (x *exp) overlay(t testing.TB, name, lower string) Overlay {
	t.Helper()
	s := filepath.Join(x.root, "s", name)
	if err := RemoveAll(s); err != nil {
		t.Fatal(err)
	}
	return Overlay{Lower: lower, Upper: s + "/upper", Work: s + "/work", Mount: x.repo}
}

// runIn runs script in the overlay with output in a file, so background
// jobs holding stdout do not block the wait.
func runIn(o Overlay, argv []string, script string) (string, int, time.Duration, error) {
	if err := o.Prepare(); err != nil {
		return "", -1, 0, err
	}
	f, err := os.CreateTemp("", "linuxfs-out-")
	if err != nil {
		return "", -1, 0, err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	if argv == nil {
		argv = o.Wrap()
	}
	argv = append(argv, "sh", "-c", script)
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = o.Mount
	cmd.Env = cleanEnv(gitEnv...)
	cmd.Stdout, cmd.Stderr = f, f
	start := time.Now()
	err = cmd.Run()
	took := time.Since(start)
	rc := 0
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		rc, err = ee.ExitCode(), nil
	}
	out, _ := os.ReadFile(f.Name())
	return strings.TrimSpace(string(out)), rc, took, err
}

func oneLine(s string) string {
	s = strings.Join(strings.Fields(strings.ReplaceAll(s, "\n", " ¶ ")), " ")
	if len(s) > 220 {
		s = s[:220] + "…"
	}
	return s
}

func countEntries(t testing.TB, root string) int {
	n := 0
	if err := walk(root, func(node) bool { n++; return true }); err != nil {
		t.Fatal(err)
	}
	return n
}

func (x *exp) base(t *testing.T) {
	x.ensureRepo(t)
	x.ensureBig(t)
	x.logf("\n## base creation (warm page cache, no fsync; source is a rw subvolume)")
	x.logf("| tree | entries | method | create | copy fallbacks | delete |")
	copies := filepath.Join(x.root, "copies")
	if err := os.MkdirAll(copies, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, src := range []struct{ name, path string }{{"repo 20k+40k+.git", x.repo}, {"tree 150k", x.big}} {
		n := countEntries(t, src.path)
		tag := strings.Fields(src.name)[0]
		keep := tag == "repo"
		row := func(method string, create time.Duration, fb string, del time.Duration) {
			ds := ms(del)
			if del == 0 {
				ds = "kept"
			}
			x.logf("| %s | %d | %s | %s | %s | %s |", src.name, n, method, ms(create), fb, ds)
		}
		// cp -a --reflink=never: a real copy.
		d := filepath.Join(copies, tag+"-cpnever")
		x.drop(t, d)
		_, took := mustRun(t, "", nil, "cp", "-a", "--reflink=never", src.path, d)
		row("cp -a --reflink=never", took, "-", x.drop(t, d))
		// cp -a: coreutils 9 defaults to --reflink=auto.
		d = filepath.Join(copies, tag+"-cpa")
		if keep {
			d = x.root + "/base-cpa"
		}
		x.drop(t, d)
		_, took = mustRun(t, "", nil, "cp", "-a", src.path, d)
		var del time.Duration
		if !keep {
			del = x.drop(t, d)
		}
		row("cp -a (reflink=auto)", took, "-", del)
		// ReflinkTree.
		d = filepath.Join(copies, tag+"-reflink")
		if keep {
			d = x.root + "/base-reflink"
		}
		x.drop(t, d)
		took, fb, err := ReflinkTree(src.path, d)
		if err != nil {
			t.Fatal(err)
		}
		del = 0
		if !keep {
			del = x.drop(t, d)
		}
		row("ReflinkTree (FICLONE)", took, fmt.Sprint(fb), del)
		// Snapshots; unprivileged delete empties them file by file.
		for _, ro := range []bool{true, false} {
			d = filepath.Join(copies, fmt.Sprintf("%s-snap-%v", tag, ro))
			x.drop(t, d)
			took, err := Snapshot(src.path, d, ro)
			if err != nil {
				t.Fatal(err)
			}
			row(fmt.Sprintf("btrfs snapshot readonly=%v", ro), took, "-", x.drop(t, d))
		}
	}
	// What an unprivileged "btrfs subvolume delete" says.
	d := filepath.Join(copies, "probe-snap")
	x.drop(t, d)
	if _, err := Snapshot(x.repo, d, true); err != nil {
		t.Fatal(err)
	}
	out, _, err := run("", nil, BtrfsPath, "subvolume", "delete", d)
	x.logf("unprivileged `btrfs subvolume delete`: err=%v out=%s", err != nil, oneLine(out))
	x.drop(t, d)
}

func statLine(p string) string {
	var st unix.Stat_t
	if err := unix.Lstat(p, &st); err != nil {
		return err.Error()
	}
	return fmt.Sprintf("dev=%d ino=%d ctime=%d.%09d", st.Dev, st.Ino, st.Ctim.Sec, st.Ctim.Nsec)
}

func (x *exp) ensureCopies(t testing.TB) {
	t.Helper()
	if !exists(x.root + "/base-cpa/.git/HEAD") {
		x.drop(t, x.root+"/base-cpa")
		mustRun(t, "", nil, "cp", "-a", x.repo, x.root+"/base-cpa")
	}
	if !exists(x.root + "/base-reflink/.git/HEAD") {
		x.drop(t, x.root+"/base-reflink")
		if _, _, err := ReflinkTree(x.repo, x.root+"/base-reflink"); err != nil {
			t.Fatal(err)
		}
	}
}

const gitProbe = `F=src/d000/f000.txt
stat -c 'inside dev=%d ino=%i ctime=%Z' $F
git ls-files --debug $F | awk '/ctime|ino/{printf "index %s ", $0}'; echo
s=$(date +%s%N); n=$(git status --porcelain | wc -l); e=$(date +%s%N); echo "first=$(( (e-s)/1000000 ))ms lines=$n"
s=$(date +%s%N); git status --porcelain >/dev/null; e=$(date +%s%N); echo "second=$(( (e-s)/1000000 ))ms"`

func (x *exp) git(t *testing.T) {
	x.ensureRepo(t)
	x.ensureCopies(t)
	x.logf("\n## git status inside the overlay (Mount = checkout path)")
	x.logf("host checkout %s: %s", "src/d000/f000.txt", statLine(x.repo+"/src/d000/f000.txt"))
	out, took, err := run(x.repo, gitEnv, "sh", "-c", "git status --porcelain | wc -l")
	x.logf("host git status (no overlay): %s, lines=%s err=%v", ms(took), strings.TrimSpace(out), err)
	for _, l := range []struct{ name, path string }{
		{"btrfs ro snapshot", x.snap}, {"ReflinkTree copy", x.root + "/base-reflink"}, {"cp -a copy", x.root + "/base-cpa"},
	} {
		o := x.overlay(t, "git-"+strings.Fields(l.name)[0], l.path)
		out, rc, took, err := runIn(o, nil, gitProbe)
		if err != nil {
			t.Fatal(err)
		}
		_, ust, err := o.ReadUpper()
		if err != nil {
			t.Fatal(err)
		}
		x.logf("- lower=%s (%s): session %s rc=%d, upper .git paths=%d, .git/index rewritten=%v\n  %s",
			l.name, statLine(l.path+"/src/d000/f000.txt"), ms(took), rc, ust.GitInternal,
			exists(o.Upper+"/.git/index"), oneLine(out))
	}
}

// upperSummary lists counts and up to three interesting upper entries.
func upperSummary(u map[string]UpperEntry, st UpperStats) string {
	var marks []string
	for _, p := range sortedKeys(u) {
		e := u[p]
		switch {
		case e.Deleted:
			marks = append(marks, "wh:"+p)
		case e.Opaque:
			marks = append(marks, "opaque:"+p)
		case e.Entry.Type == core.File:
			marks = append(marks, "f:"+p)
		case e.Entry.Type == core.Symlink:
			marks = append(marks, "l:"+p)
		case e.Entry.Type == core.Other:
			marks = append(marks, "o:"+p)
		}
	}
	more := ""
	if len(marks) > 3 {
		more = fmt.Sprintf(" +%d", len(marks)-3)
		marks = marks[:3]
	}
	return fmt.Sprintf("F%d D%d L%d W%d O%d git%d %s%s", st.Files, st.Dirs, st.Symlinks, st.Whiteouts, st.Opaque,
		st.GitInternal, strings.Join(marks, " "), more)
}

func csSummary(cs core.ChangeSet) string {
	if len(cs) == 0 {
		return "none"
	}
	byKind := map[core.ChangeKind][]string{}
	for _, p := range cs.Paths() {
		byKind[cs[p].Kind] = append(byKind[cs[p].Kind], p)
	}
	kinds := make([]string, 0, len(byKind))
	for k := range byKind {
		kinds = append(kinds, string(k))
	}
	sort.Strings(kinds)
	var parts []string
	for _, k := range kinds {
		ps := byKind[core.ChangeKind(k)]
		parts = append(parts, fmt.Sprintf("%s×%d(%s)", k, len(ps), ps[0]))
	}
	return strings.Join(parts, " ")
}

func scoreLine(truth, got core.ChangeSet) (string, bool) {
	s := core.Compare(truth, got, nil)
	ok := s.FP == 0 && s.FN == 0 && s.KindMismatch == 0
	verdict := "yes"
	if !ok {
		verdict = fmt.Sprintf("NO tp=%d fp=%d fn=%d kind=%d missed=%v extra=%v", s.TP, s.FP, s.FN, s.KindMismatch,
			head(s.Missed), head(s.Extra))
	}
	return verdict, ok
}

func head(s []string) []string {
	if len(s) > 3 {
		return s[:3]
	}
	return s
}

var expOps = []struct{ name, script string }{
	{"echo x >> tracked", "echo x >> src/d000/f000.txt"},
	{"sed -i", "sed -i s/line/LINE/ src/d000/f001.txt"},
	{"rm file", "rm src/d000/f002.txt"},
	{"mv file", "mv src/d000/f003.txt src/d000/f003-moved.txt"},
	{"mv dir dir2", "mv src/d001 src/d001-moved"},
	{"os.rename(dir)", `python3 -c 'import os
try:
    os.rename("src/d002", "src/d002-r"); print("renamed")
except OSError as e:
    print("errno", e.errno, e.strerror)'`},
	{"chmod +x", "chmod +x src/d000/f004.txt"},
	{"touch", "touch src/d000/f005.txt"},
	{"identical rewrite", `python3 -c 'p="src/d000/f006.txt"; d=open(p,"rb").read(); open(p,"wb").write(d)'`},
	{"ln a b (hardlink)", "ln src/d000/f007.txt src/d000/f007-hl.txt"},
	{"setfattr user.spike", "setfattr -n user.spike -v 1 src/d000/f008.txt"},
	{"rm -rf node_modules/pkg-1", "rm -rf node_modules/pkg-1"},
	{"new files", "echo new > src/new.txt && mkdir -p src/newdir/a && echo n > src/newdir/a/n.txt"},
	{"mkdir (empty)", "mkdir src/emptydir"},
	{"new symlink", "ln -s d000/f000.txt src/newlink"},
	{"symlink retarget", "ln -sfn src/d000/f001.txt link-a"},
	{"opaque dir recreate", "rm -rf src/d003 && mkdir src/d003 && echo z > src/d003/z.txt"},
	{"file -> dir", "rm src/d000/f009.txt && mkdir src/d000/f009.txt"},
	{"chmod 000", "chmod 000 src/d000/f010.txt"},
	{"git commit", "echo c >> src/d000/f011.txt && git add -A && git commit -qm x && echo committed"},
}

func (x *exp) ops(t *testing.T) {
	lower := x.lower(t)
	x.logf("\n## operations (fresh session each; truth = DiffTrees(lower, in-namespace scan))")
	x.logf("| op | upper content | reported (Changes) | correct | copy-up identical | effective==merged | note |")
	for i, op := range expOps {
		o := x.overlay(t, fmt.Sprintf("op%02d", i), x.snap)
		out, rc, merged := sessionEnv(t, o, gitEnv, op.script)
		upper, ust, err := o.ReadUpper()
		if err != nil {
			t.Fatal(err)
		}
		got, cst, err := o.Changes(lower)
		if err != nil {
			t.Fatal(err)
		}
		verdict, _ := scoreLine(core.DiffTrees(lower, merged), got)
		eff := o.Effective(lower, upper)
		effOK := len(core.DiffTrees(merged, eff)) == 0 && len(eff) == len(merged)
		note := oneLine(out)
		if rc != 0 {
			note = fmt.Sprintf("rc=%d %s", rc, note)
		}
		x.logf("| %s | %s | %s | %s | %d | %v | %s |", op.name, upperSummary(upper, ust), csSummary(got), verdict,
			cst.Identical, effOK, note)
		RemoveAll(filepath.Dir(o.Upper))
	}
}

func lateCheck(o Overlay) string {
	if exists(o.Upper + "/late.txt") {
		return "WRITTEN to upper"
	}
	return "not written"
}

func (x *exp) late(t *testing.T) {
	x.ensureRepo(t)
	x.logf("\n## late writer (writer sleeps 2s; checked 3.5s after start)")
	bg := "(sleep 2; echo late > late.txt) & echo started"
	ss := "setsid nohup sh -c 'sleep 2; echo late > late.txt' >/dev/null 2>&1 & echo started"
	for i, v := range []struct {
		name, script string
		extra        []string
		killParent   bool
		noDie        bool
	}{
		{"bg job, default wrap", bg, nil, false, false},
		{"setsid+nohup, default wrap", ss, nil, false, false},
		{"bg job, --unshare-pid", bg, []string{"--unshare-pid"}, false, false},
		{"setsid+nohup, --unshare-pid", ss, []string{"--unshare-pid"}, false, false},
		{"foreground writer, parent SIGKILLed, --die-with-parent", "sleep 2; echo late > late.txt", nil, true, false},
		{"foreground writer, parent SIGKILLed, no --die-with-parent", "sleep 2; echo late > late.txt", nil, true, true},
	} {
		o := x.overlay(t, fmt.Sprintf("late%d", i), x.snap)
		argv := o.WrapWith(v.extra...)
		if v.noDie {
			var keep []string
			for _, a := range argv {
				if a != "--die-with-parent" {
					keep = append(keep, a)
				}
			}
			argv = keep
		}
		start := time.Now()
		var out string
		var rc int
		var err error
		if v.killParent {
			if err = o.Prepare(); err != nil {
				t.Fatal(err)
			}
			full := append(append([]string{"sh", "-c", `"$@" & sleep 0.5; kill -9 $$`, "sh"}, argv...), "sh", "-c", v.script)
			cmd := exec.Command(full[0], full[1:]...)
			cmd.Dir, cmd.Env = o.Mount, cleanEnv()
			err = cmd.Run()
			out = fmt.Sprint(err)
			err = nil
		} else {
			out, rc, _, err = runIn(o, argv, v.script)
		}
		if err != nil {
			t.Fatal(err)
		}
		returned := time.Since(start)
		time.Sleep(3500*time.Millisecond - returned)
		x.logf("- %s: command returned after %s (rc=%d, %s); late.txt %s; on host checkout: %v", v.name, ms(returned),
			rc, oneLine(out), lateCheck(o), exists(x.repo+"/late.txt"))
	}
}

func (x *exp) escape(t *testing.T) {
	x.ensureRepo(t)
	x.logf("\n## escapes")
	sent := filepath.Join(x.root, "sentinel")
	RemoveAll(sent)
	o := x.overlay(t, "escape1", x.snap)
	out, rc, _, err := runIn(o, nil, fmt.Sprintf("mkdir -p %s && echo inside > %s/x && echo wrote", sent, sent))
	if err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(sent + "/x")
	x.logf("- write outside the overlay (%s): rc=%d out=%q; host sees %q", sent+"/x", rc, out, strings.TrimSpace(string(data)))
	// Host writes into the real checkout while a session runs.
	o = x.overlay(t, "escape2", x.snap)
	probe := "src/d000/f012.txt"
	orig, _ := os.ReadFile(x.repo + "/" + probe)
	done := make(chan struct{})
	go func() {
		defer close(done)
		time.Sleep(400 * time.Millisecond)
		os.WriteFile(x.repo+"/hostnew.txt", []byte("host\n"), 0o644)
		f, _ := os.OpenFile(x.repo+"/"+probe, os.O_APPEND|os.O_WRONLY, 0)
		f.WriteString("HOST\n")
		f.Close()
	}()
	out, rc, _, err = runIn(o, nil, "sleep 1.5; cat hostnew.txt 2>&1; tail -1 "+probe+"; ls hostnew.txt 2>&1 | head -1")
	<-done
	if err != nil {
		t.Fatal(err)
	}
	hostTail, _ := os.ReadFile(x.repo + "/" + probe)
	x.logf("- host writes hostnew.txt + appends HOST to %s during session: inside saw %q (rc=%d); host file ends %q; upper has hostnew=%v",
		probe, oneLine(out), rc, oneLine(string(hostTail[len(hostTail)-10:])), exists(o.Upper+"/hostnew.txt"))
	os.Remove(x.repo + "/hostnew.txt")
	os.WriteFile(x.repo+"/"+probe, orig, 0o644)
	RemoveAll(sent)
}

func (x *exp) concurrent(t *testing.T) {
	x.ensureRepo(t)
	x.logf("\n## two concurrent sessions, same lower, same Mount")
	probe := "src/d000/f013.txt"
	var wg sync.WaitGroup
	res := map[string]string{}
	var mu sync.Mutex
	ovs := map[string]Overlay{}
	for _, name := range []string{"A", "B"} {
		ovs[name] = x.overlay(t, "conc"+name, x.snap)
	}
	for name, o := range ovs {
		other := map[string]string{"A": "b", "B": "a"}[name]
		script := fmt.Sprintf(`printf %s > %s; touch only-%s; sleep 1; echo "content=$(cat %s)"; ls only-%s 2>&1 | head -1`,
			name, probe, strings.ToLower(name), probe, other)
		wg.Add(1)
		go func() {
			defer wg.Done()
			out, rc, took, err := runIn(o, nil, script)
			mu.Lock()
			res[name] = fmt.Sprintf("rc=%d %s err=%v (%s)", rc, oneLine(out), err, ms(took))
			mu.Unlock()
		}()
	}
	wg.Wait()
	for _, name := range []string{"A", "B"} {
		up, _ := os.ReadFile(ovs[name].Upper + "/" + probe)
		x.logf("- session %s: %s; upper %s=%q", name, res[name], probe, string(up))
	}
	host, _ := os.ReadFile(x.repo + "/" + probe)
	x.logf("- host checkout %s=%q", probe, oneLine(string(host)))
}

func (x *exp) nesting(t *testing.T) {
	x.ensureRepo(t)
	x.logf("\n## nested bwrap inside the overlay namespace")
	o := x.overlay(t, "nest", x.snap)
	script := `bwrap --ro-bind / / --bind "$PWD" "$PWD" --chdir "$PWD" -- sh -c 'echo nested > nested1.txt && echo "n1 uid=$(id -u)"'; echo "rc1=$?"
bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --bind "$PWD" "$PWD" --chdir "$PWD" --unshare-pid --unshare-net --die-with-parent --new-session -- sh -c 'echo nested > nested2.txt && echo n2'; echo "rc2=$?"
bwrap --ro-bind / / --bind "$PWD" "$PWD" -- sh -c 'echo x > /tmp/linuxfs-nested-probe' 2>&1 | tail -1; echo "rc3(write outside bind)=$?"
bwrap --dev-bind / / --overlay-src "$PWD" --tmp-overlay "$PWD" --chdir "$PWD" -- sh -c 'echo t > nested3.txt && echo n3'; echo "rc4(nested overlay)=$?"`
	for i, extra := range [][]string{nil, {"--unshare-pid", "--proc", "/proc"}} {
		if i > 0 {
			o = x.overlay(t, "nest-pid", x.snap)
		}
		out, rc, _, err := runIn(o, o.WrapWith(extra...), script)
		if err != nil {
			t.Fatal(err)
		}
		x.logf("- outer extra %v: rc=%d out: %s", extra, rc, oneLine(out))
		x.logf("  upper has nested1=%v nested2=%v nested3=%v; host checkout has nested1=%v",
			exists(o.Upper+"/nested1.txt"), exists(o.Upper+"/nested2.txt"), exists(o.Upper+"/nested3.txt"),
			exists(x.repo+"/nested1.txt"))
	}
}

func (x *exp) turns(t *testing.T) {
	lower := x.lower(t)
	x.logf("\n## per-turn change sets (one session, ChangesBetween of successive ReadUpper snapshots)")
	o := x.overlay(t, "turns", x.snap)
	turns := []string{
		"echo t1 >> src/d000/f020.txt && echo n > src/turn-new.txt && rm src/d000/f021.txt && rm -rf node_modules/pkg-2",
		"git checkout -- src/d000/f020.txt && rm src/turn-new.txt && rm -rf src/d005 && echo m > src/d006/f000.txt",
		"mkdir src/d005 && echo r > src/d005/r.txt && mv src/d007 src/d007b && chmod +x src/d000/f022.txt && touch src/d000/f023.txt",
	}
	prev, prevTree := map[string]UpperEntry{}, lower
	for i, script := range turns {
		out, rc, merged := sessionEnv(t, o, gitEnv, script)
		start := time.Now()
		cur, _, err := o.ReadUpper()
		if err != nil {
			t.Fatal(err)
		}
		read := time.Since(start)
		start = time.Now()
		got := ChangesBetween(prev, cur, lower)
		between := time.Since(start)
		truth := core.DiffTrees(prevTree, merged)
		verdict, _ := scoreLine(truth, got)
		cum, _, err := o.Changes(lower)
		if err != nil {
			t.Fatal(err)
		}
		cumVerdict, _ := scoreLine(core.DiffTrees(lower, merged), cum)
		x.logf("- turn %d (rc=%d %s): between=%s correct=%s [ReadUpper %s, ChangesBetween %s]; cumulative=%d paths correct=%s",
			i+1, rc, oneLine(out), csSummary(got), verdict, ms(read), ms(between), len(cum), cumVerdict)
		prev, prevTree = cur, merged
	}
}

func (x *exp) cost(t *testing.T) {
	lower := x.lower(t)
	x.logf("\n## cost: upper with 10k modified files")
	o := x.overlay(t, "cost", x.snap)
	script := `python3 -c 'import glob
for p in glob.glob("src/d0[0-9][0-9]/*.txt"):
    open(p, "a").write("c\n")'`
	_, rc, merged := sessionEnv(t, o, gitEnv, script)
	best := func(f func()) time.Duration {
		var b time.Duration
		for i := range 3 {
			s := time.Now()
			f()
			if d := time.Since(s); i == 0 || d < b {
				b = d
			}
		}
		return b
	}
	var upper map[string]UpperEntry
	var ust UpperStats
	tRead := best(func() {
		var err error
		if upper, ust, err = o.ReadUpper(); err != nil {
			t.Fatal(err)
		}
	})
	var cs core.ChangeSet
	tChanges := best(func() {
		var err error
		if cs, _, err = o.Changes(lower); err != nil {
			t.Fatal(err)
		}
	})
	tDiff := best(func() { diffUpper(lower, upper) })
	tBetween := best(func() { ChangesBetween(map[string]UpperEntry{}, upper, lower) })
	tEff := best(func() { o.Effective(lower, upper) })
	tScan := best(func() {
		if _, err := ScanTree(x.snap); err != nil {
			t.Fatal(err)
		}
	})
	verdict, _ := scoreLine(core.DiffTrees(lower, merged), cs)
	x.logf("- rc=%d upper: %d entries (%d files, %d dirs, %d bytes); changes=%d correct=%s", rc, ust.Entries, ust.Files,
		ust.Dirs, ust.Bytes, len(cs), verdict)
	x.logf("- best of 3: ReadUpper %s, Changes (ReadUpper+diff) %s, diff only %s, ChangesBetween %s, Effective %s, ScanTree(lower %d entries) %s",
		ms(tRead), ms(tChanges), ms(tDiff), ms(tBetween), ms(tEff), len(lower), ms(tScan))
}

func (x *exp) cleanup(t *testing.T) {
	if os.Getenv("LINUXFS_EXP_CLEAN") != "1" {
		t.Skip("set LINUXFS_EXP_CLEAN=1")
	}
	x.logf("\n## cleanup")
	ents, err := os.ReadDir(x.root)
	if err != nil {
		t.Fatal(err)
	}
	var parts []string
	for _, e := range ents {
		if e.Name() == "report.txt" {
			continue
		}
		p := filepath.Join(x.root, e.Name())
		parts = append(parts, fmt.Sprintf("%s %s", e.Name(), ms(x.drop(t, p))))
	}
	sort.Strings(parts)
	x.logf("- removed: %s", strings.Join(parts, ", "))
}
