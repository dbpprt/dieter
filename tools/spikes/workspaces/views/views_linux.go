//go:build linux

package views

import (
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"dieter.spike/workspaces/core"
	"dieter.spike/workspaces/linuxfs"
)

// prepareBase makes a read-only btrfs snapshot of the source when the source
// is a subvolume, otherwise a reflink copy.
func prepareBase(env Env) (time.Duration, error) {
	if _, err := os.Stat(env.Base); err == nil {
		return 0, nil
	}
	if err := os.MkdirAll(filepath.Dir(env.Base), 0o755); err != nil {
		return 0, err
	}
	if linuxfs.IsSubvolume(env.Source) {
		return linuxfs.Snapshot(env.Source, env.Base, true)
	}
	d, _, err := linuxfs.ReflinkTree(env.Source, env.Base)
	return d, err
}

func hydrateReflink(src, dst string) error {
	fi, err := os.Lstat(src)
	if err != nil {
		return err
	}
	if !fi.IsDir() {
		// ReflinkTree walks directories; copy single files with cp --reflink.
		return exec.Command("cp", "-a", "--reflink=auto", src, dst).Run()
	}
	_, _, err = linuxfs.ReflinkTree(src, dst)
	return err
}

// overlay: kernel overlayfs in a user+mount+pid namespace, mounted at the
// source's own path over the frozen base.
type overlay struct{}

func (overlay) Name() string                               { return "overlay" }
func (overlay) PrepareBase(env Env) (time.Duration, error) { return prepareBase(env) }

// Overlay returns the overlay description of a view.
func Overlay(env Env, v *View) linuxfs.Overlay {
	return linuxfs.Overlay{Lower: env.Base, Upper: filepath.Join(v.State, "upper"),
		Work: filepath.Join(v.State, "work"), Mount: env.Source}
}

func (overlay) Create(env Env, id string) (*View, Timing, error) {
	start := time.Now()
	v := &View{ID: id, Provider: "overlay", Dir: env.Source, State: filepath.Join(env.Root, "sessions", id)}
	o := Overlay(env, v)
	if err := o.Prepare(); err != nil {
		return nil, Timing{}, err
	}
	v.Launcher = core.Launcher{Dir: env.Source, Wrap: RetryWrap(o.WrapWith("--unshare-pid", "--proc", "/proc"))}
	v.Index = filepath.Join(env.Base, ".git", "index")
	return v, Timing{Create: time.Since(start)}, nil
}

func (overlay) Discard(env Env, v *View) (time.Duration, error) {
	start := time.Now()
	err := linuxfs.RemoveAll(v.State)
	return time.Since(start), err
}

// btrfsView: a writable btrfs snapshot of the base per view.
type btrfsView struct{}

func (btrfsView) Name() string                               { return "btrfs" }
func (btrfsView) PrepareBase(env Env) (time.Duration, error) { return prepareBase(env) }

func (btrfsView) Create(env Env, id string) (*View, Timing, error) {
	dir := filepath.Join(env.Root, "views", id)
	if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
		return nil, Timing{}, err
	}
	d, err := linuxfs.Snapshot(env.Base, dir, false)
	if err != nil {
		return nil, Timing{}, err
	}
	return &View{ID: id, Provider: "btrfs", Dir: dir, HostDir: dir, GitDir: filepath.Join(dir, ".git"),
		Index: filepath.Join(dir, ".git", "index"), Launcher: core.Launcher{Dir: dir}}, Timing{Create: d}, nil
}

func (btrfsView) Discard(env Env, v *View) (time.Duration, error) {
	start := time.Now()
	err := linuxfs.DeleteSubvolume(v.Dir)
	return time.Since(start), err
}

// reflinkView: a reflink copy of the base per view.
type reflinkView struct{}

func (reflinkView) Name() string                               { return "reflink" }
func (reflinkView) PrepareBase(env Env) (time.Duration, error) { return prepareBase(env) }

func (reflinkView) Create(env Env, id string) (*View, Timing, error) {
	dir := filepath.Join(env.Root, "views", id)
	if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
		return nil, Timing{}, err
	}
	d, _, err := linuxfs.ReflinkTree(env.Base, dir)
	if err != nil {
		return nil, Timing{}, err
	}
	return &View{ID: id, Provider: "reflink", Dir: dir, HostDir: dir, GitDir: filepath.Join(dir, ".git"),
		Index: filepath.Join(dir, ".git", "index"), Launcher: core.Launcher{Dir: dir}}, Timing{Create: d}, nil
}

func (reflinkView) Discard(env Env, v *View) (time.Duration, error) {
	start := time.Now()
	err := linuxfs.RemoveAll(v.Dir)
	return time.Since(start), err
}

// RetryWrap prefixes a bwrap argv with `spike bwrap-retry` (see cmd/spike).
func RetryWrap(wrap []string) []string {
	self, err := os.Executable()
	if err != nil {
		return wrap
	}
	return append([]string{self, "bwrap-retry"}, wrap...)
}

func init() {
	register(overlay{})
	register(btrfsView{})
	register(reflinkView{})
	register(worktree{name: "worktree-hydrate", hydrate: hydrateReflink})
}
