package workspace_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/git/workspace"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func archiveFixture(t *testing.T, mode string) (*workspace.Manager, model.Card, model.Workspace, string) {
	t.Helper()
	repo := testkit.GitRepo(t)
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Archive", Path: repo, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	enabled := true
	if _, err := data.Kanban.UpdateProjectWithHostnames(project.ID, nil, nil, nil, nil, nil, &enabled); err != nil {
		t.Fatal(err)
	}
	card, err := data.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "Original name", Prompt: "work", WorkspaceMode: mode})
	if err != nil {
		t.Fatal(err)
	}
	m := workspace.New(data, nil)
	value, err := m.Ensure(context.Background(), card.ID)
	if err != nil {
		t.Fatal(err)
	}
	return m, card, value, repo
}

func TestArchiveReclaimsBuildProductsAndRestoresRetainedBranch(t *testing.T) {
	t.Parallel()
	m, card, value, repo := archiveFixture(t, model.WorkspaceModeWorktree)
	ctx := context.Background()
	if err := os.WriteFile(filepath.Join(value.Path, ".gitignore"), []byte("build/\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(value.Path, "README.md"), []byte("unmerged work\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	testkit.RunGit(t, value.Path, "add", ".")
	testkit.RunGit(t, value.Path, "commit", "-m", "unmerged work")
	head := testkit.RunGit(t, value.Path, "rev-parse", "HEAD")
	if err := os.MkdirAll(filepath.Join(value.Path, "build"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(value.Path, "build", "large-output"), make([]byte, 1<<20), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := m.Store.Conversations.AppendUIChunk(card.ID, "text", []byte(`{"type":"text-delta","id":"answer","delta":"retained history"}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Store.Kanban.RenameCard(card.ID, "Renamed later"); err != nil {
		t.Fatal(err)
	}
	archived, err := m.ArchiveCard(ctx, card.ID, true)
	if err != nil || !archived.Archived {
		t.Fatalf("archive: %+v %v", archived, err)
	}
	if _, err := os.Stat(value.Path); !os.IsNotExist(err) {
		t.Fatalf("worktree remains: %v", err)
	}
	if got := testkit.RunGit(t, repo, "rev-parse", value.Branch); got != head {
		t.Fatalf("branch moved: %s != %s", got, head)
	}
	if strings.Contains(testkit.RunGit(t, repo, "worktree", "list", "--porcelain"), card.ID) {
		t.Fatal("Git admin entry remains")
	}
	conversation, err := m.Store.Conversations.Get(card.ID)
	if err != nil || len(conversation.Messages) == 0 {
		t.Fatalf("history lost: %+v %v", conversation, err)
	}
	if _, err := m.Ensure(ctx, card.ID); err == nil {
		t.Fatal("archived worktree was recreated")
	}
	if _, err := m.Store.Kanban.AcquireRuntimeLease(card.ProjectID, card.ID); err == nil {
		t.Fatal("archived turn admitted")
	}
	// An in-flight presentation snapshot must not resurrect the removed tree.
	if _, err := m.Store.Workspaces.UpdateGitState(value, true); err != nil {
		t.Fatal(err)
	}
	retained, err := m.Refresh(ctx, card.ID, true)
	if err != nil || retained.State != model.WorkspaceStateReserved || retained.SizeBytes != 0 {
		t.Fatalf("retained workspace: %+v %v", retained, err)
	}
	if _, err := m.ArchiveCard(ctx, card.ID, false); err != nil {
		t.Fatal(err)
	}
	restored, err := m.Ensure(ctx, card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if restored.Branch != value.Branch || restored.HeadSHA != head {
		t.Fatalf("wrong restored workspace: %+v", restored)
	}
	if contents, err := os.ReadFile(filepath.Join(restored.Path, "README.md")); err != nil || string(contents) != "unmerged work\n" {
		t.Fatalf("work lost: %s %v", contents, err)
	}
	if _, err := os.Stat(filepath.Join(restored.Path, "build")); !os.IsNotExist(err) {
		t.Fatalf("build restored: %v", err)
	}
}

func TestArchiveRetainsUnsafeWorktreesAndRetries(t *testing.T) {
	t.Parallel()
	for _, reason := range []string{"tracked", "untracked", "staged", "busy", "lease", "git-operation", "locked", "detached", "branch-changed", "recovery"} {
		t.Run(reason, func(t *testing.T) {
			m, card, value, repo := archiveFixture(t, model.WorkspaceModeWorktree)
			ctx := context.Background()
			var undo func()
			switch reason {
			case "tracked", "staged":
				if err := os.WriteFile(filepath.Join(value.Path, "README.md"), []byte("keep me\n"), 0o644); err != nil {
					t.Fatal(err)
				}
				if reason == "staged" {
					testkit.RunGit(t, value.Path, "add", ".")
				}
				undo = func() { testkit.RunGit(t, value.Path, "reset", "--hard", "HEAD") }
			case "untracked":
				file := filepath.Join(value.Path, "keep.txt")
				if err := os.WriteFile(file, []byte("keep me"), 0o644); err != nil {
					t.Fatal(err)
				}
				undo = func() {
					if err := os.Remove(file); err != nil {
						t.Fatal(err)
					}
				}
			case "busy":
				m.Busy = func(string) bool { return true }
				undo = func() { m.Busy = nil }
			case "lease":
				lease, err := m.Store.Kanban.AcquireRuntimeLease(card.ProjectID, card.ID)
				if err != nil {
					t.Fatal(err)
				}
				undo = func() {
					if err := m.Store.Leases.Release(lease); err != nil {
						t.Fatal(err)
					}
				}
			case "git-operation":
				op, err := m.Store.Workspaces.CreateGitOperation(card.ID, "commit", "")
				if err != nil {
					t.Fatal(err)
				}
				value.CurrentOperationID = op.ID
				if _, err := m.Store.Workspaces.Save(value); err != nil {
					t.Fatal(err)
				}
				undo = func() {
					op.Status = model.GitOperationSucceeded
					if _, err := m.Store.Workspaces.SaveGitOperation(op); err != nil {
						t.Fatal(err)
					}
				}
			case "locked":
				testkit.RunGit(t, repo, "worktree", "lock", value.Path)
				undo = func() { testkit.RunGit(t, repo, "worktree", "unlock", value.Path) }
			case "detached":
				testkit.RunGit(t, value.Path, "checkout", "--detach")
				undo = func() { testkit.RunGit(t, value.Path, "checkout", value.Branch) }
			case "branch-changed":
				testkit.RunGit(t, value.Path, "switch", "-c", "unexpected-branch")
				undo = func() { testkit.RunGit(t, value.Path, "switch", value.Branch) }
			case "recovery":
				value.State = model.WorkspaceStateRecoveryRequired
				if _, err := m.Store.Workspaces.Save(value); err != nil {
					t.Fatal(err)
				}
				undo = func() {
					value.State = model.WorkspaceStateReady
					if _, err := m.Store.Workspaces.Save(value); err != nil {
						t.Fatal(err)
					}
				}
			}
			_, err := m.ArchiveCard(ctx, card.ID, true)
			if reason == "lease" {
				if err == nil {
					t.Fatal("archived active turn")
				}
				undo()
				undo = func() {}
				if _, err := m.Store.Kanban.ArchiveCard(card.ID, true); err != nil {
					t.Fatal(err)
				}
			} else if err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(value.Path); err != nil {
				t.Fatalf("unsafe worktree removed: %v", err)
			}
			undo()
			m.CleanupArchivedWorktrees(ctx)
			if _, err := os.Stat(value.Path); !os.IsNotExist(err) {
				t.Fatalf("retry did not reclaim tree: %v", err)
			}
		})
	}
}

func TestArchiveRestoreRefusesMissingRetainedBranch(t *testing.T) {
	t.Parallel()
	m, card, value, repo := archiveFixture(t, model.WorkspaceModeWorktree)
	if _, err := m.ArchiveCard(context.Background(), card.ID, true); err != nil {
		t.Fatal(err)
	}
	testkit.RunGit(t, repo, "branch", "-D", value.Branch)
	if _, err := m.ArchiveCard(context.Background(), card.ID, false); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Ensure(context.Background(), card.ID); err == nil {
		t.Fatal("missing branch silently replaced with base")
	}
}

func TestArchivePreservesSharedCheckout(t *testing.T) {
	t.Parallel()
	m, card, value, _ := archiveFixture(t, model.WorkspaceModeProject)
	if _, err := m.ArchiveCard(context.Background(), card.ID, true); err != nil {
		t.Fatal(err)
	}
	m.CleanupArchivedWorktrees(context.Background())
	if _, err := os.Stat(filepath.Join(value.Path, "README.md")); err != nil {
		t.Fatal(err)
	}
}

func TestArchiveCleanupCanBeDisabledAndReenabledForExistingArchives(t *testing.T) {
	t.Parallel()
	m, card, value, _ := archiveFixture(t, model.WorkspaceModeWorktree)
	enabled := false
	if _, err := m.Store.Kanban.UpdateProjectWithHostnames(card.ProjectID, nil, nil, nil, nil, nil, &enabled); err != nil {
		t.Fatal(err)
	}
	if _, err := m.ArchiveCard(context.Background(), card.ID, true); err != nil {
		t.Fatal(err)
	}
	m.CleanupArchivedWorktrees(context.Background())
	if _, err := os.Stat(value.Path); err != nil {
		t.Fatalf("disabled preference ignored: %v", err)
	}
	enabled = true
	if _, err := m.Store.Kanban.UpdateProjectWithHostnames(card.ProjectID, nil, nil, nil, nil, nil, &enabled); err != nil {
		t.Fatal(err)
	}
	m.CleanupArchivedWorktrees(context.Background())
	if _, err := os.Stat(value.Path); !os.IsNotExist(err) {
		t.Fatalf("enabled cleanup did not reclaim existing archive: %v", err)
	}
}

func TestArchiveCleanupRechecksPreferenceBeforeDeleting(t *testing.T) {
	t.Parallel()
	m, card, value, _ := archiveFixture(t, model.WorkspaceModeWorktree)
	if _, err := m.Store.Kanban.ArchiveCard(card.ID, true); err != nil {
		t.Fatal(err)
	}
	m.CleanupGuard = func() func() {
		enabled := false
		if _, err := m.Store.Kanban.UpdateProjectWithHostnames(card.ProjectID, nil, nil, nil, nil, nil, &enabled); err != nil {
			t.Fatal(err)
		}
		return func() {}
	}
	if err := m.CleanupArchived(context.Background(), card.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(value.Path); err != nil {
		t.Fatalf("preference was not rechecked: %v", err)
	}
}

func TestArchiveSweepReclaimsWorktreeWhenProjectIsArchived(t *testing.T) {
	t.Parallel()
	m, card, value, repo := archiveFixture(t, model.WorkspaceModeWorktree)
	if _, err := m.Store.Kanban.ArchiveCard(card.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Store.Kanban.ArchiveProject(card.ProjectID, true); err != nil {
		t.Fatal(err)
	}
	m.CleanupArchivedWorktrees(context.Background())
	if _, err := os.Stat(value.Path); !os.IsNotExist(err) {
		t.Fatalf("archived project retained worktree: %v", err)
	}
	if _, err := os.Stat(filepath.Join(repo, "README.md")); err != nil {
		t.Fatalf("project checkout removed: %v", err)
	}
	if got := testkit.RunGit(t, repo, "rev-parse", value.Branch); got != value.HeadSHA {
		t.Fatalf("branch changed: %s", got)
	}
	if _, err := m.Store.Kanban.ArchiveProject(card.ProjectID, false); err != nil {
		t.Fatal(err)
	}
	if _, err := m.ArchiveCard(context.Background(), card.ID, false); err != nil {
		t.Fatal(err)
	}
	if _, err := m.Ensure(context.Background(), card.ID); err != nil {
		t.Fatal(err)
	}
}

func TestArchiveSweepHandlesOlderArchivesAndMissingDirectories(t *testing.T) {
	t.Parallel()
	for _, missing := range []bool{false, true} {
		t.Run(fmtBool(missing), func(t *testing.T) {
			m, card, value, repo := archiveFixture(t, model.WorkspaceModeWorktree)
			if _, err := m.Store.Kanban.ArchiveCard(card.ID, true); err != nil {
				t.Fatal(err)
			}
			if missing {
				if err := os.RemoveAll(value.Path); err != nil {
					t.Fatal(err)
				}
			}
			m.CleanupArchivedWorktrees(context.Background())
			if _, err := os.Stat(value.Path); !os.IsNotExist(err) {
				t.Fatalf("old tree remains: %v", err)
			}
			if strings.Contains(testkit.RunGit(t, repo, "worktree", "list", "--porcelain"), card.ID) {
				t.Fatal("Git registration remains")
			}
			if _, err := m.ArchiveCard(context.Background(), card.ID, false); err != nil {
				t.Fatal(err)
			}
			if _, err := m.Ensure(context.Background(), card.ID); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func fmtBool(value bool) string {
	if value {
		return "missing"
	}
	return "existing"
}

func TestArchiveRetainsRegisteredOrUnmanagedDirectories(t *testing.T) {
	t.Parallel()
	for _, kind := range []string{"registered", "outside", "symlink"} {
		t.Run(kind, func(t *testing.T) {
			m, card, value, repo := archiveFixture(t, model.WorkspaceModeWorktree)
			switch kind {
			case "registered":
				if _, err := m.Store.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Registered worktree", Path: value.Path}); err != nil {
					t.Fatal(err)
				}
			case "outside":
				value.Path = repo
				if _, err := m.Store.Workspaces.Save(value); err != nil {
					t.Fatal(err)
				}
			case "symlink":
				moved := value.Path + "-moved"
				if err := os.Rename(value.Path, moved); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(moved, value.Path); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := m.ArchiveCard(context.Background(), card.ID, true); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(filepath.Join(value.Path, "README.md")); err != nil {
				t.Fatalf("protected directory removed: %v", err)
			}
		})
	}
}

func TestArchiveRestorePreservesWorkspaceAdoption(t *testing.T) {
	t.Parallel()
	m, source, value, _ := archiveFixture(t, model.WorkspaceModeWorktree)
	target, err := m.Store.Kanban.CreateChat(kanban.CreateCardInput{Project: source.ProjectID, Title: "Adopted", WorkspaceMode: model.WorkspaceModeWorktree})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.Store.Workspaces.Transfer(source.ID, target.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := m.ArchiveCard(context.Background(), source.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(value.Path); err != nil {
		t.Fatalf("source archive removed adopted tree: %v", err)
	}
	if _, err := m.ArchiveCard(context.Background(), target.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(value.Path); !os.IsNotExist(err) {
		t.Fatalf("target archive retained tree: %v", err)
	}
	if _, err := m.ArchiveCard(context.Background(), source.ID, false); err != nil {
		t.Fatal(err)
	}
	if _, err := m.ArchiveCard(context.Background(), target.ID, false); err != nil {
		t.Fatal(err)
	}
	restored, err := m.Ensure(context.Background(), target.ID)
	if err != nil {
		t.Fatal(err)
	}
	if restored.Path != value.Path || restored.Branch != value.Branch {
		t.Fatalf("adopted workspace changed: %+v", restored)
	}
	if _, err := m.Ensure(context.Background(), source.ID); err == nil {
		t.Fatal("source reclaimed adopted workspace")
	}
}

func TestAutomaticArchiveReclaimsDoneWorktree(t *testing.T) {
	m, chat, _, _ := archiveFixture(t, model.WorkspaceModeProject)
	board, err := m.Store.Kanban.CreateBoard(kanban.CreateBoardInput{Project: chat.ProjectID, Name: "Done", Workflow: model.WorkflowReview, DoneArchivePolicy: model.DoneArchiveImmediately})
	if err != nil {
		t.Fatal(err)
	}
	card, err := m.Store.Kanban.CreateCard(kanban.CreateCardInput{Project: chat.ProjectID, Board: board.ID, Title: "Done work", WorkspaceMode: model.WorkspaceModeWorktree})
	if err != nil {
		t.Fatal(err)
	}
	value, err := m.Ensure(context.Background(), card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := m.Store.Kanban.MoveCard(card.ID, model.LaneDone, nil); err != nil {
		t.Fatal(err)
	}
	archived, err := m.Store.Kanban.ArchiveDoneCards(time.Now().Add(time.Second))
	if err != nil || len(archived) != 1 {
		t.Fatalf("auto archive: %+v %v", archived, err)
	}
	m.CleanupArchivedWorktrees(context.Background())
	if _, err := os.Stat(value.Path); !os.IsNotExist(err) {
		t.Fatalf("done tree remains: %v", err)
	}
}
