package git_test

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/dbpprt/dieter/internal/git"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestReadReportsStagedUnstagedUntrackedAndRenamedFromOneStatusCommand(t *testing.T) {
	t.Parallel()
	repository := testkit.EmptyGitRepo(t)
	writeFile(t, repository, "both.txt", "base\n")
	writeFile(t, repository, "old name.txt", "old\n")
	testkit.RunGit(t, repository, "add", ".")
	testkit.RunGit(t, repository, "commit", "-m", "fixture")

	writeFile(t, repository, "both.txt", "staged\n")
	testkit.RunGit(t, repository, "add", "both.txt")
	writeFile(t, repository, "both.txt", "unstaged\n")
	testkit.RunGit(t, repository, "mv", "old name.txt", "new name.txt")
	writeFile(t, repository, "untracked.txt", "new\n")

	runner := &countingRunner{}
	value, err := git.ReadStatus(context.Background(), runner, repository)
	if err != nil {
		t.Fatal(err)
	}
	if runner.calls != 1 || value.Branch != "main" || value.HeadSHA == "" || !value.Dirty || value.Revision == "" {
		t.Fatalf("snapshot=%#v calls=%d", value, runner.calls)
	}
	files := map[string]struct {
		staged, unstaged bool
		previous         string
	}{}
	for _, file := range value.Files {
		files[file.Path] = struct {
			staged, unstaged bool
			previous         string
		}{file.Staged, file.Unstaged, file.PreviousPath}
	}
	if both := files["both.txt"]; !both.staged || !both.unstaged {
		t.Fatalf("partially staged file=%#v", both)
	}
	if renamed := files["new name.txt"]; !renamed.staged || renamed.previous != "old name.txt" {
		t.Fatalf("rename=%#v", renamed)
	}
	if untracked := files["untracked.txt"]; untracked.staged || !untracked.unstaged {
		t.Fatalf("untracked=%#v", untracked)
	}

	before := value.Revision
	writeFile(t, repository, "untracked.txt", "changed contents\n")
	value, err = git.ReadStatus(context.Background(), runner, repository)
	if err != nil {
		t.Fatal(err)
	}
	if value.Revision == before {
		t.Fatal("working-tree edit did not change the cheap revision")
	}
}

func TestParseReportsSubmoduleAndUnmergedRecords(t *testing.T) {
	t.Parallel()
	raw := []byte(strings.Join([]string{
		"# branch.oid 0123456789012345678901234567890123456789",
		"# branch.head main",
		"1 M. S.M. 160000 160000 160000 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 vendor/module",
		"u UU N... 100644 100644 100644 100644 1111111111111111111111111111111111111111 2222222222222222222222222222222222222222 3333333333333333333333333333333333333333 conflicted.txt",
		"",
	}, "\x00"))
	value, err := git.ParseStatus(raw)
	if err != nil {
		t.Fatal(err)
	}
	if len(value.Files) != 2 || !value.Dirty || !value.Conflicted {
		t.Fatalf("snapshot=%#v", value)
	}
	if file := value.Files[1]; file.Path != "vendor/module" || !file.Submodule || !file.Staged {
		t.Fatalf("submodule=%#v", file)
	}
	if file := value.Files[0]; file.Path != "conflicted.txt" || !file.Conflicted || !file.Staged || !file.Unstaged || file.Status != "conflicted" {
		t.Fatalf("conflict=%#v", file)
	}
}

func TestReadReportsRealMergeConflict(t *testing.T) {
	t.Parallel()
	repository := testkit.EmptyGitRepo(t)
	writeFile(t, repository, "both.txt", "base\n")
	testkit.RunGit(t, repository, "add", "both.txt")
	testkit.RunGit(t, repository, "commit", "-m", "base")
	testkit.RunGit(t, repository, "switch", "-c", "feature")
	writeFile(t, repository, "both.txt", "feature\n")
	testkit.RunGit(t, repository, "add", "both.txt")
	testkit.RunGit(t, repository, "commit", "-m", "feature")
	testkit.RunGit(t, repository, "switch", "main")
	writeFile(t, repository, "both.txt", "main\n")
	testkit.RunGit(t, repository, "add", "both.txt")
	testkit.RunGit(t, repository, "commit", "-m", "main")
	command := exec.Command("git", "merge", "feature")
	command.Dir = repository
	if err := command.Run(); err == nil {
		t.Fatal("merge unexpectedly succeeded")
	}

	value, err := git.ReadStatus(context.Background(), git.ExecRunner{}, repository)
	if err != nil {
		t.Fatal(err)
	}
	if len(value.Files) != 1 || !value.Conflicted || !value.Files[0].Conflicted || value.Files[0].Path != "both.txt" {
		t.Fatalf("conflicted snapshot=%#v", value)
	}
}

func TestForcedReadDoesNotJoinOlderPresentationRead(t *testing.T) {
	t.Parallel()
	runner := &blockingRunner{started: make(chan struct{}), release: make(chan struct{})}
	reader := git.NewStatusReader(runner)
	first := make(chan git.StatusSnapshot, 1)
	go func() {
		value, _ := reader.Read(context.Background(), "fixture", false)
		first <- value
	}()
	<-runner.started
	forced := make(chan git.StatusSnapshot, 1)
	go func() {
		value, _ := reader.Read(context.Background(), "fixture", true)
		forced <- value
	}()
	close(runner.release)
	if value := <-first; value.Dirty {
		t.Fatalf("first snapshot=%#v", value)
	}
	if value := <-forced; !value.Dirty || len(value.Files) != 1 {
		t.Fatalf("forced snapshot reused older scan: %#v", value)
	}
	if runner.count() != 2 {
		t.Fatalf("status calls=%d, want 2", runner.count())
	}
}

func TestInvalidationDuringReadPreventsStaleSnapshotFromEnteringCache(t *testing.T) {
	t.Parallel()
	runner := &blockingRunner{started: make(chan struct{}), release: make(chan struct{})}
	reader := git.NewStatusReader(runner)
	first := make(chan git.StatusSnapshot, 1)
	go func() {
		value, _ := reader.Read(context.Background(), "fixture", false)
		first <- value
	}()
	<-runner.started
	reader.Invalidate("fixture")
	close(runner.release)
	if value := <-first; !value.Dirty {
		t.Fatalf("invalidated caller returned the stale snapshot: %#v", value)
	}
	value, err := reader.Read(context.Background(), "fixture", false)
	if err != nil {
		t.Fatal(err)
	}
	if !value.Dirty || runner.count() != 2 {
		t.Fatalf("snapshot=%#v status calls=%d", value, runner.count())
	}
}

type blockingRunner struct {
	mu      sync.Mutex
	calls   int
	started chan struct{}
	release chan struct{}
}

func (r *blockingRunner) Run(context.Context, string, ...string) (git.Result, error) {
	r.mu.Lock()
	r.calls++
	call := r.calls
	if call == 1 {
		close(r.started)
	}
	r.mu.Unlock()
	if call == 1 {
		<-r.release
		return git.Result{Output: []byte("# branch.head main\x00")}, nil
	}
	return git.Result{Output: []byte("# branch.head main\x00? changed.txt\x00")}, nil
}

func (r *blockingRunner) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.calls
}

type countingRunner struct{ calls int }

func (r *countingRunner) Run(ctx context.Context, directory string, args ...string) (git.Result, error) {
	r.calls++
	return (git.ExecRunner{}).Run(ctx, directory, args...)
}

func writeFile(t *testing.T, root, name, value string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, name), []byte(value), 0o644); err != nil {
		t.Fatal(err)
	}
}
