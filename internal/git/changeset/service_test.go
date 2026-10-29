package changeset_test

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/git"
	"github.com/dbpprt/dieter/internal/git/changeset"
	"github.com/dbpprt/dieter/internal/git/workspace"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

type countingGitReads struct {
	commands [][]string
}

func (r *countingGitReads) Run(ctx context.Context, directory string, args ...string) (git.Result, error) {
	r.commands = append(r.commands, append([]string(nil), args...))
	return (git.ExecRunner{}).Run(ctx, directory, args...)
}

func TestProjectChangesUseOneStatusAndLoadUntrackedContentOnlyForSelectedDiff(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Read cost", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	// Cross the streaming buffer boundary and omit the final newline.
	content := strings.Repeat("some content\n", 10_000) + "last line"
	filePath := filepath.Join(repository, "untracked.txt")
	if err := os.WriteFile(filePath, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	manager := workspace.New(data, nil)
	runner := &countingGitReads{}
	manager.SetGitRunner(runner)
	service := changeset.New(manager)
	set, err := service.GetProject(context.Background(), project.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(set.Files) != 1 || len(runner.commands) != 1 || len(runner.commands[0]) == 0 || runner.commands[0][0] != "status" {
		t.Fatalf("changes=%#v commands=%#v", set.Files, runner.commands)
	}
	runner.commands = nil
	diff, err := service.FileDiffTarget(context.Background(), "", project.ID, set.Revision, "untracked.txt", "", "unstaged", 0, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if len(runner.commands) != 2 || runner.commands[0][0] != "status" || runner.commands[1][0] != "diff" {
		t.Fatalf("selected diff commands=%#v", runner.commands)
	}
	if !strings.Contains(diff.Patch, "+last line") {
		t.Fatal("diff omitted the tail of the untracked file")
	}
	if err := os.WriteFile(filePath, []byte(content+" changed"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := service.FileDiffTarget(context.Background(), "", project.ID, set.Revision, "untracked.txt", "", "unstaged", 0, 1<<20); !errors.Is(err, changeset.ErrStaleRevision) {
		t.Fatalf("tail edit must invalidate the old revision: %v", err)
	}
}

func TestConcurrentProjectRefreshesShareOneStatusCommand(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Coalesced", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repository, "README.md"), []byte("changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	manager := workspace.New(data, nil)
	runner := &slowCountingRunner{}
	manager.SetGitRunner(runner)
	service := changeset.New(manager)
	start := make(chan struct{})
	errorsByCall := make(chan error, 24)
	var group sync.WaitGroup
	for range 24 {
		group.Add(1)
		go func() {
			defer group.Done()
			<-start
			value, readErr := service.GetProject(context.Background(), project.ID)
			if readErr == nil && len(value.Files) != 1 {
				readErr = errors.New("coalesced snapshot lost the changed file")
			}
			errorsByCall <- readErr
		}()
	}
	close(start)
	group.Wait()
	close(errorsByCall)
	for readErr := range errorsByCall {
		if readErr != nil {
			t.Fatal(readErr)
		}
	}
	if calls := runner.count(); calls != 1 {
		t.Fatalf("concurrent refreshes ran %d status commands", calls)
	}
}

func TestProjectChangesWithOneThousandFilesStillUsesOneStatusCommand(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	generated := filepath.Join(repository, "generated")
	if err := os.MkdirAll(generated, 0o755); err != nil {
		t.Fatal(err)
	}
	for index := range 1_000 {
		name := filepath.Join(generated, fmt.Sprintf("file-%04d.txt", index))
		if err := os.WriteFile(name, []byte("change\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Scale", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	manager := workspace.New(data, nil)
	runner := &countingGitReads{}
	manager.SetGitRunner(runner)
	started := time.Now()
	value, err := changeset.New(manager).GetProject(context.Background(), project.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(value.Files) != 1_000 || len(runner.commands) != 1 || runner.commands[0][0] != "status" {
		t.Fatalf("files=%d commands=%#v", len(value.Files), runner.commands)
	}
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("one-command 1,000-file status took %s", elapsed)
	}
}

type slowCountingRunner struct {
	mu    sync.Mutex
	calls int
}

func (r *slowCountingRunner) Run(ctx context.Context, directory string, args ...string) (git.Result, error) {
	r.mu.Lock()
	r.calls++
	r.mu.Unlock()
	// Callers resolve the project under the store lock one at a time first; on
	// a loaded race-enabled runner the last ones arrive well after the first,
	// and must still find the status read in flight or cached.
	time.Sleep(250 * time.Millisecond)
	return (git.ExecRunner{}).Run(ctx, directory, args...)
}

func (r *slowCountingRunner) count() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.calls
}

func TestChangesetIncludesTrackedAndUntrackedDiffsAndRejectsStaleRevision(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Fixture", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "Changes", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
	if err != nil {
		t.Fatal(err)
	}
	manager := workspace.New(data, nil)
	value, err := manager.Ensure(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(value.Path, "README.md"), []byte("changed\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(value.Path, "new.txt"), []byte("first\nsecond\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	service := changeset.New(manager)
	set, err := service.Get(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(set.Files) != 2 || set.Revision == "" || !set.Dirty {
		t.Fatalf("unexpected changeset: %#v", set)
	}
	diff, err := service.FileDiff(context.Background(), chat.ID, set.Revision, "new.txt", "", 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(diff.Patch, "+first") || diff.TotalBytes == 0 {
		t.Fatalf("untracked patch was not returned: %#v", diff)
	}
	if err := os.WriteFile(filepath.Join(value.Path, "new.txt"), []byte("new revision\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := service.FileDiff(context.Background(), chat.ID, set.Revision, "new.txt", "", 0, 0); !errors.Is(err, changeset.ErrStaleRevision) {
		t.Fatalf("expected stale revision, got %v", err)
	}
}

func TestProjectDirectoryChangesetUsesItsCurrentFeatureBranch(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	testkit.RunGit(t, repository, "switch", "-c", "feature/direct")
	if err := os.WriteFile(filepath.Join(repository, "feature.txt"), []byte("feature\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	testkit.RunGit(t, repository, "add", "feature.txt")
	testkit.RunGit(t, repository, "commit", "-m", "feature commit")
	if err := os.WriteFile(filepath.Join(repository, "README.md"), []byte("local project change\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Fixture", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "Direct", Prompt: "work", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	manager := workspace.New(data, nil)
	value, err := manager.Ensure(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	service := changeset.New(manager)
	if _, err := service.Get(context.Background(), chat.ID); !errors.Is(err, changeset.ErrProjectChangesRequireProject) {
		t.Fatalf("project-mode card changes must be rejected, got %v", err)
	}
	set, err := service.GetProject(context.Background(), project.ID)
	if err != nil {
		t.Fatal(err)
	}
	canonicalRepository, err := filepath.EvalSymlinks(repository)
	if err != nil {
		t.Fatal(err)
	}
	if value.Path != canonicalRepository || set.ProjectID != project.ID || set.CardID != "" || set.Branch != "feature/direct" || len(set.Files) != 1 || set.Files[0].Path != "README.md" || len(set.Commits) != 0 {
		t.Fatalf("unexpected direct feature-branch changeset: workspace=%#v changes=%#v", value, set)
	}
}

func TestChangesetSeparatesStagedAndUnstagedSections(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Fixture", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "Sections", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
	if err != nil {
		t.Fatal(err)
	}
	manager := workspace.New(data, nil)
	value, err := manager.Ensure(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(value.Path, "README.md"), []byte("staged\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	testkit.RunGit(t, value.Path, "add", "README.md")
	if err := os.WriteFile(filepath.Join(value.Path, "README.md"), []byte("staged\nunstaged\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	service := changeset.New(manager)
	set, err := service.Get(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(set.Files) != 1 || !set.Files[0].Staged || !set.Files[0].Unstaged {
		t.Fatalf("unexpected staged/unstaged split: %#v", set.Files)
	}
	staged, err := service.FileDiffTarget(context.Background(), chat.ID, "", set.Revision, "README.md", "", changeset.DiffSectionStaged, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	unstaged, err := service.FileDiffTarget(context.Background(), chat.ID, "", set.Revision, "README.md", "", changeset.DiffSectionUnstaged, 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(staged.Patch, "+staged") || strings.Contains(staged.Patch, "+unstaged") || !strings.Contains(unstaged.Patch, "+unstaged") {
		t.Fatalf("section patches were not isolated: staged=%q unstaged=%q", staged.Patch, unstaged.Patch)
	}
}

func TestCommitDiffWithoutPathReturnsTheWholeCommitPatch(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Fixture", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "Commits", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
	if err != nil {
		t.Fatal(err)
	}
	manager := workspace.New(data, nil)
	value, err := manager.Ensure(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(value.Path, "one.txt"), []byte("one\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(value.Path, "two.txt"), []byte("two\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	testkit.RunGit(t, value.Path, "add", "-A")
	testkit.RunGit(t, value.Path, "commit", "-m", "add both files")

	service := changeset.New(manager)
	set, err := service.Get(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(set.Commits) != 0 || len(set.Files) != 0 {
		t.Fatalf("working changes must exclude committed history: %#v", set)
	}
	sha := testkit.RunGit(t, value.Path, "rev-parse", "HEAD")
	diff, err := service.CommitDiff(context.Background(), chat.ID, set.Revision, sha, "", 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(diff.Patch, "+one") || !strings.Contains(diff.Patch, "+two") {
		t.Fatalf("whole-commit patch missing files: %#v", diff)
	}
	if _, err := service.FileDiff(context.Background(), chat.ID, set.Revision, "", "", 0, 0); err == nil {
		t.Fatal("working-tree diff without a path must stay rejected")
	}
}

func TestProjectChangesPreserveGitStatusesAndUnusualPaths(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	write := func(name, body string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(repository, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("old.txt", "rename source\nunchanged content\n")
	write("gone.txt", "deleted content\n")
	testkit.RunGit(t, repository, "add", "-A")
	testkit.RunGit(t, repository, "commit", "-m", "status fixture")
	if err := os.Rename(filepath.Join(repository, "old.txt"), filepath.Join(repository, "renamed\tfile.txt")); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(repository, "gone.txt")); err != nil {
		t.Fatal(err)
	}
	write("new\nfile.txt", "brand new content\n")
	testkit.RunGit(t, repository, "add", "-A")
	write("README.md", "modified working tree\n")
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Statuses", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	service := changeset.New(workspace.New(data, nil))
	set, err := service.GetProject(context.Background(), project.ID)
	if err != nil {
		t.Fatal(err)
	}
	files := map[string]model.ChangedFile{}
	for _, file := range set.Files {
		files[file.Path] = file
	}
	if len(files) != 4 {
		t.Fatalf("unexpected changes: %#v", files)
	}
	for name, expected := range map[string]string{"renamed\tfile.txt": "renamed", "gone.txt": "deleted", "new\nfile.txt": "added"} {
		if file := files[name]; file.IndexStatus != expected || !file.Staged {
			t.Errorf("%q: expected staged %s, got %#v", name, expected, file)
		}
	}
	if files["renamed\tfile.txt"].PreviousPath != "old.txt" {
		t.Fatalf("lost rename source: %#v", files)
	}
	if files["README.md"].WorktreeStatus != "modified" || !files["README.md"].Unstaged {
		t.Fatal("working-tree status was lost")
	}
}
