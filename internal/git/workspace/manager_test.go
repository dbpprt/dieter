package workspace_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/git/workspace"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestWorktreeWorkspaceUsesSameCardIdentityForBoardCardsAndChats(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	data := testkit.Store(t)
	project, err := data.CreateProject(store.CreateProjectInput{
		Name: "Fixture", Path: repository, BaseBranch: "main", BaseRemote: "origin",
	})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.CreateBoard(store.CreateBoardInput{
		Project: project.ID, Name: "Main", Workflow: model.WorkflowReview,
		BaseRemote: "private", RemotePublishMode: model.RemotePublishPullRequest,
	})
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
	if cardWorkspace.BaseRemote != "private" || cardWorkspace.RemotePublishMode != model.RemotePublishPullRequest {
		t.Fatalf("card workspace ignored board Git defaults: %#v", cardWorkspace)
	}
	if chatWorkspace.BaseRemote != "origin" || chatWorkspace.RemotePublishMode != model.RemotePublishManual {
		t.Fatalf("chat workspace did not use project/manual defaults: %#v", chatWorkspace)
	}
}

func TestProjectDirectoryWorkspaceUsesCurrentBranchWithoutSwitching(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	testkit.RunGit(t, repository, "switch", "-c", "feature/current-checkout")
	data := testkit.Store(t)
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
	if branch := testkit.RunGit(t, repository, "branch", "--show-current"); branch != "feature/current-checkout" {
		t.Fatalf("project directory branch was switched to %q", branch)
	}
	testkit.RunGit(t, repository, "checkout", "--detach")
	value, err = workspace.New(data, nil).Refresh(context.Background(), chat.ID, false)
	if err != nil {
		t.Fatal(err)
	}
	if value.Branch != "" {
		t.Fatalf("detached project directory reported stale branch %q", value.Branch)
	}
}
