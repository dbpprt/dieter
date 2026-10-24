// Package views creates per-session working copies ("views") of a source
// checkout through different mechanisms, so the spike can compare them.
package views

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"dieter.spike/workspaces/core"
)

// Env holds the directories every provider works with.
type Env struct {
	Source string // the operator checkout (a git repository)
	Base   string // a quiescent copy of Source owned by the spike
	Root   string // where views and session state are created
}

// View is one session's working copy.
type View struct {
	ID       string
	Provider string
	Dir      string // path the agent works in
	HostDir  string // host-readable path of the same files ("" when only visible in a namespace)
	GitDir   string // host path of the view's git dir
	Index    string // host path of the view's own index (seed for the shadow index)
	Launcher core.Launcher
	State    string            // provider-private directory (overlay upper/work)
	Extra    map[string]string // provider details for reports
}

// Timing breaks down view creation.
type Timing struct {
	Create time.Duration            `json:"create"`
	Steps  map[string]time.Duration `json:"steps,omitempty"`
}

// Provider creates and discards views.
type Provider interface {
	Name() string
	// PrepareBase makes Env.Base from Env.Source (once per run).
	PrepareBase(env Env) (time.Duration, error)
	Create(env Env, id string) (*View, Timing, error)
	Discard(env Env, v *View) (time.Duration, error)
}

var registry = map[string]Provider{}

func register(p Provider) { registry[p.Name()] = p }

// Get returns a provider by name.
func Get(name string) (Provider, error) {
	p, ok := registry[name]
	if !ok {
		return nil, fmt.Errorf("unknown provider %q (have %s)", name, strings.Join(Names(), ", "))
	}
	return p, nil
}

// Names lists the providers available on this platform.
func Names() []string {
	var out []string
	for n := range registry {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

func gitEnv() []string {
	var env []string
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(k, "GIT_") || strings.HasPrefix(k, "DIETER_") {
			continue
		}
		env = append(env, kv)
	}
	return append(env, "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
}

// Git runs git in dir with the operator's global config disabled.
func Git(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = gitEnv()
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return out.String(), fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(errb.String()))
	}
	return strings.TrimSpace(out.String()), nil
}

// FirstStatus times the first `git status` in a host-visible view.
func FirstStatus(v *View) (time.Duration, int, error) {
	if v.HostDir == "" {
		return 0, 0, fmt.Errorf("view %s is not host visible", v.ID)
	}
	start := time.Now()
	out, err := Git(v.HostDir, "status", "--porcelain")
	n := 0
	if strings.TrimSpace(out) != "" {
		n = len(strings.Split(strings.TrimSpace(out), "\n"))
	}
	return time.Since(start), n, err
}

// worktree provider (both platforms): a linked git worktree, as Dieter does
// today, optionally hydrated with the base's ignored top-level entries.
type worktree struct {
	name    string
	hydrate func(src, dst string) error
}

func (w worktree) Name() string { return w.name }

func (w worktree) PrepareBase(env Env) (time.Duration, error) { return prepareBase(env) }

func (w worktree) Create(env Env, id string) (*View, Timing, error) {
	start := time.Now()
	dir := filepath.Join(env.Root, "views", id)
	t := Timing{Steps: map[string]time.Duration{}}
	if _, err := Git(env.Source, "worktree", "add", "-q", "--detach", dir, "HEAD"); err != nil {
		return nil, t, err
	}
	t.Steps["worktree_add"] = time.Since(start)
	if w.hydrate != nil {
		h := time.Now()
		ignored, err := ignoredTopLevel(env.Base)
		if err != nil {
			return nil, t, err
		}
		for _, name := range ignored {
			if err := w.hydrate(filepath.Join(env.Base, name), filepath.Join(dir, name)); err != nil {
				return nil, t, fmt.Errorf("hydrate %s: %w", name, err)
			}
		}
		t.Steps["hydrate"] = time.Since(h)
	}
	gitDir, err := Git(dir, "rev-parse", "--absolute-git-dir")
	if err != nil {
		return nil, t, err
	}
	t.Create = time.Since(start)
	return &View{ID: id, Provider: w.name, Dir: dir, HostDir: dir, GitDir: gitDir,
		Index: filepath.Join(gitDir, "index"), Launcher: core.Launcher{Dir: dir}}, t, nil
}

func (w worktree) Discard(env Env, v *View) (time.Duration, error) {
	start := time.Now()
	_, err := Git(env.Source, "worktree", "remove", "--force", v.Dir)
	return time.Since(start), err
}

// ignoredTopLevel lists top-level entries of dir that git ignores.
func ignoredTopLevel(dir string) ([]string, error) {
	out, err := Git(dir, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z")
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var names []string
	for _, p := range strings.Split(out, "\x00") {
		p = strings.TrimSuffix(p, "/")
		if p == "" {
			continue
		}
		// Only hydrate entries that are ignored as a whole; nested ignored
		// paths live inside tracked directories the worktree already has.
		if strings.Contains(p, "/") || seen[p] {
			continue
		}
		seen[p] = true
		names = append(names, p)
	}
	sort.Strings(names)
	return names, nil
}

func init() {
	register(worktree{name: "worktree"})
}
