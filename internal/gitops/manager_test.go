package gitops_test

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/gitops"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/scm"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/workspace"
)

func TestCommitFastForwardMergeAndCleanupEndToEnd(t *testing.T) {
	repository := testRepository(t)
	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Fixture", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Operation", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
	if err != nil {
		t.Fatal(err)
	}
	workspaces := workspace.New(data, nil)
	value, err := workspaces.Ensure(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(value.Path, "README.md"), []byte("merged content\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	manager := gitops.New(data, workspaces, nil)
	commit, err := manager.Start(context.Background(), gitops.Request{CardID: chat.ID, Kind: "commit", Parameters: map[string]string{"subject": "workspace change", "validate": "false"}})
	if err != nil {
		t.Fatal(err)
	}
	commit = waitOperation(t, manager, commit.ID)
	if commit.Status != model.GitOperationSucceeded || commit.Result == "" {
		t.Fatalf("commit failed: %#v", commit)
	}
	merge, err := manager.Start(context.Background(), gitops.Request{CardID: chat.ID, Kind: "merge_local", Parameters: map[string]string{"strategy": "squash", "subject": "squashed workspace", "validate": "false"}})
	if err != nil {
		t.Fatal(err)
	}
	merge = waitOperation(t, manager, merge.ID)
	if merge.Status != model.GitOperationSucceeded {
		t.Fatalf("merge failed: %#v", merge)
	}
	content, err := os.ReadFile(filepath.Join(repository, "README.md"))
	if err != nil || string(content) != "merged content\n" {
		t.Fatalf("base checkout was not updated: %q, %v", content, err)
	}
	cleanup, err := manager.Start(context.Background(), gitops.Request{CardID: chat.ID, Kind: "cleanup"})
	if err != nil {
		t.Fatal(err)
	}
	cleanup = waitOperation(t, manager, cleanup.ID)
	if cleanup.Status != model.GitOperationSucceeded {
		t.Fatalf("cleanup failed: %#v", cleanup)
	}
	if _, err := os.Stat(value.Path); !os.IsNotExist(err) {
		t.Fatalf("worktree still exists: %v", err)
	}
}

func TestRebaseConflictCanBeResolvedAndContinued(t *testing.T) {
	repository := testRepository(t)
	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Fixture", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Conflict", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
	if err != nil {
		t.Fatal(err)
	}
	workspaces := workspace.New(data, nil)
	value, err := workspaces.Ensure(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(value.Path, "README.md"), []byte("workspace version\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, value.Path, "add", "README.md")
	runGit(t, value.Path, "commit", "-m", "workspace version")
	if err := os.WriteFile(filepath.Join(repository, "README.md"), []byte("base version\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, repository, "add", "README.md")
	runGit(t, repository, "commit", "-m", "base version")

	manager := gitops.New(data, workspaces, nil)
	update, err := manager.Start(context.Background(), gitops.Request{CardID: chat.ID, Kind: "update", Parameters: map[string]string{"fetch": "false", "validate": "false"}})
	if err != nil {
		t.Fatal(err)
	}
	update = waitOperation(t, manager, update.ID)
	if update.Status != model.GitOperationWaitingForResolution || len(update.Conflicts) != 1 {
		t.Fatalf("expected conflict: %#v", update)
	}
	if err := os.WriteFile(filepath.Join(value.Path, "README.md"), []byte("resolved version\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(t, value.Path, "add", "README.md")
	continued, err := manager.Start(context.Background(), gitops.Request{CardID: chat.ID, Kind: "continue_conflict", Parameters: map[string]string{"validate": "false"}})
	if err != nil {
		t.Fatal(err)
	}
	continued = waitOperation(t, manager, continued.ID)
	if continued.Status != model.GitOperationSucceeded {
		t.Fatalf("continue failed: %#v", continued)
	}
	update, err = manager.Get(update.ID)
	if err != nil || update.Status != model.GitOperationSucceeded {
		t.Fatalf("original update was not completed: %#v %v", update, err)
	}
	workspaceValue, err := data.Workspace(chat.ID)
	if err != nil || workspaceValue.State != model.WorkspaceStateReady || workspaceValue.CurrentOperationID != "" {
		t.Fatalf("workspace did not recover: %#v %v", workspaceValue, err)
	}
}

func TestBranchWorkspaceMigratesToWorktree(t *testing.T) {
	repository := testRepository(t)
	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Fixture", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Migration", Prompt: "work", WorkspaceMode: model.WorkspaceModeBranch})
	if err != nil {
		t.Fatal(err)
	}
	workspaces := workspace.New(data, nil)
	before, err := workspaces.Ensure(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	if before.Mode != model.WorkspaceModeBranch || before.Branch == "main" {
		t.Fatalf("branch workspace not activated: %#v", before)
	}
	manager := gitops.New(data, workspaces, nil)
	operation, err := manager.Start(context.Background(), gitops.Request{CardID: chat.ID, Kind: "migrate", Parameters: map[string]string{"mode": "worktree"}})
	if err != nil {
		t.Fatal(err)
	}
	operation = waitOperation(t, manager, operation.ID)
	if operation.Status != model.GitOperationSucceeded {
		t.Fatalf("migration failed: %#v", operation)
	}
	after, err := data.Workspace(chat.ID)
	if err != nil || after.Mode != model.WorkspaceModeWorktree || after.Path == before.Path || after.Branch != before.Branch {
		t.Fatalf("unexpected migrated workspace: %#v %v", after, err)
	}
	if branch := runGit(t, repository, "branch", "--show-current"); branch != "main" {
		t.Fatalf("registered checkout remained on %q", branch)
	}
}

func TestWorkspaceCanBeAdoptedByAnotherConversation(t *testing.T) {
	repository := testRepository(t)
	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Fixture", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	source, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Source", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
	if err != nil {
		t.Fatal(err)
	}
	target, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Target", Prompt: "work"})
	if err != nil {
		t.Fatal(err)
	}
	workspaces := workspace.New(data, nil)
	before, err := workspaces.Ensure(context.Background(), source.ID)
	if err != nil {
		t.Fatal(err)
	}
	manager := gitops.New(data, workspaces, nil)
	operation, err := manager.Start(context.Background(), gitops.Request{
		CardID: source.ID, Kind: "adopt", Parameters: map[string]string{"target_card_id": target.ID},
	})
	if err != nil {
		t.Fatal(err)
	}
	operation = waitOperation(t, manager, operation.ID)
	if operation.Status != model.GitOperationSucceeded || operation.Result != target.ID {
		t.Fatalf("adoption failed: %#v", operation)
	}
	adopted, err := data.Workspace(target.ID)
	if err != nil || adopted.Path != before.Path || adopted.CardID != target.ID || len(adopted.PreviousCardIDs) != 1 || adopted.CurrentOperationID != "" {
		t.Fatalf("unexpected adopted workspace: %#v %v", adopted, err)
	}
	if _, err := workspaces.Ensure(context.Background(), source.ID); err == nil || !strings.Contains(err.Error(), "adopted") {
		t.Fatalf("source conversation silently recreated its workspace: %v", err)
	}
}

func TestPullRequestWorkflowPersistsAndMarksWorkspaceForCleanup(t *testing.T) {
	repository := testRepository(t)
	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Fixture", Path: repository, BaseBranch: "main", BaseRemote: "origin"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Pull request", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
	if err != nil {
		t.Fatal(err)
	}
	workspaces := workspace.New(data, nil)
	value, err := workspaces.Ensure(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	provider := &fakeSCMProvider{headSHA: value.HeadSHA}
	manager := gitops.New(data, workspaces, nil)
	manager.SCM = provider
	created, err := manager.Start(context.Background(), gitops.Request{
		CardID: chat.ID, Kind: "create_pr", Parameters: map[string]string{"title": "Ship it", "push": "false"},
	})
	if err != nil {
		t.Fatal(err)
	}
	created = waitOperation(t, manager, created.ID)
	if created.Status != model.GitOperationSucceeded || created.Result != "https://example.test/pull/17" {
		t.Fatalf("create PR failed: %#v", created)
	}
	persisted, err := data.PullRequest(chat.ID)
	if err != nil || persisted.Number != 17 || persisted.State != "open" {
		t.Fatalf("pull request was not persisted: %#v %v", persisted, err)
	}
	merged, err := manager.Start(context.Background(), gitops.Request{
		CardID: chat.ID, Kind: "merge_pr", Parameters: map[string]string{"strategy": "squash", "expected_head_sha": value.HeadSHA},
	})
	if err != nil {
		t.Fatal(err)
	}
	merged = waitOperation(t, manager, merged.ID)
	if merged.Status != model.GitOperationSucceeded || provider.mergedHead != value.HeadSHA {
		t.Fatalf("merge PR failed: %#v provider=%#v", merged, provider)
	}
	workspaceValue, err := data.Workspace(chat.ID)
	if err != nil || workspaceValue.State != model.WorkspaceStateCleanupPending || workspaceValue.IntegratedHeadSHA != value.HeadSHA {
		t.Fatalf("merged PR did not mark cleanup state: %#v %v", workspaceValue, err)
	}
}

func TestDiscardCreatesRecoveryArtifactsBeforeRemovingWorktree(t *testing.T) {
	repository := testRepository(t)
	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Fixture", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := data.CreateChat(store.CreateCardInput{Project: project.ID, Title: "Discard", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
	if err != nil {
		t.Fatal(err)
	}
	workspaces := workspace.New(data, nil)
	value, err := workspaces.Ensure(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(value.Path, "README.md"), []byte("uncommitted\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(value.Path, "untracked.txt"), []byte("recover me\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	manager := gitops.New(data, workspaces, nil)
	operation, err := manager.Start(context.Background(), gitops.Request{CardID: chat.ID, Kind: "discard"})
	if err != nil {
		t.Fatal(err)
	}
	operation = waitOperation(t, manager, operation.ID)
	if operation.Status != model.GitOperationSucceeded {
		t.Fatalf("discard failed: %#v", operation)
	}
	recovery := filepath.Join(data.RecoveryDir(), operation.ID)
	for _, name := range []string{"branch.bundle", "unstaged.patch", "staged.patch", "untracked.tar", "RESTORE.txt"} {
		if info, statErr := os.Stat(filepath.Join(recovery, name)); statErr != nil || !info.Mode().IsRegular() {
			t.Fatalf("missing recovery artifact %s: %v", name, statErr)
		}
	}
	if _, err := data.Workspace(chat.ID); err == nil {
		t.Fatal("discard left a workspace record")
	}
}

type fakeSCMProvider struct {
	headSHA    string
	mergedHead string
}

func (f *fakeSCMProvider) Capabilities(context.Context, string, string) model.SCMCapabilities {
	return model.SCMCapabilities{Provider: "fake", Authenticated: true}
}

func (f *fakeSCMProvider) CreatePullRequest(_ context.Context, _, _ string, _ scm.CreatePullRequestInput) (model.PullRequest, error) {
	return model.PullRequest{Provider: "fake", Number: 17, URL: "https://example.test/pull/17", State: "open", HeadSHA: f.headSHA, BaseSHA: "base"}, nil
}

func (f *fakeSCMProvider) PullRequest(context.Context, string, string, int) (model.PullRequest, error) {
	return model.PullRequest{Provider: "fake", Number: 17, URL: "https://example.test/pull/17", State: "open", HeadSHA: f.headSHA, BaseSHA: "base"}, nil
}

func (f *fakeSCMProvider) MergePullRequest(_ context.Context, _, _ string, _ int, _, expectedHeadSHA string) (model.PullRequest, error) {
	f.mergedHead = expectedHeadSHA
	return model.PullRequest{Provider: "fake", Number: 17, URL: "https://example.test/pull/17", State: "merged", HeadSHA: expectedHeadSHA, BaseSHA: "merged-base"}, nil
}

func waitOperation(t *testing.T, manager *gitops.Manager, id string) model.GitOperation {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		value, err := manager.Get(id)
		if err != nil {
			t.Fatal(err)
		}
		switch value.Status {
		case model.GitOperationQueued, model.GitOperationRunning:
			time.Sleep(10 * time.Millisecond)
		default:
			return value
		}
	}
	t.Fatal("timed out waiting for Git operation")
	return model.GitOperation{}
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
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %s: %v", args, output, err)
	}
	return strings.TrimSpace(string(output))
}
