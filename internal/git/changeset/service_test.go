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
	set, err := service.GetTarget(context.Background(), "", project.ID)
	if err != nil {
		t.Fatal(err)
	}
	// One status for the list, one staged and one unstaged numstat for the
	// line counts; no per-file command.
	if len(set.Files) != 1 || len(runner.commands) != 3 || runner.commands[0][0] != "status" || runner.commands[1][0] != "diff" || runner.commands[2][0] != "diff" {
		t.Fatalf("changes=%#v commands=%#v", set.Files, runner.commands)
	}
	if set.Files[0].UnstagedAdditions != 10_001 || set.Additions != 10_001 {
		t.Fatalf("untracked line count = %d, total %d", set.Files[0].UnstagedAdditions, set.Additions)
	}
	runner.commands = nil
	if again, err := service.GetTarget(context.Background(), "", project.ID); err != nil || again.Additions != 10_001 {
		t.Fatalf("again=%#v err=%v", again, err)
	}
	if len(runner.commands) > 1 {
		t.Fatalf("an unchanged tree must reuse its line counts: %#v", runner.commands)
	}
	runner.commands = nil
	diff, err := service.FileDiffTarget(context.Background(), "", project.ID, "untracked.txt", "", "unstaged", "", 0, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if len(runner.commands) != 2 || runner.commands[0][0] != "status" || runner.commands[1][0] != "diff" {
		t.Fatalf("selected diff commands=%#v", runner.commands)
	}
	if !strings.Contains(diff.Patch, "+last line") || diff.FileRevision != set.Files[0].Revision {
		t.Fatalf("diff omitted the tail of the untracked file or its revision: %q", diff.FileRevision)
	}
	if err := os.WriteFile(filePath, []byte(content+" changed"), 0o644); err != nil {
		t.Fatal(err)
	}
	// A read never fails because the file changed; it shows the new content.
	changed, err := service.FileDiffTarget(context.Background(), "", project.ID, "untracked.txt", "", "unstaged", "", 0, 1<<20)
	if err != nil || !strings.Contains(changed.Patch, "+last line changed") || changed.FileRevision == diff.FileRevision {
		t.Fatalf("changed diff=%q revision=%q err=%v", changed.Patch[max(0, len(changed.Patch)-40):], changed.FileRevision, err)
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
			value, readErr := service.GetTarget(context.Background(), "", project.ID)
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
	// One status and one pair of numstat reads serve every caller.
	if calls := runner.count(); calls != 3 {
		t.Fatalf("concurrent refreshes ran %d Git commands", calls)
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
	value, err := changeset.New(manager).GetTarget(context.Background(), "", project.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(value.Files) != 1_000 || len(runner.commands) != 3 || runner.commands[0][0] != "status" || value.Additions != 1_000 {
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
	set, err := service.GetTarget(context.Background(), chat.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(set.Files) != 2 || set.Revision == "" || !set.Dirty || set.Scope != model.ChangesetScopeWorktree {
		t.Fatalf("unexpected changeset: %#v", set)
	}
	diff, err := service.FileDiffTarget(context.Background(), chat.ID, "", "new.txt", "", "", "", 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(diff.Patch, "+first") || diff.TotalBytes == 0 {
		t.Fatalf("untracked patch was not returned: %#v", diff)
	}
	// Writes to another file leave this file's revision and diff alone.
	if err := os.WriteFile(filepath.Join(value.Path, "README.md"), []byte("changed again\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	same, err := service.FileDiffTarget(context.Background(), chat.ID, "", "new.txt", "", "", "", 0, 0)
	if err != nil || same.FileRevision != diff.FileRevision || same.Patch != diff.Patch {
		t.Fatalf("an unrelated write changed new.txt: %#v err=%v", same, err)
	}
	if err := os.WriteFile(filepath.Join(value.Path, "new.txt"), []byte("new revision\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	fresh, err := service.FileDiffTarget(context.Background(), chat.ID, "", "new.txt", "", "", "", 0, 0)
	if err != nil || !strings.Contains(fresh.Patch, "+new revision") || fresh.FileRevision == diff.FileRevision {
		t.Fatalf("expected the new content, got %#v err=%v", fresh, err)
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
	// A project-directory conversation reads its checkout.
	conversation, err := service.GetTarget(context.Background(), chat.ID, "")
	if err != nil || conversation.Scope != model.ChangesetScopeCheckout || conversation.CardID != chat.ID || len(conversation.Files) != 1 {
		t.Fatalf("project-mode conversation changes=%#v err=%v", conversation, err)
	}
	set, err := service.GetTarget(context.Background(), "", project.ID)
	if err != nil {
		t.Fatal(err)
	}
	if conversation.Revision != set.Revision || conversation.CheckoutID != set.CheckoutID || set.Scope != model.ChangesetScopeCheckout {
		t.Fatalf("conversation and project changes differ: %#v vs %#v", conversation, set)
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
	set, err := service.GetTarget(context.Background(), chat.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(set.Files) != 1 || !set.Files[0].Staged || !set.Files[0].Unstaged {
		t.Fatalf("unexpected staged/unstaged split: %#v", set.Files)
	}
	staged, err := service.FileDiffTarget(context.Background(), chat.ID, "", "README.md", "", changeset.DiffSectionStaged, "", 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	unstaged, err := service.FileDiffTarget(context.Background(), chat.ID, "", "README.md", "", changeset.DiffSectionUnstaged, "", 0, 0)
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
	set, err := service.GetTarget(context.Background(), chat.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	// Committed work is listed as the branch's commits, not as working changes.
	if len(set.Files) != 0 || len(set.Commits) != 1 || set.Commits[0].Subject != "add both files" {
		t.Fatalf("committed history must be listed as commits only: %#v", set)
	}
	sha := testkit.RunGit(t, value.Path, "rev-parse", "HEAD")
	diff, err := service.FileDiffTarget(context.Background(), chat.ID, "", "", sha, "", "", 0, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(diff.Patch, "+one") || !strings.Contains(diff.Patch, "+two") {
		t.Fatalf("whole-commit patch missing files: %#v", diff)
	}
	if _, err := service.FileDiffTarget(context.Background(), chat.ID, "", "", "", "", "", 0, 0); err == nil {
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
	set, err := service.GetTarget(context.Background(), "", project.ID)
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

func TestWorktreeChangesetListsTheBranchCommitsAndLineCounts(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Branch", Path: repository, BaseBranch: "main"})
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
	// The agent commits its work: the worktree is clean, yet the branch has changes.
	if err := os.WriteFile(filepath.Join(value.Path, "feature.txt"), []byte("one\ntwo\nthree\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	testkit.RunGit(t, value.Path, "add", "feature.txt")
	testkit.RunGit(t, value.Path, "commit", "-m", "Add the feature")
	if err := os.WriteFile(filepath.Join(value.Path, "README.md"), []byte("edited\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	set, err := changeset.New(manager).GetTarget(context.Background(), chat.ID, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(set.Commits) != 1 || set.Commits[0].Subject != "Add the feature" || set.Commits[0].Additions != 3 || set.Commits[0].Files != 1 {
		t.Fatalf("branch commits=%#v", set.Commits)
	}
	if len(set.Files) != 1 || set.Files[0].Path != "README.md" || set.Files[0].UnstagedAdditions != 1 || set.Files[0].UnstagedDeletions == 0 {
		t.Fatalf("uncommitted files=%#v", set.Files)
	}
}

func TestDiffPagesComeFromOneRenderingAndRestartWhenTheFileChanged(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Pages", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	big := strings.Repeat("a line of the large file\n", 2_000)
	target := filepath.Join(repository, "large.txt")
	if err := os.WriteFile(target, []byte(big), 0o644); err != nil {
		t.Fatal(err)
	}
	service := changeset.New(workspace.New(data, nil))
	first, err := service.FileDiffTarget(context.Background(), "", project.ID, "large.txt", "", "unstaged", "", 0, 4096)
	if err != nil || !first.Truncated || first.FileRevision == "" {
		t.Fatalf("first page=%#v err=%v", first, err)
	}
	// Another file changing leaves the pages consistent.
	if err := os.WriteFile(filepath.Join(repository, "other.txt"), []byte("other\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	second, err := service.FileDiffTarget(context.Background(), "", project.ID, "large.txt", "", "unstaged", first.FileRevision, first.NextOffset, 4096)
	if err != nil || second.Restarted || second.FileRevision != first.FileRevision {
		t.Fatalf("second page=%#v err=%v", second, err)
	}
	// The file itself changing: the cached rendering still finishes the pages.
	if err := os.WriteFile(target, []byte(big+"tail\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	third, err := service.FileDiffTarget(context.Background(), "", project.ID, "large.txt", "", "unstaged", first.FileRevision, second.NextOffset, 4096)
	if err != nil || third.Restarted || third.FileRevision != first.FileRevision {
		t.Fatalf("third page=%#v err=%v", third, err)
	}
	// An unknown earlier rendering restarts at the new file's first page.
	restarted, err := service.FileDiffTarget(context.Background(), "", project.ID, "large.txt", "", "unstaged", "gone", second.NextOffset, 4096)
	if err != nil || !restarted.Restarted || restarted.FileRevision == first.FileRevision || !strings.HasPrefix(restarted.Patch, "diff --git") {
		t.Fatalf("restarted page=%#v err=%v", restarted, err)
	}
}

func TestFileRevisionsAndIndexFingerprintChangeOnlyWithTheirOwnState(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Revisions", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	write := func(name, body string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(repository, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("README.md", "staged\n")
	testkit.RunGit(t, repository, "add", "README.md")
	write("agent.txt", "v1\n")
	service := changeset.New(workspace.New(data, nil))
	read := func() model.Changeset {
		t.Helper()
		value, err := service.GetTargetFresh(context.Background(), "", project.ID)
		if err != nil {
			t.Fatal(err)
		}
		return value
	}
	revisionOf := func(set model.Changeset, path string) string {
		for _, file := range set.Files {
			if file.Path == path {
				return file.Revision
			}
		}
		return ""
	}
	before := read()
	time.Sleep(10 * time.Millisecond)
	write("agent.txt", "v2 with more\n")
	after := read()
	if after.Revision == before.Revision || revisionOf(after, "agent.txt") == revisionOf(before, "agent.txt") {
		t.Fatal("a working-tree edit must change the tree and the file revision")
	}
	if revisionOf(after, "README.md") != revisionOf(before, "README.md") || after.IndexFingerprint != before.IndexFingerprint {
		t.Fatal("an edit to another unstaged file changed README.md or the index fingerprint")
	}
	testkit.RunGit(t, repository, "add", "agent.txt")
	staged := read()
	if staged.IndexFingerprint == after.IndexFingerprint {
		t.Fatal("staging must change the index fingerprint")
	}
}

func TestHubReadsOnceForEveryWatcherAndWakesOnInvalidate(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Hub", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	service := changeset.New(workspace.New(data, nil))
	target, err := service.Resolve(context.Background(), "", project.ID)
	if err != nil {
		t.Fatal(err)
	}
	hub := changeset.NewHub(service)
	first := hub.Watch(target, nil)
	second := hub.Watch(target, nil)
	if hub.Watching() != 1 {
		t.Fatalf("two watchers of one directory started %d readers", hub.Watching())
	}
	waitRead := func(watch *changeset.Watch) (git.StatusSnapshot, <-chan struct{}) {
		t.Helper()
		deadline := time.After(10 * time.Second)
		for {
			reading := watch.Current()
			if reading.Err != nil {
				t.Fatal(reading.Err)
			}
			if reading.Read {
				return reading.Status, reading.Changed
			}
			select {
			case <-reading.Changed:
			case <-deadline:
				t.Fatal("the hub never read the directory")
			}
		}
	}
	initial, changed := waitRead(first)
	if len(initial.Files) != 0 {
		t.Fatalf("clean checkout listed %#v", initial.Files)
	}
	if err := os.WriteFile(filepath.Join(repository, "README.md"), []byte("watched\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	service.InvalidatePath(target.Workspace.Path)
	select {
	case <-changed:
	case <-time.After(5 * time.Second):
		t.Fatal("an invalidated directory was not reread")
	}
	if waited := time.Since(started); waited > 2*time.Second {
		t.Fatalf("invalidation took %s to publish", waited)
	}
	status, _ := waitRead(second)
	if len(status.Files) != 1 {
		t.Fatalf("watchers saw %#v", status.Files)
	}
	first.Release()
	if hub.Watching() != 1 {
		t.Fatal("releasing one watcher stopped the shared reader")
	}
	second.Release()
	if hub.Watching() != 0 {
		t.Fatal("the last release must stop the reader")
	}
}

func TestUnbornWorktreeCommitsAndRootDiffRemainReviewable(t *testing.T) {
	t.Parallel()
	repository := filepath.Join(t.TempDir(), "repository")
	testkit.InitGitRepo(t, repository)
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Empty", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "First", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
	if err != nil {
		t.Fatal(err)
	}
	manager := workspace.New(data, nil)
	value, err := manager.Ensure(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(value.Path, "first.txt")
	if err := os.WriteFile(file, []byte("root line\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	testkit.RunGit(t, value.Path, "add", "first.txt")
	testkit.RunGit(t, value.Path, "commit", "-m", "First commit")
	root := testkit.RunGit(t, value.Path, "rev-parse", "HEAD")
	if err := os.WriteFile(file, []byte("root line\nsecond line\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	testkit.RunGit(t, value.Path, "commit", "-am", "Second commit")
	if _, err := manager.Refresh(context.Background(), chat.ID, false); err != nil {
		t.Fatal(err)
	}
	service := changeset.New(manager)
	for _, otherBase := range []bool{false, true} {
		// Another orphan worktree may initialize main with unrelated history.
		if otherBase {
			testkit.RunGit(t, repository, "commit", "--allow-empty", "-m", "Other root")
			if _, err := manager.Refresh(context.Background(), chat.ID, false); err != nil {
				t.Fatal(err)
			}
		}
		set, err := service.GetTargetFresh(context.Background(), chat.ID, "")
		if err != nil {
			t.Fatal(err)
		}
		if len(set.Commits) != 2 || set.Commits[1].SHA != root || set.Commits[1].ParentSHA != "" || set.Commits[1].Additions != 1 {
			t.Fatalf("missing root history: %#v", set.Commits)
		}
		for _, path := range []string{"", "first.txt"} {
			diff, err := service.FileDiffTarget(context.Background(), chat.ID, "", path, root, "", "", 0, 0)
			if err != nil || !strings.Contains(diff.Patch, "+root line") || strings.Contains(diff.Patch, "+second line") {
				t.Fatalf("incorrect root patch: %#v %v", diff, err)
			}
		}
	}
}
