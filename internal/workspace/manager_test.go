package workspace_test

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/workspace"
)

func TestWorktreeWorkspaceUsesSameCardIdentityForBoardCardsAndChats(t *testing.T) {
	repository := testRepository(t)
	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.CreateProject(store.CreateProjectInput{
		Name: "Fixture", Path: repository, BaseBranch: "main",
	})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateCard(store.CreateCardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Board work", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Chat work", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
	if err != nil {
		t.Fatal(err)
	}
	manager := workspace.New(data, nil)
	cardWorkspace, err := manager.Ensure(context.Background(), card.ID)
	if err != nil {
		t.Fatal(err)
	}
	chatWorkspace, err := manager.Ensure(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	for id, value := range map[string]model.Workspace{card.ID: cardWorkspace, chat.ID: chatWorkspace} {
		if value.CardID != id || value.Mode != model.WorkspaceModeWorktree || value.State != model.WorkspaceStateReady {
			t.Fatalf("unexpected workspace for %s: %#v", id, value)
		}
		if !strings.HasPrefix(value.Path, data.WorktreeRoot()+string(filepath.Separator)) || value.Revision == "" || value.HeadSHA == "" {
			t.Fatalf("workspace was not fully provisioned: %#v", value)
		}
		if _, err := os.Stat(filepath.Join(value.Path, "README.md")); err != nil {
			t.Fatal(err)
		}
	}
	if cardWorkspace.Path == chatWorkspace.Path || cardWorkspace.Branch == chatWorkspace.Branch {
		t.Fatal("card and chat workspaces must be isolated")
	}
}

func TestProjectDirectoryWorkspaceUsesCurrentBranchWithoutSwitching(t *testing.T) {
	repository := testRepository(t)
	runGit(t, repository, "switch", "-c", "feature/current-checkout")
	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.CreateProject(store.CreateProjectInput{
		Name: "Fixture", Path: repository, BaseBranch: "main",
	})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.CreateChat(store.CreateCardInput{
		Project: project.ID, Title: "Direct work", Prompt: "work", WorkspaceMode: model.WorkspaceModeProject,
	})
	if err != nil {
		t.Fatal(err)
	}
	value, err := workspace.New(data, nil).Ensure(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	canonicalRepository, err := filepath.EvalSymlinks(repository)
	if err != nil {
		t.Fatal(err)
	}
	if value.Mode != model.WorkspaceModeProject || value.Path != canonicalRepository || value.Branch != "feature/current-checkout" || value.BaseBranch != "main" {
		t.Fatalf("unexpected project-directory workspace: %#v", value)
	}
	if branch := runGit(t, repository, "branch", "--show-current"); branch != "feature/current-checkout" {
		t.Fatalf("project directory branch was switched to %q", branch)
	}
	runGit(t, repository, "checkout", "--detach")
	value, err = workspace.New(data, nil).Refresh(context.Background(), chat.ID, false)
	if err != nil {
		t.Fatal(err)
	}
	if value.Branch != "" {
		t.Fatalf("detached project directory reported stale branch %q", value.Branch)
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

func runGit(t *testing.T, directory string, args ...string) string {
	t.Helper()
	command := exec.Command("git", args...)
	command.Dir = directory
	command.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0")
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %s: %v", args, output, err)
	}
	return strings.TrimSpace(string(output))
}
