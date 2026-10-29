//go:build darwin

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"dieter.spike/workspaces/core"
	"dieter.spike/workspaces/darwinfs"
	"dieter.spike/workspaces/tree"
	"dieter.spike/workspaces/views"
	"golang.org/x/sys/unix"
)

type platformState struct{ re *runEnv }

func newPlatformState(re *runEnv) (*platformState, error) { return &platformState{re: re}, nil }

func (p *platformState) baseManifest() (*tree.Manifest, bool) {
	m, _, err := tree.BuildManifest(p.re.env.Base, nil)
	return m, err == nil
}

func (p *platformState) oracle(v *views.View, driver string) (recorder, string) {
	return &hostOracle{dir: v.HostDir}, "host-scan"
}

func (p *platformState) recorders(v *views.View, id string) []recorder {
	return []recorder{
		&shadowRec{re: p.re, v: v, session: id},
		&manifestRec{re: p.re, dir: v.HostDir},
		&cloneScanRec{dir: v.HostDir},
		&fseventsRec{label: "fsevents", dirs: []string{v.HostDir}},
	}
}

func (p *platformState) escapeRecorders() []recorder {
	return []recorder{&fseventsRec{label: "fsevents-escape", dirs: []string{p.re.o.source, p.re.o.sentinel}}}
}

func (p *platformState) cleanupSentinel(o *runOpts) {
	os.Remove(filepath.Join(o.sentinel, "escape.txt"))
	os.Remove(filepath.Join(o.source, "escape-into-source.txt"))
}

// cloneScanRec is a stat-only getattrlistbulk walk (clone id, size, times).
type cloneScanRec struct {
	dir  string
	prev map[string]darwinfs.CEntry
}

func (c *cloneScanRec) name() string { return "clonescan" }
func (c *cloneScanRec) mark() (core.ChangeSet, time.Duration, error) {
	cur, st, err := darwinfs.ScanClone(c.dir, darwinfs.ScanOptions{Workers: 8, SkipGit: true, SkipBlockStats: true})
	if err != nil {
		return nil, 0, err
	}
	var cs core.ChangeSet
	if c.prev != nil {
		cs = core.ChangeSet{}
		for p, a := range cur {
			if a.Type == core.Dir {
				continue
			}
			b, ok := c.prev[p]
			switch {
			case !ok:
				cs.Add(p, core.Added, false)
			case b.Type != a.Type:
				cs.Add(p, core.TypeChanged, false)
			case b.Size != a.Size || b.MtimeNs != a.MtimeNs || b.CloneID != a.CloneID || b.Ino != a.Ino:
				cs.Add(p, core.Modified, false)
			case b.Mode != a.Mode:
				cs.Add(p, core.ModeChanged, false)
			case b.CtimeNs != a.CtimeNs:
				cs.Add(p, core.Changed, false)
			}
		}
		for p, b := range c.prev {
			if _, ok := cur[p]; !ok && b.Type != core.Dir {
				cs.Add(p, core.Deleted, false)
			}
		}
	}
	c.prev = cur
	return cs, st.Duration, nil
}

// fseventsRec replays FSEvents history since the previous mark.
type fseventsRec struct {
	label string
	dirs  []string
	since uint64
}

func (f *fseventsRec) name() string { return f.label }
func (f *fseventsRec) mark() (core.ChangeSet, time.Duration, error) {
	if f.since == 0 {
		f.since = darwinfs.CurrentEventID()
		return nil, 0, nil
	}
	start := time.Now()
	next := darwinfs.CurrentEventID()
	evs, err := darwinfs.EventsSince(f.dirs, f.since, 15*time.Second)
	if err != nil {
		return nil, 0, err
	}
	f.since = next
	roots := make([]string, len(f.dirs))
	for i, d := range f.dirs {
		r, err := filepath.EvalSymlinks(d)
		if err != nil {
			r = d
		}
		roots[i] = r
	}
	cs := core.ChangeSet{}
	for _, e := range evs {
		if e.ItemIsDir() || e.HistoryDone() {
			continue
		}
		for i, r := range roots {
			rel, err := filepath.Rel(r, e.Path)
			if err != nil || strings.HasPrefix(rel, "..") || rel == "." {
				continue
			}
			if rel == ".git" || strings.HasPrefix(rel, ".git/") {
				break
			}
			if len(roots) > 1 {
				rel = filepath.Base(f.dirs[i]) + ":" + rel
			}
			cs.Add(rel, core.Changed, false)
			break
		}
	}
	return cs, time.Since(start), nil
}

func freeBytes(path string) int64 {
	var st unix.Statfs_t
	if err := unix.Statfs(path, &st); err != nil {
		return 0
	}
	return int64(st.Bavail) * int64(st.Bsize)
}

// forkView clones a view (between turns) into a new clone view.
func forkView(re *runEnv, v *views.View) (*views.View, time.Duration, error) {
	id := v.ID + "-fork"
	dir := filepath.Join(re.env.Root, "views", id)
	d, err := darwinfs.CloneTree(v.HostDir, dir)
	if err != nil {
		return nil, 0, err
	}
	return &views.View{ID: id, Provider: v.Provider, Dir: dir, HostDir: dir, GitDir: filepath.Join(dir, ".git"),
		Index: filepath.Join(dir, ".git", "index"), Launcher: core.Launcher{Dir: dir}}, d, nil
}

func cmdClone(args []string) error {
	if len(args) != 2 {
		return fmt.Errorf("usage: spike clone SRC DST")
	}
	d, err := darwinfs.CloneTree(args[0], args[1])
	fmt.Printf("cloned in %s\n", d)
	return err
}

func cmdBwrapRetry(args []string) error { return fmt.Errorf("bwrap-retry is linux-only") }
