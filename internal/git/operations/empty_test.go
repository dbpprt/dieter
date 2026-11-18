package operations_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/git/operations"
	"github.com/dbpprt/dieter/internal/git/workspace"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func emptyWorkspace(t *testing.T) (*operations.Manager, model.Project, model.Workspace) {
	t.Helper()
	repository := filepath.Join(t.TempDir(), "repository")
	testkit.InitGitRepo(t, repository)
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Empty", Path: repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	workspaces := workspace.New(data, nil)
	manager := operations.New(data, workspaces, nil)
	return manager, project, anotherEmptyWorkspace(t, manager, project.ID)
}

func anotherEmptyWorkspace(t *testing.T, manager *operations.Manager, projectID string) model.Workspace {
	t.Helper()
	chat, err := manager.Store.Kanban.CreateChat(kanban.CreateCardInput{Project: projectID, Title: "Initial", Prompt: "work", WorkspaceMode: model.WorkspaceModeWorktree})
	if err != nil {
		t.Fatal(err)
	}
	value, err := manager.Workspaces.Ensure(context.Background(), chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	return value
}

func emptyOperation(t *testing.T, manager *operations.Manager, value model.Workspace, kind string, parameters map[string]string) model.GitOperation {
	t.Helper()
	changes, err := manager.Changesets.GetTargetFresh(context.Background(), value.CardID, "")
	if err != nil {
		t.Fatal(err)
	}
	op, err := manager.Start(context.Background(), operations.Request{CardID: value.CardID, Kind: kind, ExpectedRevision: changes.Revision, ExpectedIndex: changes.IndexFingerprint, ExpectedFiles: expectFiles(changes, ""), Parameters: parameters})
	if err != nil {
		t.Fatal(err)
	}
	return waitOperation(t, manager, op.ID)
}

func requireEmptyOperation(t *testing.T, manager *operations.Manager, value model.Workspace, kind string, parameters map[string]string) model.GitOperation {
	t.Helper()
	op := emptyOperation(t, manager, value, kind, parameters)
	if op.Status != model.GitOperationSucceeded {
		t.Fatalf("%s failed: %s", kind, op.Error)
	}
	return op
}

func commitEmptyFile(t *testing.T, manager *operations.Manager, value model.Workspace, name string) model.GitOperation {
	t.Helper()
	if err := os.WriteFile(filepath.Join(value.Path, name), []byte(name+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Exercise the staged-index path as well as the initial root commit.
	requireEmptyOperation(t, manager, value, "stage", map[string]string{"path": name})
	return requireEmptyOperation(t, manager, value, "commit", map[string]string{"subject": "Add " + name, "validate": "false"})
}

func TestUnbornWorktreeCommitMergeAndCleanup(t *testing.T) {
	t.Parallel()
	for _, strategy := range []string{"fast_forward", "squash", "merge_commit"} {
		t.Run(strategy, func(t *testing.T) {
			manager, project, value := emptyWorkspace(t)
			commitEmptyFile(t, manager, value, "first.txt")
			last := commitEmptyFile(t, manager, value, "second.txt")
			validation := []model.ValidationCommand{{Name: "Exact candidate", Executable: "git", Arguments: []string{"rev-parse", "HEAD"}}}
			if _, err := manager.Store.Kanban.UpdateProjectWorkspaceSettings(project.ID, "", "main", validation); err != nil {
				t.Fatal(err)
			}
			merge := requireEmptyOperation(t, manager, value, "merge_local", map[string]string{"strategy": strategy, "subject": "Bootstrap main"})
			if len(merge.ValidationResults) != 1 || strings.TrimSpace(merge.ValidationResults[0].Output) != merge.Result {
				t.Fatalf("validated a different commit: %#v", merge.ValidationResults)
			}
			if got := testkit.RunGit(t, project.Path, "rev-parse", "main"); got != merge.Result {
				t.Fatalf("base %s != integrated %s", got, merge.Result)
			}
			if strategy == "squash" {
				if got := testkit.RunGit(t, project.Path, "rev-list", "--count", "main"); got != "1" {
					t.Fatalf("squash kept %s commits", got)
				}
				if got := testkit.RunGit(t, project.Path, "log", "-1", "--format=%s"); got != "Bootstrap main" {
					t.Fatalf("squash subject %q", got)
				}
			} else if merge.Result != last.Result {
				t.Fatal("initial integration changed workspace history")
			}
			for _, name := range []string{"first.txt", "second.txt"} {
				content, err := os.ReadFile(filepath.Join(project.Path, name))
				if err != nil || string(content) != name+"\n" {
					t.Fatalf("missing integrated content: %q %v", content, err)
				}
			}
			requireEmptyOperation(t, manager, value, "cleanup", nil)
			if _, err := os.Stat(value.Path); !os.IsNotExist(err) {
				t.Fatalf("worktree remains: %v", err)
			}
			if _, err := manager.Store.Workspaces.Get(value.CardID); !errors.Is(err, home.ErrNotFound) {
				t.Fatalf("workspace record remains: %v", err)
			}
			next := anotherEmptyWorkspace(t, manager, project.ID)
			if next.BaseSHA != merge.Result || next.HeadSHA != merge.Result {
				t.Fatalf("next worktree has wrong base: %#v", next)
			}
		})
	}
}

func TestUnbornWorktreesCreatedAroundFirstCommit(t *testing.T) {
	t.Parallel()
	manager, project, first := emptyWorkspace(t)
	before := anotherEmptyWorkspace(t, manager, project.ID)
	commitEmptyFile(t, manager, first, "first.txt")
	after := anotherEmptyWorkspace(t, manager, project.ID)
	commitEmptyFile(t, manager, before, "before.txt")
	commitEmptyFile(t, manager, after, "after.txt")
	for _, value := range []model.Workspace{first, before, after} {
		requireEmptyOperation(t, manager, value, "merge_local", map[string]string{"strategy": "squash", "validate": "false"})
		requireEmptyOperation(t, manager, value, "cleanup", nil)
	}
	for _, name := range []string{"first.txt", "before.txt", "after.txt"} {
		if _, err := os.Stat(filepath.Join(project.Path, name)); err != nil {
			t.Fatal(err)
		}
	}
}

func TestUnbornWorktreeCleanupAndDiscard(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"cleanup", "discard"} {
		t.Run(kind, func(t *testing.T) {
			manager, project, value := emptyWorkspace(t)
			if kind == "discard" {
				if err := os.WriteFile(filepath.Join(value.Path, "keep.txt"), []byte("recover me\n"), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			op := requireEmptyOperation(t, manager, value, kind, nil)
			if _, err := os.Stat(value.Path); !os.IsNotExist(err) {
				t.Fatalf("worktree remains: %v", err)
			}
			if _, err := manager.Store.Workspaces.Get(value.CardID); !errors.Is(err, home.ErrNotFound) {
				t.Fatalf("workspace record remains: %v", err)
			}
			if kind == "discard" {
				recovery := filepath.Join(manager.Store.RecoveryDir(), op.ID, "untracked.tar")
				if _, err := os.Stat(recovery); err != nil {
					t.Fatalf("missing recovery: %v", err)
				}
			}
			if refs := testkit.RunGit(t, project.Path, "for-each-ref"); refs != "" {
				t.Fatalf("created refs: %s", refs)
			}
		})
	}
}

func TestUnbornMergePreservesDirtyBase(t *testing.T) {
	t.Parallel()
	manager, project, value := emptyWorkspace(t)
	commitEmptyFile(t, manager, value, "first.txt")
	// Same path as the incoming commit: bootstrap must never overwrite it.
	userFile := filepath.Join(project.Path, "first.txt")
	if err := os.WriteFile(userFile, []byte("user data\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	op := emptyOperation(t, manager, value, "merge_local", map[string]string{"strategy": "squash", "validate": "false"})
	if op.Status != model.GitOperationFailed || !strings.Contains(op.Error, "must be clean") {
		t.Fatalf("unsafe bootstrap: %#v", op)
	}
	content, err := os.ReadFile(userFile)
	if err != nil || string(content) != "user data\n" {
		t.Fatalf("lost user file: %q %v", content, err)
	}
	if refs := testkit.RunGit(t, project.Path, "for-each-ref", "--format=%(refname)", "refs/heads/main"); refs != "" {
		t.Fatal("failed integration created main")
	}
	if _, err := os.Stat(value.Path); err != nil {
		t.Fatalf("lost workspace: %v", err)
	}
	if err := os.Remove(userFile); err != nil {
		t.Fatal(err)
	}
	requireEmptyOperation(t, manager, value, "merge_local", map[string]string{"strategy": "squash", "validate": "false"})
}

func TestUnbornMergePreservesIgnoredFiles(t *testing.T) {
	t.Parallel()
	manager, project, value := emptyWorkspace(t)
	commitEmptyFile(t, manager, value, "first.txt")
	exclude := filepath.Join(project.Path, ".git", "info", "exclude")
	if err := os.WriteFile(exclude, []byte("first.txt\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	userFile := filepath.Join(project.Path, "first.txt")
	if err := os.WriteFile(userFile, []byte("ignored user data\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	op := emptyOperation(t, manager, value, "merge_local", map[string]string{"strategy": "fast_forward", "validate": "false"})
	if op.Status != model.GitOperationFailed {
		t.Fatalf("overwrote ignored file: %#v", op)
	}
	content, err := os.ReadFile(userFile)
	if err != nil || string(content) != "ignored user data\n" {
		t.Fatalf("lost ignored file: %q %v", content, err)
	}
	if refs := testkit.RunGit(t, project.Path, "for-each-ref", "--format=%(refname)", "refs/heads/main"); refs != "" {
		t.Fatal("failed integration created main")
	}
}

func TestUnbornMergeValidationFailureIsRecoverable(t *testing.T) {
	t.Parallel()
	manager, project, value := emptyWorkspace(t)
	commitEmptyFile(t, manager, value, "first.txt")
	validation := []model.ValidationCommand{{Name: "Reject", Executable: "git", Arguments: []string{"rev-parse", "--verify", "refs/heads/missing"}}}
	if _, err := manager.Store.Kanban.UpdateProjectWorkspaceSettings(project.ID, "", "main", validation); err != nil {
		t.Fatal(err)
	}
	op := emptyOperation(t, manager, value, "merge_local", map[string]string{"strategy": "squash"})
	if op.Status != model.GitOperationFailed || len(op.ValidationResults) != 1 || op.ValidationResults[0].ExitCode == 0 {
		t.Fatalf("validation did not gate integration: %#v", op)
	}
	if refs := testkit.RunGit(t, project.Path, "for-each-ref", "--format=%(refname)", "refs/heads/main"); refs != "" {
		t.Fatal("failed validation created main")
	}
	if _, err := os.Stat(filepath.Join(value.Path, "first.txt")); err != nil {
		t.Fatalf("lost workspace content: %v", err)
	}
	integration := filepath.Join(manager.Store.RuntimeDir(), "integration")
	entries, err := os.ReadDir(integration)
	if err != nil || len(entries) != 0 {
		t.Fatalf("leaked integration checkout: %v %v", entries, err)
	}
	requireEmptyOperation(t, manager, value, "merge_local", map[string]string{"strategy": "squash", "validate": "false"})
}

func TestUnbornCommittedWorktreeRestoresBeforeBaseExists(t *testing.T) {
	t.Parallel()
	manager, project, value := emptyWorkspace(t)
	commit := commitEmptyFile(t, manager, value, "first.txt")
	enabled := true
	if _, err := manager.Store.Kanban.UpdateProjectWithHostnames(project.ID, nil, nil, nil, nil, nil, &enabled); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Workspaces.ArchiveCard(context.Background(), value.CardID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(value.Path); !os.IsNotExist(err) {
		t.Fatalf("archive retained worktree: %v", err)
	}
	if _, err := manager.Workspaces.ArchiveCard(context.Background(), value.CardID, false); err != nil {
		t.Fatal(err)
	}
	restored, err := manager.Workspaces.Ensure(context.Background(), value.CardID)
	if err != nil {
		t.Fatal(err)
	}
	if restored.HeadSHA != commit.Result || restored.BaseSHA != "" {
		t.Fatalf("restored wrong history: %#v", restored)
	}
	requireEmptyOperation(t, manager, restored, "merge_local", map[string]string{"strategy": "squash", "validate": "false"})
	requireEmptyOperation(t, manager, restored, "cleanup", nil)
}

func TestUnbornMergePreservesIgnoredSymlinkAncestor(t *testing.T) {
	t.Parallel()
	manager, project, value := emptyWorkspace(t)
	if err := os.MkdirAll(filepath.Join(value.Path, "nested"), 0o755); err != nil {
		t.Fatal(err)
	}
	commitEmptyFile(t, manager, value, "nested/file.txt")
	outside := t.TempDir()
	outsideFile := filepath.Join(outside, "file.txt")
	if err := os.WriteFile(outsideFile, []byte("outside user data\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(project.Path, ".git", "info", "exclude"), []byte("nested\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(project.Path, "nested")); err != nil {
		t.Fatal(err)
	}
	op := emptyOperation(t, manager, value, "merge_local", map[string]string{"strategy": "fast_forward", "validate": "false"})
	if op.Status != model.GitOperationFailed || !strings.Contains(op.Error, "would overwrite") {
		t.Fatalf("unsafe initial merge: %#v", op)
	}
	content, err := os.ReadFile(outsideFile)
	if err != nil || string(content) != "outside user data\n" {
		t.Fatalf("lost outside data: %q %v", content, err)
	}
}

func TestUnbornMergeRefusesBaseCreatedDuringValidation(t *testing.T) {
	t.Parallel()
	manager, project, value := emptyWorkspace(t)
	commit := commitEmptyFile(t, manager, value, "first.txt")
	validation := []model.ValidationCommand{{Name: "Concurrent base writer", Executable: "git", Arguments: []string{"-C", project.Path, "reset", "--hard", commit.Result}}}
	if _, err := manager.Store.Kanban.UpdateProjectWorkspaceSettings(project.ID, "", "main", validation); err != nil {
		t.Fatal(err)
	}
	op := emptyOperation(t, manager, value, "merge_local", map[string]string{"strategy": "squash"})
	if op.Status != model.GitOperationFailed || !strings.Contains(op.Error, "moved during merge") {
		t.Fatalf("ignored concurrent base change: %#v", op)
	}
	if got := testkit.RunGit(t, project.Path, "rev-parse", "main"); got != commit.Result {
		t.Fatalf("overwrote concurrent ref: %s", got)
	}
}

func TestUnbornMergePushBaseUsesIntegratedCommit(t *testing.T) {
	t.Parallel()
	manager, project, value := emptyWorkspace(t)
	remote := filepath.Join(t.TempDir(), "remote.git")
	testkit.RunGit(t, "", "init", "--bare", remote)
	testkit.RunGit(t, project.Path, "remote", "add", "origin", remote)
	value.BaseRemote, value.RemotePublishMode = "origin", model.RemotePublishPushBase
	if _, err := manager.Store.Workspaces.Save(value); err != nil {
		t.Fatal(err)
	}
	commitEmptyFile(t, manager, value, "first.txt")
	commitEmptyFile(t, manager, value, "second.txt")
	merge := requireEmptyOperation(t, manager, value, "merge_local", map[string]string{"strategy": "squash", "validate": "false"})
	if got := testkit.RunGit(t, remote, "rev-parse", "main"); got != merge.Result {
		t.Fatalf("pushed wrong initial commit: %s", got)
	}
	if count := testkit.RunGit(t, remote, "rev-list", "--count", "main"); count != "1" {
		t.Fatalf("pushed unsquashed history: %s", count)
	}
	requireEmptyOperation(t, manager, value, "cleanup", nil)
}
