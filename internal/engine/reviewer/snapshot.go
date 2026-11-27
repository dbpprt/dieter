// Package reviewer reviews a conversation's changes with a separately
// configured harness: it snapshots the workspace without touching it, renders
// the change, builds the reviewer prompt (adapted from pr-agent's reviewer,
// MIT, see THIRD_PARTY_NOTICES.md) and turns the reviewer's answer into
// validated findings. The engine runs the harness turn.
package reviewer

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// EmptyTree is Git's empty tree, the base of a change in a repository (or an
// orphan worktree) without a usable base commit.
const EmptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

// maxGitOutput bounds what one Git command may return.
const maxGitOutput = 32 << 20

// Snapshot is a disposable, detached worktree of a workspace's current state:
// the commit captures tracked changes, staged or not, and untracked files
// that are not ignored. The reviewer works there, so it can neither see later
// edits nor change the conversation's workspace.
type Snapshot struct {
	// Dir is the snapshot worktree; Commit and Tree are what it holds.
	Dir, Commit, Tree string
	// Head is the workspace's HEAD when the snapshot was taken ("" unborn).
	Head string
	repo string
	root string
}

// TakeSnapshot snapshots the workspace at repoDir into a new directory under
// root (which it creates and Close removes). The workspace's index, HEAD and
// refs are untouched: a temporary index file collects the tree.
func TakeSnapshot(ctx context.Context, repoDir, root string) (_ Snapshot, err error) {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return Snapshot{}, err
	}
	snapshot := Snapshot{repo: repoDir, root: root}
	defer func() {
		if err != nil {
			snapshot.Close()
		}
	}()
	top, err := gitOutput(ctx, repoDir, nil, "rev-parse", "--show-toplevel")
	if err != nil {
		return snapshot, fmt.Errorf("the workspace is not a Git checkout: %w", err)
	}
	snapshot.repo = top
	if head, headErr := gitOutput(ctx, top, nil, "rev-parse", "--verify", "--quiet", "HEAD^{commit}"); headErr == nil {
		snapshot.Head = head
	}
	index := []string{"GIT_INDEX_FILE=" + filepath.Join(root, "index")}
	if snapshot.Head != "" {
		_, err = git(ctx, top, index, nil, "read-tree", snapshot.Head)
	} else {
		_, err = git(ctx, top, index, nil, "read-tree", "--empty")
	}
	if err != nil {
		return snapshot, err
	}
	if _, err = git(ctx, top, index, nil, "add", "--all", "--", "."); err != nil {
		return snapshot, fmt.Errorf("snapshot the workspace: %w", err)
	}
	if snapshot.Tree, err = gitOutput(ctx, top, index, "write-tree"); err != nil {
		return snapshot, err
	}
	args := []string{"-c", "commit.gpgSign=false", "commit-tree", "--no-gpg-sign", snapshot.Tree, "-m", "Dieter code review snapshot"}
	if snapshot.Head != "" {
		args = append(args, "-p", snapshot.Head)
	}
	identity := []string{
		"GIT_AUTHOR_NAME=Dieter", "GIT_AUTHOR_EMAIL=reviewer@dieter.invalid",
		"GIT_COMMITTER_NAME=Dieter", "GIT_COMMITTER_EMAIL=reviewer@dieter.invalid",
	}
	if snapshot.Commit, err = gitOutput(ctx, top, identity, args...); err != nil {
		return snapshot, err
	}
	dir := filepath.Join(root, "tree")
	// No hooks or LFS downloads: this checkout is a read-only copy.
	if _, err = git(ctx, top, []string{"GIT_LFS_SKIP_SMUDGE=1"}, nil, "-c", "core.hooksPath=/dev/null", "worktree", "add", "--detach", "--quiet", dir, snapshot.Commit); err != nil {
		return snapshot, fmt.Errorf("check out the snapshot: %w", err)
	}
	snapshot.Dir = dir
	return snapshot, nil
}

// Close removes the snapshot worktree and its directory. It is safe to call
// more than once and on a partial snapshot.
func (s *Snapshot) Close() {
	if s.Dir != "" && s.repo != "" {
		ctx, cancel := context.WithTimeout(context.Background(), gitCleanupTimeout)
		_, _ = git(ctx, s.repo, nil, nil, "worktree", "remove", "--force", s.Dir)
		cancel()
	}
	if s.root != "" {
		_ = os.RemoveAll(s.root)
		if s.repo != "" {
			ctx, cancel := context.WithTimeout(context.Background(), gitCleanupTimeout)
			_, _ = git(ctx, s.repo, nil, nil, "worktree", "prune")
			cancel()
		}
	}
	s.Dir, s.root = "", ""
}

// MergeBase is the commit the change is measured from: the merge base of
// base and HEAD for a worktree that branched from base, HEAD itself for a
// project checkout (only uncommitted work), or the empty tree when there is
// no usable commit (an unborn branch, unrelated histories).
func MergeBase(ctx context.Context, repoDir, base, head string) string {
	if head == "" {
		return EmptyTree
	}
	if base == "" {
		return head
	}
	if commit, err := gitOutput(ctx, repoDir, nil, "rev-parse", "--verify", "--quiet", base+"^{commit}"); err == nil {
		base = commit
	}
	if merged, err := gitOutput(ctx, repoDir, nil, "merge-base", base, head); err == nil && merged != "" {
		return merged
	}
	return EmptyTree
}

// git runs one Git command with its own stdout and stderr (stderr never
// reaches the output), bounded output and no prompts or index refreshes.
func git(ctx context.Context, dir string, env []string, stdin io.Reader, args ...string) ([]byte, error) {
	command := exec.CommandContext(ctx, "git", append([]string{"-c", "diff.autoRefreshIndex=false", "-c", "core.quotePath=false", "-c", "log.showSignature=false"}, args...)...)
	command.Dir = dir
	command.Env = append(gitEnvironment(), env...)
	command.Stdin = stdin
	var stdout limited
	var stderr bytes.Buffer
	stdout.limit = maxGitOutput
	command.Stdout, command.Stderr = &stdout, &stderr
	err := command.Run()
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if err != nil {
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = err.Error()
		}
		return nil, fmt.Errorf("git %s: %s", firstArg(args), lastLine(message))
	}
	if stdout.truncated {
		return stdout.Bytes(), errTruncated
	}
	return stdout.Bytes(), nil
}

var errTruncated = errors.New("git output exceeded its bound")

func gitOutput(ctx context.Context, dir string, env []string, args ...string) (string, error) {
	output, err := git(ctx, dir, env, nil, args...)
	return strings.TrimSpace(string(output)), err
}

func gitEnvironment() []string {
	values := os.Environ()
	result := make([]string, 0, len(values)+6)
	for _, value := range values {
		name, _, _ := strings.Cut(value, "=")
		switch name {
		case "GIT_TERMINAL_PROMPT", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR", "LC_ALL", "GIT_OPTIONAL_LOCKS", "GIT_INDEX_FILE", "GIT_DIR", "GIT_WORK_TREE":
			continue
		}
		result = append(result, value)
	}
	return append(result, "GIT_TERMINAL_PROMPT=0", "GIT_EDITOR=true", "GIT_SEQUENCE_EDITOR=true", "LC_ALL=C", "GIT_OPTIONAL_LOCKS=0")
}

func firstArg(args []string) string {
	for index := 0; index < len(args); index++ {
		if args[index] == "-c" {
			index++
			continue
		}
		return args[index]
	}
	return ""
}

func lastLine(message string) string {
	lines := strings.Split(strings.TrimSpace(message), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

type limited struct {
	bytes.Buffer
	limit     int
	truncated bool
}

func (b *limited) Write(value []byte) (int, error) {
	original := len(value)
	remaining := b.limit - b.Len()
	if remaining <= 0 {
		b.truncated = true
		return original, nil
	}
	if len(value) > remaining {
		value = value[:remaining]
		b.truncated = true
	}
	_, err := b.Buffer.Write(value)
	return original, err
}
