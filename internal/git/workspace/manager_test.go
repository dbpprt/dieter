package workspace_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/git/workspace"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestWorktreeWorkspaceUsesSameCardIdentityForBoardCardsAndChats(t *testing.T) {
	t.Parallel()
	repository := testkit.GitRepo(t)
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{
		Name: "Fixture", Path: repository, BaseBranch: "main", BaseRemote: "origin",
	})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{
		Project: project.ID, Name: "Main", Workflow: model.WorkflowReview,
		BaseRemote: "private", RemotePublishMode: model.RemotePublishPullRequest,
	})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Board work", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "Chat work", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
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
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{
		Name: "Fixture", Path: repository, BaseBranch: "main",
	})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.Kanban.CreateChat(kanban.CreateCardInput{
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

func TestEmptyRepositoryWorkspaces(t *testing.T) {
	t.Parallel()
	for _, mode := range []string{model.WorkspaceModeWorktree, model.WorkspaceModeProject} {
		t.Run(mode, func(t *testing.T) {
			repository := filepath.Join(t.TempDir(), "repository")
			testkit.RunGit(t, "", "init", "-b", "main", repository)
			data := testkit.Store(t)
			project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Empty", Path: repository, BaseBranch: "main"})
			if err != nil {
				t.Fatal(err)
			}
			manager := workspace.New(data, nil)
			for i := 0; i < 2; i++ {
				chat, err := data.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "Start", Prompt: "work", WorkspaceMode: mode})
				if err != nil {
					t.Fatal(err)
				}
				value, err := manager.Ensure(context.Background(), chat.ID)
				if err != nil {
					t.Fatal(err)
				}
				if value.State != model.WorkspaceStateReady || value.Mode != mode || value.HeadSHA != "" || value.BaseSHA != "" || value.CurrentBaseSHA != "" {
					t.Fatalf("unexpected unborn workspace: %#v", value)
				}
				if mode == model.WorkspaceModeWorktree && value.Path == repository {
					t.Fatal("worktree lost isolation")
				}
				value, err = manager.Ensure(context.Background(), chat.ID)
				if err != nil || value.BaseSHA != "" {
					t.Fatalf("retry: %#v, %v", value, err)
				}
			}
			if got := testkit.RunGit(t, repository, "branch", "--show-current"); got != "main" {
				t.Fatalf("changed checkout branch: %s", got)
			}
			if got := testkit.RunGit(t, repository, "for-each-ref"); got != "" {
				t.Fatalf("created refs or commits: %s", got)
			}
		})
	}
}

func TestWorktreeRejectsMissingBaseBranch(t *testing.T) {
	t.Parallel()
	for _, empty := range []bool{true, false} {
		t.Run(map[bool]string{true: "empty", false: "committed"}[empty], func(t *testing.T) {
			repository := ""
			if empty {
				repository = filepath.Join(t.TempDir(), "repository")
				testkit.RunGit(t, "", "init", "-b", "main", repository)
			} else {
				repository = testkit.GitRepo(t)
			}
			data := testkit.Store(t)
			project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Missing", Path: repository, BaseBranch: "typo"})
			if err != nil {
				t.Fatal(err)
			}
			chat, err := data.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "Start", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
			if err != nil {
				t.Fatal(err)
			}
			_, err = workspace.New(data, nil).Ensure(context.Background(), chat.ID)
			if err == nil || !strings.Contains(err.Error(), `resolve base branch "typo"`) {
				t.Fatalf("expected missing base error, got %v", err)
			}
		})
	}
}
