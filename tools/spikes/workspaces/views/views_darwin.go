//go:build darwin

package views

import (
	"fmt"
	"os"
	"path/filepath"
	"time"

	"dieter.spike/workspaces/core"
	"dieter.spike/workspaces/darwinfs"
)

func prepareBase(env Env) (time.Duration, error) {
	if _, err := os.Stat(env.Base); err == nil {
		return 0, nil
	}
	if err := os.MkdirAll(filepath.Dir(env.Base), 0o755); err != nil {
		return 0, err
	}
	return darwinfs.CloneTree(env.Source, env.Base)
}

func hydrateClone(src, dst string) error {
	fi, err := os.Lstat(src)
	if err != nil {
		return err
	}
	if fi.IsDir() {
		_, err = darwinfs.CloneTree(src, dst)
		return err
	}
	return darwinfs.CloneFile(src, dst)
}

// clone: one clonefile(2) of the whole base, .git included. viewConfig sets
// core.checkStat=minimal and core.trustCtime=false in the clone so git does
// not rehash files whose inode and ctime changed with the clone.
type clone struct {
	name       string
	viewConfig bool
	perFile    bool
}

func (c clone) Name() string                               { return c.name }
func (c clone) PrepareBase(env Env) (time.Duration, error) { return prepareBase(env) }

func (c clone) Create(env Env, id string) (*View, Timing, error) {
	t := Timing{Steps: map[string]time.Duration{}}
	dir := filepath.Join(env.Root, "views", id)
	if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
		return nil, t, err
	}
	start := time.Now()
	var err error
	if c.perFile {
		t.Steps["clone"], err = darwinfs.ClonePerFile(env.Base, dir)
	} else {
		t.Steps["clone"], err = darwinfs.CloneTree(env.Base, dir)
	}
	if err != nil {
		return nil, t, err
	}
	if c.viewConfig {
		s := time.Now()
		for _, kv := range [][2]string{{"core.checkStat", "minimal"}, {"core.trustCtime", "false"}} {
			if _, err := Git(dir, "config", kv[0], kv[1]); err != nil {
				return nil, t, err
			}
		}
		t.Steps["config"] = time.Since(s)
	}
	t.Create = time.Since(start)
	return &View{ID: id, Provider: c.name, Dir: dir, HostDir: dir, GitDir: filepath.Join(dir, ".git"),
		Index: filepath.Join(dir, ".git", "index"), Launcher: core.Launcher{Dir: dir}}, t, nil
}

func (c clone) Discard(env Env, v *View) (time.Duration, error) {
	start := time.Now()
	err := os.RemoveAll(v.Dir)
	return time.Since(start), err
}

// cloneWorktree: a linked worktree registered in the source repository whose
// files come from clones of the base instead of a checkout, with the base
// index copied in. Existing worktree-based git operations keep working.
type cloneWorktree struct{}

func (cloneWorktree) Name() string                               { return "clone-worktree" }
func (cloneWorktree) PrepareBase(env Env) (time.Duration, error) { return prepareBase(env) }

func (cloneWorktree) Create(env Env, id string) (*View, Timing, error) {
	t := Timing{Steps: map[string]time.Duration{}}
	dir := filepath.Join(env.Root, "views", id)
	start := time.Now()
	if _, err := Git(env.Source, "worktree", "add", "-q", "--no-checkout", "--detach", dir, "HEAD"); err != nil {
		return nil, t, err
	}
	t.Steps["worktree_add"] = time.Since(start)
	s := time.Now()
	entries, err := os.ReadDir(env.Base)
	if err != nil {
		return nil, t, err
	}
	for _, e := range entries {
		if e.Name() == ".git" {
			continue
		}
		if err := hydrateClone(filepath.Join(env.Base, e.Name()), filepath.Join(dir, e.Name())); err != nil {
			return nil, t, fmt.Errorf("clone %s: %w", e.Name(), err)
		}
	}
	t.Steps["clone_entries"] = time.Since(s)
	gitDir, err := Git(dir, "rev-parse", "--absolute-git-dir")
	if err != nil {
		return nil, t, err
	}
	s = time.Now()
	if err := darwinfs.CloneFile(filepath.Join(env.Base, ".git", "index"), filepath.Join(gitDir, "index")); err != nil {
		return nil, t, err
	}
	t.Steps["seed_index"] = time.Since(s)
	t.Create = time.Since(start)
	return &View{ID: id, Provider: "clone-worktree", Dir: dir, HostDir: dir, GitDir: gitDir,
		Index: filepath.Join(gitDir, "index"), Launcher: core.Launcher{Dir: dir}}, t, nil
}

func (cloneWorktree) Discard(env Env, v *View) (time.Duration, error) {
	start := time.Now()
	_, err := Git(env.Source, "worktree", "remove", "--force", v.Dir)
	return time.Since(start), err
}

func init() {
	register(clone{name: "clone", viewConfig: true})
	register(clone{name: "clone-raw"})
	register(clone{name: "clone-cp", perFile: true, viewConfig: true})
	register(cloneWorktree{})
	register(worktree{name: "worktree-hydrate", hydrate: hydrateClone})
}
