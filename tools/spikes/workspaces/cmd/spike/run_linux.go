//go:build linux

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"dieter.spike/workspaces/core"
	"dieter.spike/workspaces/linuxfs"
	"dieter.spike/workspaces/shadow"
	"dieter.spike/workspaces/tree"
	"dieter.spike/workspaces/views"
	"golang.org/x/sys/unix"
	"golang.org/x/text/unicode/norm"
)

type platformState struct {
	re    *runEnv
	lower core.Tree
}

func newPlatformState(re *runEnv) (*platformState, error) {
	p := &platformState{re: re}
	if re.o.provider == "overlay" {
		t, err := linuxfs.ScanTree(re.env.Base)
		if err != nil {
			return nil, err
		}
		p.lower = t
	}
	return p, nil
}

func (p *platformState) baseManifest() (*tree.Manifest, bool) {
	if p.re.o.provider == "overlay" {
		return nil, false
	}
	m, _, err := tree.BuildManifest(p.re.env.Base, nil)
	return m, err == nil
}

func (p *platformState) oracle(v *views.View, driver string) (recorder, string) {
	if v.HostDir != "" {
		return &hostOracle{dir: v.HostDir}, "host-scan"
	}
	o := views.Overlay(p.re.env, v)
	if driver == "codex" {
		// The app-server keeps the overlay mounted between turns; a second
		// mount of the same upper is undefined, so derive the merged view.
		return &effectiveOracle{o: o, lower: p.lower}, "effective(lower+upper)"
	}
	return &nsOracle{self: p.re.self, launcher: v.Launcher, tmp: filepath.Join(p.re.o.root, "tmp")}, "namespace-scan"
}

func (p *platformState) recorders(v *views.View, id string) []recorder {
	if v.HostDir != "" {
		return []recorder{&shadowRec{re: p.re, v: v, session: id}, &manifestRec{re: p.re, dir: v.HostDir}}
	}
	o := views.Overlay(p.re.env, v)
	return []recorder{
		&upperRec{o: o, lower: p.lower},
		&shadowUpperRec{re: p.re, o: o, lower: p.lower, session: id},
	}
}

func (p *platformState) escapeRecorders() []recorder { return nil }

func (p *platformState) cleanupSentinel(o *runOpts) {
	os.Remove(filepath.Join(o.sentinel, "escape.txt"))
	os.Remove(filepath.Join(o.source, "escape-into-source.txt"))
}

// nsOracle scans the view from inside its namespace.
type nsOracle struct {
	self     string
	launcher core.Launcher
	tmp      string
	prev     core.Tree
}

func (n *nsOracle) name() string { return "oracle" }
func (n *nsOracle) mark() (core.ChangeSet, time.Duration, error) {
	start := time.Now()
	out := filepath.Join(n.tmp, fmt.Sprintf("scan-%d.json", time.Now().UnixNano()))
	defer os.Remove(out)
	argv := append(append([]string{}, n.launcher.Wrap...), n.self, "scan", "-root", n.launcher.Dir, "-out", out)
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = n.launcher.Dir
	if b, err := cmd.CombinedOutput(); err != nil {
		return nil, 0, fmt.Errorf("namespace scan: %v: %s", err, b)
	}
	b, err := os.ReadFile(out)
	if err != nil {
		return nil, 0, err
	}
	var t core.Tree
	if err := json.Unmarshal(b, &t); err != nil {
		return nil, 0, err
	}
	var cs core.ChangeSet
	if n.prev != nil {
		cs = core.DiffTrees(n.prev, t)
	}
	n.prev = t
	return cs, time.Since(start), nil
}

type effectiveOracle struct {
	o     linuxfs.Overlay
	lower core.Tree
	prev  core.Tree
}

func (e *effectiveOracle) name() string { return "oracle" }
func (e *effectiveOracle) mark() (core.ChangeSet, time.Duration, error) {
	start := time.Now()
	up, _, err := e.o.ReadUpper()
	if err != nil {
		return nil, 0, err
	}
	t := e.o.Effective(e.lower, up)
	var cs core.ChangeSet
	if e.prev != nil {
		cs = core.DiffTrees(e.prev, t)
	}
	e.prev = t
	return cs, time.Since(start), nil
}

// upperRec reads the overlay upper directory.
type upperRec struct {
	o     linuxfs.Overlay
	lower core.Tree
	prev  map[string]linuxfs.UpperEntry
	init  bool
}

func (u *upperRec) name() string { return "upper" }
func (u *upperRec) mark() (core.ChangeSet, time.Duration, error) {
	start := time.Now()
	cur, _, err := u.o.ReadUpper()
	if err != nil {
		return nil, 0, err
	}
	var cs core.ChangeSet
	if u.init {
		cs = linuxfs.ChangesBetween(u.prev, cur, u.lower)
	}
	u.prev, u.init = cur, true
	return cs, time.Since(start), nil
}

// shadowUpperRec turns per-turn upper changes into shadow commits without
// mounting the overlay.
type shadowUpperRec struct {
	re      *runEnv
	o       linuxfs.Overlay
	lower   core.Tree
	session string
	prevUp  map[string]linuxfs.UpperEntry
	prev    string
	n       int
}

func (s *shadowUpperRec) name() string { return "shadow" }
func (s *shadowUpperRec) mark() (core.ChangeSet, time.Duration, error) {
	start := time.Now()
	cur, _, err := s.o.ReadUpper()
	if err != nil {
		return nil, 0, err
	}
	changes := core.ChangeSet{}
	if s.prev != "" {
		changes = linuxfs.ChangesBetween(s.prevUp, cur, s.lower)
		markIgnored(s.re.env.Base, changes)
	}
	parent := s.prev
	if parent == "" {
		parent = s.re.baseHead
	}
	idx := filepath.Join(s.re.o.root, "idx", s.session+".index")
	os.MkdirAll(filepath.Dir(idx), 0o755)
	snap, err := s.re.shadow.SnapshotFromChanges(parent, changes, func(p string) string { return resolveRaw(s.o.Upper, p) },
		idx, fmt.Sprintf("refs/sessions/%s/%d", s.session, s.n), fmt.Sprintf("%s turn %d", s.session, s.n))
	if err != nil {
		return nil, 0, err
	}
	s.n++
	var cs core.ChangeSet
	if s.prev != "" {
		cs, err = s.re.shadow.Diff(s.prev, snap.Commit)
	}
	s.prev, s.prevUp = snap.Commit, cur
	return cs, time.Since(start), err
}

var _ = shadow.Rev

func (s *shadowUpperRec) last() string { return s.prev }

// resolveRaw maps an NFC-normalized relative path back to the on-disk name
// (Linux keeps NFD names as distinct bytes).
func resolveRaw(root, rel string) string {
	cur := root
	for _, part := range strings.Split(rel, "/") {
		next := filepath.Join(cur, part)
		if _, err := os.Lstat(next); err != nil {
			if ents, err := os.ReadDir(cur); err == nil {
				for _, e := range ents {
					if norm.NFC.String(e.Name()) == part {
						next = filepath.Join(cur, e.Name())
						break
					}
				}
			}
		}
		cur = next
	}
	return cur
}

func freeBytes(path string) int64 {
	var st unix.Statfs_t
	if err := unix.Statfs(path, &st); err != nil {
		return 0
	}
	return int64(st.Bavail) * int64(st.Bsize)
}

// forkView copies a view between turns: overlay views get a reflink copy of
// the upper over the same lower; btrfs views a snapshot; others a reflink copy.
func forkView(re *runEnv, v *views.View) (*views.View, time.Duration, error) {
	id := v.ID + "-fork"
	start := time.Now()
	switch v.Provider {
	case "overlay":
		nv := &views.View{ID: id, Provider: "overlay", Dir: v.Dir, State: filepath.Join(re.env.Root, "sessions", id)}
		o := views.Overlay(re.env, nv)
		if _, _, err := linuxfs.ReflinkTree(filepath.Join(v.State, "upper"), o.Upper); err != nil {
			return nil, 0, err
		}
		if err := o.Prepare(); err != nil {
			return nil, 0, err
		}
		nv.Launcher = core.Launcher{Dir: v.Dir, Wrap: views.RetryWrap(o.WrapWith("--unshare-pid", "--proc", "/proc"))}
		nv.Index = v.Index
		return nv, time.Since(start), nil
	case "btrfs":
		dir := filepath.Join(re.env.Root, "views", id)
		d, err := linuxfs.Snapshot(v.HostDir, dir, false)
		if err != nil {
			return nil, 0, err
		}
		return &views.View{ID: id, Provider: v.Provider, Dir: dir, HostDir: dir, GitDir: filepath.Join(dir, ".git"),
			Index: filepath.Join(dir, ".git", "index"), Launcher: core.Launcher{Dir: dir}}, d, nil
	default:
		dir := filepath.Join(re.env.Root, "views", id)
		d, _, err := linuxfs.ReflinkTree(v.HostDir, dir)
		if err != nil {
			return nil, 0, err
		}
		return &views.View{ID: id, Provider: v.Provider, Dir: dir, HostDir: dir, GitDir: filepath.Join(dir, ".git"),
			Index: filepath.Join(dir, ".git", "index"), Launcher: core.Launcher{Dir: dir}}, d, nil
	}
}

func cmdClone(args []string) error {
	if len(args) != 2 {
		return fmt.Errorf("usage: spike clone SRC DST")
	}
	var d time.Duration
	var err error
	if linuxfs.IsSubvolume(args[0]) {
		d, err = linuxfs.Snapshot(args[0], args[1], false)
	} else {
		d, _, err = linuxfs.ReflinkTree(args[0], args[1])
	}
	fmt.Printf("cloned in %s\n", d)
	return err
}

// cmdBwrapRetry runs bwrap and retries while the overlay mount fails with
// EBUSY: overlayfs releases its upper/work "in use" lock asynchronously after
// the previous namespace exits, so an immediate remount can fail. The inner
// command has not started when the mount fails, so a retry is safe.
func cmdBwrapRetry(args []string) error {
	delay := 50 * time.Millisecond
	for attempt := 1; ; attempt++ {
		var errb strings.Builder
		cmd := exec.Command(args[0], args[1:]...)
		cmd.Stdin, cmd.Stdout = os.Stdin, os.Stdout
		cmd.Stderr = &teeWriter{w: os.Stderr, buf: &errb}
		err := cmd.Run()
		if err == nil {
			return nil
		}
		busy := strings.Contains(errb.String(), "Can't make overlay mount") && strings.Contains(errb.String(), "busy")
		if !busy || attempt >= 40 {
			if exit, ok := err.(*exec.ExitError); ok {
				os.Exit(exit.ExitCode())
			}
			return err
		}
		fmt.Fprintf(os.Stderr, "spike: overlay busy, retry %d after %s\n", attempt, delay)
		time.Sleep(delay)
		if delay < time.Second {
			delay *= 2
		}
	}
}

type teeWriter struct {
	w   *os.File
	buf *strings.Builder
}

func (t *teeWriter) Write(p []byte) (int, error) {
	if t.buf.Len() < 4096 {
		t.buf.Write(p)
	}
	return t.w.Write(p)
}
