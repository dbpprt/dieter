// Package shadow records working-tree snapshots as git trees in a bare
// "shadow" repository that lives outside the project. Its object store
// borrows the project's objects through alternates, so snapshots only add
// what is new, and nothing is ever written into the project repository until
// a publish.
package shadow

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"dieter.spike/workspaces/core"
)

// Repo is a shadow repository for one project.
type Repo struct {
	Dir           string // bare repository
	SourceObjects string // the project's objects directory (alternate)
}

// Snapshot is one recorded tree.
type Snapshot struct {
	Commit   string        `json:"commit"`
	Tree     string        `json:"tree"`
	Ref      string        `json:"ref"`
	Duration time.Duration `json:"duration"`
}

var baseEnv = func() []string {
	var env []string
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(k, "GIT_") || strings.HasPrefix(k, "DIETER_") {
			continue
		}
		env = append(env, kv)
	}
	return append(env,
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1",
		"GIT_AUTHOR_NAME=Dieter Snapshot", "GIT_AUTHOR_EMAIL=snapshot@dieter.invalid",
		"GIT_COMMITTER_NAME=Dieter Snapshot", "GIT_COMMITTER_EMAIL=snapshot@dieter.invalid",
		"GIT_AUTHOR_DATE=2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE=2026-01-01T00:00:00Z")
}()

func git(dir string, env []string, stdin []byte, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(append([]string{}, baseEnv...), env...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return out.String(), fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(errb.String()))
	}
	return strings.TrimSpace(out.String()), nil
}

// Open creates (or opens) the shadow repository at dir, borrowing objects
// from sourceGitDir.
func Open(dir, sourceGitDir string) (*Repo, error) {
	objs, err := filepath.Abs(filepath.Join(sourceGitDir, "objects"))
	if err != nil {
		return nil, err
	}
	if _, err := os.Stat(filepath.Join(dir, "HEAD")); err != nil {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
		if _, err := git(dir, nil, nil, "init", "-q", "--bare", "."); err != nil {
			return nil, err
		}
		if _, err := git(dir, nil, nil, "config", "gc.auto", "0"); err != nil {
			return nil, err
		}
	}
	alt := filepath.Join(dir, "objects", "info", "alternates")
	if err := os.WriteFile(alt, []byte(objs+"\n"), 0o644); err != nil {
		return nil, err
	}
	return &Repo{Dir: dir, SourceObjects: objs}, nil
}

func (r *Repo) objectEnv(index string) []string {
	return []string{
		"GIT_INDEX_FILE=" + index,
		"GIT_OBJECT_DIRECTORY=" + filepath.Join(r.Dir, "objects"),
		"GIT_ALTERNATE_OBJECT_DIRECTORIES=" + r.SourceObjects,
	}
}

// SnapshotWorkTree records workTree with a private index. gitDir supplies the
// ignore rules (info/exclude); index is the session's private index, seeded
// from seed on first use so unchanged files are not rehashed. parent is the
// previous snapshot (or the base commit).
func (r *Repo) SnapshotWorkTree(workTree, gitDir, index, seed, parent, ref, msg string) (Snapshot, error) {
	start := time.Now()
	if _, err := os.Stat(index); errors.Is(err, os.ErrNotExist) && seed != "" {
		b, err := os.ReadFile(seed)
		if err != nil {
			return Snapshot{}, err
		}
		if err := os.MkdirAll(filepath.Dir(index), 0o755); err != nil {
			return Snapshot{}, err
		}
		if err := os.WriteFile(index, b, 0o644); err != nil {
			return Snapshot{}, err
		}
	}
	env := r.objectEnv(index)
	common := []string{"--git-dir=" + gitDir, "--work-tree=" + workTree,
		"-c", "core.checkStat=minimal", "-c", "core.trustCtime=false", "-c", "gc.auto=0",
		"-c", "core.fsmonitor=false", "-c", "core.untrackedCache=true"}
	if _, err := git(workTree, env, nil, append(common, "add", "-A", "--", ".")...); err != nil {
		return Snapshot{}, err
	}
	tree, err := git(workTree, env, nil, append(common, "write-tree")...)
	if err != nil {
		return Snapshot{}, err
	}
	return r.commit(tree, parent, ref, msg, start)
}

// SnapshotFromChanges records parent's tree plus changes, reading new
// content through content(path) (a host path to the file or symlink). Paths
// marked ignored are skipped. This is how an overlay upper becomes a commit
// without mounting it.
func (r *Repo) SnapshotFromChanges(parent string, changes core.ChangeSet, content func(string) string, index, ref, msg string) (Snapshot, error) {
	start := time.Now()
	_ = os.Remove(index)
	env := r.objectEnv(index)
	if _, err := git(r.Dir, env, nil, "read-tree", parent+"^{tree}"); err != nil {
		return Snapshot{}, err
	}
	var info bytes.Buffer
	var files []string
	var filePaths []string
	for _, p := range changes.Paths() {
		c := changes[p]
		if c.Ignored {
			continue
		}
		if c.Kind == core.Deleted {
			fmt.Fprintf(&info, "0 0000000000000000000000000000000000000000\t%s\n", p)
			continue
		}
		host := content(p)
		fi, err := os.Lstat(host)
		if err != nil {
			return Snapshot{}, err
		}
		switch {
		case fi.Mode()&os.ModeSymlink != 0:
			target, err := os.Readlink(host)
			if err != nil {
				return Snapshot{}, err
			}
			sha, err := git(r.Dir, env, []byte(target), "hash-object", "-w", "--stdin")
			if err != nil {
				return Snapshot{}, err
			}
			fmt.Fprintf(&info, "120000 %s\t%s\n", sha, p)
		case fi.Mode().IsRegular():
			files = append(files, host)
			filePaths = append(filePaths, p)
			mode := "100644"
			if fi.Mode().Perm()&0o111 != 0 {
				mode = "100755"
			}
			filePaths[len(filePaths)-1] = mode + "\x00" + p
		}
	}
	if len(files) > 0 {
		out, err := git(r.Dir, env, []byte(strings.Join(files, "\n")+"\n"), "hash-object", "-w", "--stdin-paths")
		if err != nil {
			return Snapshot{}, err
		}
		shas := strings.Fields(out)
		if len(shas) != len(files) {
			return Snapshot{}, fmt.Errorf("hash-object returned %d ids for %d files", len(shas), len(files))
		}
		for i, sha := range shas {
			mode, p, _ := strings.Cut(filePaths[i], "\x00")
			fmt.Fprintf(&info, "%s %s\t%s\n", mode, sha, p)
		}
	}
	if info.Len() > 0 {
		if _, err := git(r.Dir, env, info.Bytes(), "update-index", "--index-info"); err != nil {
			return Snapshot{}, err
		}
	}
	tree, err := git(r.Dir, env, nil, "write-tree")
	if err != nil {
		return Snapshot{}, err
	}
	return r.commit(tree, parent, ref, msg, start)
}

func (r *Repo) commit(tree, parent, ref, msg string, start time.Time) (Snapshot, error) {
	args := []string{"commit-tree", tree, "-m", msg}
	if parent != "" {
		args = append(args, "-p", parent)
	}
	commit, err := git(r.Dir, nil, nil, args...)
	if err != nil {
		return Snapshot{}, err
	}
	if ref != "" {
		if _, err := git(r.Dir, nil, nil, "update-ref", ref, commit); err != nil {
			return Snapshot{}, err
		}
	}
	return Snapshot{Commit: commit, Tree: tree, Ref: ref, Duration: time.Since(start)}, nil
}

// Diff returns the per-path changes between two snapshot commits (or trees).
func (r *Repo) Diff(from, to string) (core.ChangeSet, error) {
	out, err := git(r.Dir, nil, nil, "diff-tree", "-r", "-z", "--no-renames", "--raw", from, to)
	if err != nil {
		return nil, err
	}
	cs := core.ChangeSet{}
	fields := strings.Split(out, "\x00")
	for i := 0; i+1 < len(fields); i += 2 {
		meta := strings.Fields(strings.TrimPrefix(fields[i], ":"))
		if len(meta) < 5 {
			continue
		}
		oldMode, newMode, oldSha, newSha, status := meta[0], meta[1], meta[2], meta[3], meta[4]
		path := fields[i+1]
		kind := core.Modified
		switch status {
		case "A":
			kind = core.Added
		case "D":
			kind = core.Deleted
		case "T":
			kind = core.TypeChanged
		case "M":
			if oldSha == newSha && oldMode != newMode {
				kind = core.ModeChanged
			}
		}
		cs.Add(path, kind, false)
	}
	return cs, nil
}

// Publish squashes snapshot's tree onto base and writes it as branch in the
// project repository with a compare-and-swap ref update. It returns the new
// commit. Only this call writes into the project repository.
func (r *Repo) Publish(projectDir, base, snapshot, branch, msg string) (string, error) {
	commit, err := git(r.Dir, nil, nil, "commit-tree", snapshot+"^{tree}", "-p", base, "-m", msg)
	if err != nil {
		return "", err
	}
	tmpRef := "refs/publish/" + strings.ReplaceAll(branch, "/", "-")
	if _, err := git(r.Dir, nil, nil, "update-ref", tmpRef, commit); err != nil {
		return "", err
	}
	if _, err := git(projectDir, nil, nil, "fetch", "-q", "--no-tags", r.Dir, tmpRef+":refs/spike-incoming/"+strings.ReplaceAll(branch, "/", "-")); err != nil {
		return "", err
	}
	// Compare-and-swap: the branch must not exist yet (zero old value).
	if _, err := git(projectDir, nil, nil, "update-ref", "refs/heads/"+branch, commit, "0000000000000000000000000000000000000000"); err != nil {
		return "", err
	}
	_, _ = git(projectDir, nil, nil, "update-ref", "-d", "refs/spike-incoming/"+strings.ReplaceAll(branch, "/", "-"))
	return commit, nil
}

// MergePreview runs git merge-tree --write-tree between two refs in the
// project repository without touching any checkout. It returns whether the
// merge is clean and the conflicted paths.
func MergePreview(projectDir, a, b string) (bool, []string, error) {
	cmd := exec.Command("git", "merge-tree", "--write-tree", "--name-only", "--no-messages", a, b)
	cmd.Dir = projectDir
	cmd.Env = baseEnv
	out, err := cmd.Output()
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	var exit *exec.ExitError
	switch {
	case err == nil:
		return true, nil, nil
	case errors.As(err, &exit) && exit.ExitCode() == 1:
		if len(lines) > 1 {
			return false, lines[1:], nil
		}
		return false, nil, nil
	default:
		return false, nil, err
	}
}

// Rev resolves a revision in dir.
func Rev(dir, rev string) (string, error) { return git(dir, nil, nil, "rev-parse", rev) }

// Refs lists refs in a repository (for detecting agent commits/branches).
func Refs(dir string) (map[string]string, error) {
	out, err := git(dir, nil, nil, "for-each-ref", "--format=%(objectname) %(refname)")
	if err != nil {
		return nil, err
	}
	refs := map[string]string{}
	for _, line := range strings.Split(out, "\n") {
		sha, name, ok := strings.Cut(line, " ")
		if ok {
			refs[name] = sha
		}
	}
	if head, err := git(dir, nil, nil, "rev-parse", "HEAD"); err == nil {
		refs["HEAD"] = head
	}
	return refs, nil
}

// ObjectCount reports loose objects and their size in the shadow store.
func (r *Repo) ObjectCount() (int, int64) {
	out, err := git(r.Dir, nil, nil, "count-objects", "-v")
	if err != nil {
		return 0, 0
	}
	var n int
	var kb int64
	for _, line := range strings.Split(out, "\n") {
		k, v, _ := strings.Cut(line, ": ")
		switch k {
		case "count":
			n, _ = strconv.Atoi(v)
		case "size":
			kb, _ = strconv.ParseInt(v, 10, 64)
		}
	}
	return n, kb * 1024
}
