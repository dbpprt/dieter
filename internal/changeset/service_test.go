package changeset_test

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/changeset"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/workspace"
)

func TestChangesetIncludesTrackedAndUntrackedDiffsAndRejectsStaleRevision(t *testing.T) {
	repository := testRepository(t)
	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Fixture", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Changes", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
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
	if len(set.Files) != 2 || set.Additions < 3 || set.Revision == "" {
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
	repository := testRepository(t)
	runGit(t, repository, "switch", "-c", "feature/direct")
	if err := os.WriteFile(filepath.Join(repository, "feature.txt"), []byte("feature\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, repository, "add", "feature.txt")
	runGit(t, repository, "commit", "-m", "feature commit")

	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Fixture", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Direct", Prompt: "work", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	manager := workspace.New(data, nil)
	value, err := manager.Ensure(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	set, err := changeset.New(manager).Get(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	canonicalRepository, err := filepath.EvalSymlinks(repository)
	if err != nil {
		t.Fatal(err)
	}
	if value.Path != canonicalRepository || value.Branch != "feature/direct" || len(set.Commits) != 1 || set.Commits[0].Subject != "feature commit" {
		t.Fatalf("unexpected direct feature-branch changeset: workspace=%#v changes=%#v", value, set)
	}
}

func testRepository(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "repository")
	runGit(t, "", "init", "-b", "main", root)
	runGit(t, root, "config", "user.name", "Dieter Test")
	runGit(t, root, "config", "user.email", "dieter@example.test")
	if err := os.WriteFile(filepath.Join(root, "README.md"), []byte("base\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, root, "add", "README.md")
	runGit(t, root, "commit", "-m", "base")
	return root
}

func runGit(t *testing.T, directory string, args ...string) {
	t.Helper()
	command := exec.Command("git", args...)
	command.Dir = directory
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %s: %v", args, output, err)
	}
}

func TestCommitDiffWithoutPathReturnsTheWholeCommitPatch(t *testing.T) {
	repository := testRepository(t)
	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Fixture", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Commits", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
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
	runGit(t, value.Path, "add", "-A")
	runGit(t, value.Path, "commit", "-m", "add both files")

	service := changeset.New(manager)
	set, err := service.Get(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(set.Commits) != 1 {
		t.Fatalf("expected one commit ahead, got %#v", set.Commits)
	}
	diff, err := service.CommitDiff(context.Background(), chat.ID, set.Revision, set.Commits[0].SHA, "", 0, 0)
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
