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
