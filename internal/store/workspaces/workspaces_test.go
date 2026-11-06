package workspaces_test

import (
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestWorkspaceChangesetStatsPreserveNewerLifecycleState(t *testing.T) {
	t.Parallel()
	s, project, _ := testkit.BoardStore(t, model.WorkflowDirect)
	card, err := s.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "stats-card"})
	if err != nil {
		t.Fatal(err)
	}
	workspace, err := s.Workspaces.Save(model.Workspace{
		CardID: card.ID, ProjectID: project.ID, Mode: model.WorkspaceModeWorktree,
		Path: "/tmp/stats-worktree", State: model.WorkspaceStateCleanupPending,
		HeadSHA: "head", IntegratedHeadSHA: "head", IntegratedResultSHA: "result",
		IntegrationStrategy: "squash", IntegratedAt: "2026-08-29T20:00:00Z",
	})
	if err != nil {
		t.Fatal(err)
	}
	updated, err := s.Workspaces.UpdateChangesetStats(card.ID, 3, 12, 4)
	if err != nil {
		t.Fatal(err)
	}
	if updated.State != model.WorkspaceStateCleanupPending || updated.IntegratedHeadSHA != workspace.IntegratedHeadSHA || updated.IntegratedResultSHA != workspace.IntegratedResultSHA {
		t.Fatalf("changeset stats overwrote lifecycle state: %#v", updated)
	}
	if updated.ChangedFiles != 3 || updated.Additions != 12 || updated.Deletions != 4 {
		t.Fatalf("changeset stats were not updated: %#v", updated)
	}
}

func TestWorkspaceGitStatePreservesNewerLifecycleState(t *testing.T) {
	t.Parallel()
	s, project, _ := testkit.BoardStore(t, model.WorkflowDirect)
	card, err := s.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "refresh-card"})
	if err != nil {
		t.Fatal(err)
	}
	current, err := s.Workspaces.Save(model.Workspace{
		CardID: card.ID, ProjectID: project.ID, Mode: model.WorkspaceModeWorktree,
		Path: "/tmp/refresh-worktree", Branch: "topic", State: model.WorkspaceStateCleanupPending,
		HeadSHA: "old-head", CurrentOperationID: "gitop_active", IntegratedHeadSHA: "old-head",
		IntegratedResultSHA: "result", IntegrationStrategy: "squash", IntegratedAt: "2026-08-29T20:00:00Z",
	})
	if err != nil {
		t.Fatal(err)
	}
	observed := current
	observed.Branch = "observed-topic"
	observed.HeadSHA = "observed-head"
	observed.CurrentBaseSHA = "observed-base"
	observed.Dirty = true
	observed.Ahead = 2
	observed.Behind = 1
	observed.Revision = "observed-revision"
	updated, err := s.Workspaces.UpdateGitState(observed, false)
	if err != nil {
		t.Fatal(err)
	}
	if updated.State != model.WorkspaceStateCleanupPending || updated.CurrentOperationID != "gitop_active" || updated.IntegratedHeadSHA != "old-head" || updated.IntegratedResultSHA != "result" {
		t.Fatalf("Git refresh overwrote lifecycle state: %#v", updated)
	}
	if updated.Branch != observed.Branch || updated.HeadSHA != observed.HeadSHA || updated.CurrentBaseSHA != observed.CurrentBaseSHA || !updated.Dirty || updated.Ahead != 2 || updated.Behind != 1 || updated.Revision != observed.Revision {
		t.Fatalf("Git refresh fields were not updated: %#v", updated)
	}
}

func TestProjectCheckoutRuntimeLeaseIgnoresWorktreeConversations(t *testing.T) {
	t.Parallel()
	s, project, _ := testkit.BoardStore(t, model.WorkflowReview)
	worktreeCard, err := s.Kanban.CreateChat(kanban.CreateCardInput{
		Project: project.ID, Title: "Isolated", WorkspaceMode: model.WorkspaceModeWorktree,
	})
	if err != nil {
		t.Fatal(err)
	}
	projectCard, err := s.Kanban.CreateChat(kanban.CreateCardInput{
		Project: project.ID, Title: "Shared", WorkspaceMode: model.WorkspaceModeProject,
	})
	if err != nil {
		t.Fatal(err)
	}
	worktreeLease, err := s.Kanban.AcquireRuntimeLease(project.ID, worktreeCard.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.Leases.Release(worktreeLease) }()
	if active, err := s.Workspaces.ProjectCheckoutActive(project.ID, ""); err != nil || active {
		t.Fatalf("worktree turn blocked the registered checkout: active=%v err=%v", active, err)
	}
	projectLease, err := s.Kanban.AcquireRuntimeLease(project.ID, projectCard.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.Leases.Release(projectLease) }()
	if active, err := s.Workspaces.ProjectCheckoutActive(project.ID, ""); err != nil || !active {
		t.Fatalf("project-directory turn did not block the registered checkout: active=%v err=%v", active, err)
	}
	if active, err := s.Workspaces.ProjectCheckoutActive(project.ID, projectCard.ID); err != nil || active {
		t.Fatalf("excepted project-directory turn still blocked itself: active=%v err=%v", active, err)
	}
}
