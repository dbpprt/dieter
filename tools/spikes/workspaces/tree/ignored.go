//go:build darwin || linux

package tree

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"strings"

	"dieter.spike/workspaces/core"
)

// gitEnv is the environment for every git child: the parent's environment
// without DIETER_* (turn credentials) and GIT_* (a hook's GIT_DIR or
// GIT_INDEX_FILE would redirect git), with user and system config disabled.
func gitEnv(extra ...string) []string {
	var env []string
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "DIETER_") || strings.HasPrefix(kv, "GIT_") {
			continue
		}
		env = append(env, kv)
	}
	env = append(env, "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "GIT_TERMINAL_PROMPT=0")
	return append(env, extra...)
}

// Ignored classifies paths (relative to repoRoot) with git check-ignore.
// gitDir "" means git's own discovery from repoRoot; otherwise it is passed
// as --git-dir with --work-tree=repoRoot. A path is ignored when git ignores
// it or any of its parent directories; tracked paths are never ignored (git
// consults the index). Only the repository's own rules count: user and
// system config and the global excludes file are disabled so classification
// is reproducible. Keys are core.NormPath of the inputs; every input gets a
// key.
func Ignored(repoRoot string, gitDir string, paths []string) (map[string]bool, error) {
	out := make(map[string]bool, len(paths))
	seen := map[string]bool{}
	var queries []string
	add := func(q string) {
		if !seen[q] {
			seen[q] = true
			queries = append(queries, q)
		}
	}
	for _, p := range paths {
		np := core.NormPath(p)
		if np == "" {
			continue
		}
		out[np] = false
		add(np)
		// A trailing slash lets dir-only patterns ("build/") match parents
		// that no longer exist on disk.
		for d := path.Dir(np); d != "." && d != "/" && d != ""; d = path.Dir(d) {
			add(d + "/")
		}
	}
	// git dies on any pathspec at or below a symlinked directory ("beyond a
	// symbolic link"); such paths are classified by their real parents only.
	symDirs := map[string]bool{}
	for q := range seen {
		if d, ok := strings.CutSuffix(q, "/"); ok {
			if fi, err := os.Lstat(filepath.Join(repoRoot, filepath.FromSlash(d))); err == nil && fi.Mode()&os.ModeSymlink != 0 {
				symDirs[d] = true
			}
		}
	}
	if len(symDirs) > 0 {
		kept := queries[:0]
		for _, q := range queries {
			if !beyondSymlink(q, symDirs) {
				kept = append(kept, q)
			}
		}
		queries = kept
	}

	hit := map[string]bool{}
	// Backstop: drop a pathspec git refuses (for example one inside a
	// submodule) and retry, a bounded number of times.
	for attempt := 0; len(queries) > 0; attempt++ {
		lines, bad, err := checkIgnore(repoRoot, gitDir, queries)
		if err == nil {
			for _, q := range lines {
				hit[q] = true
			}
			break
		}
		if bad == "" || attempt >= 100 {
			return nil, err
		}
		kept := queries[:0]
		for _, q := range queries {
			if q != bad {
				kept = append(kept, q)
			}
		}
		if len(kept) == len(queries) {
			return nil, err
		}
		queries = kept
	}
	for np := range out {
		ig := hit[np]
		for d := path.Dir(np); !ig && d != "." && d != "/" && d != ""; d = path.Dir(d) {
			ig = hit[d+"/"]
		}
		out[np] = ig
	}
	return out, nil
}

// beyondSymlink reports a query naming a symlinked directory with a
// trailing slash, or any path below one.
func beyondSymlink(q string, symDirs map[string]bool) bool {
	if d, ok := strings.CutSuffix(q, "/"); ok && symDirs[d] {
		return true
	}
	for d := path.Dir(strings.TrimSuffix(q, "/")); d != "." && d != "/" && d != ""; d = path.Dir(d) {
		if symDirs[d] {
			return true
		}
	}
	return false
}

var badPathspec = regexp.MustCompile(`(?i)pathspec '(.*?)' (?:is|did) `)

// checkIgnore runs one git check-ignore over queries and returns the ignored
// ones. On failure it also returns the pathspec git complained about, if any.
func checkIgnore(repoRoot, gitDir string, queries []string) ([]string, string, error) {
	var args []string
	if gitDir != "" {
		args = append(args, "--git-dir="+gitDir, "--work-tree="+repoRoot)
	}
	args = append(args, "-c", "core.excludesFile=/dev/null", "check-ignore", "--stdin", "-z")
	cmd := exec.Command("git", args...)
	cmd.Dir = repoRoot
	cmd.Env = gitEnv()
	var in bytes.Buffer
	for _, q := range queries {
		in.WriteString(q)
		in.WriteByte(0)
	}
	cmd.Stdin = &in // exec feeds stdin from a goroutine, so large inputs cannot deadlock
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) || ee.ExitCode() != 1 { // 1: nothing ignored
			msg := strings.TrimSpace(stderr.String())
			bad := ""
			if m := badPathspec.FindStringSubmatch(msg); m != nil {
				bad = m[1]
			}
			return nil, bad, fmt.Errorf("git check-ignore in %s: %w: %s", repoRoot, err, msg)
		}
	}
	var out []string
	for _, q := range strings.Split(stdout.String(), "\x00") {
		if q != "" {
			out = append(out, q)
		}
	}
	return out, "", nil
}

// MarkIgnored sets Ignored on every change whose path is marked ignored.
func MarkIgnored(cs core.ChangeSet, ignored map[string]bool) {
	for p, c := range cs {
		if ignored[p] {
			c.Ignored = true
			cs[p] = c
		}
	}
}
