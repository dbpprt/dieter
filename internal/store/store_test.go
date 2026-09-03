package store

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
)

func gitProject(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(path, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestDefaultRootUsesDieterHome(t *testing.T) {
	want := filepath.Join(t.TempDir(), "state")
	t.Setenv("DIETER_HOME", want)
	if got := DefaultRoot(); got != want {
		t.Fatalf("DefaultRoot() = %q, want %q", got, want)
	}
}

func TestDefaultRootUsesHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("DIETER_HOME", "")
	if got, want := DefaultRoot(), filepath.Join(home, ".dieter"); got != want {
		t.Fatalf("DefaultRoot() = %q, want %q", got, want)
	}
}

func TestCreateProjectAcceptsLinkedGitWorktree(t *testing.T) {
	worktree := filepath.Join(t.TempDir(), "linked-worktree")
	if err := os.MkdirAll(worktree, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(worktree, ".git"), []byte("gitdir: ../repo/.git/worktrees/linked-worktree\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	data := New(t.TempDir())
	project, err := data.CreateProject(CreateProjectInput{Path: worktree})
	if err != nil {
		t.Fatal(err)
	}
	canonicalWorktree, err := filepath.EvalSymlinks(worktree)
	if err != nil {
		t.Fatal(err)
	}
	if project.Path != canonicalWorktree || project.Name != "linked-worktree" {
		t.Fatalf("linked worktree project=%#v", project)
	}
}

func TestLegacyWorkspaceModesCanonicalizeToProjectDirectory(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowDirect)
	for _, legacy := range []string{"main", "branch"} {
		chat, err := s.CreateChat(CreateCardInput{
			Project: project.ID, Title: "Legacy " + legacy, Prompt: "work",
			WorkspaceMode: legacy, WorkspaceBranch: "stale", WorkspaceBaseBranch: "stale-base",
		})
		if err != nil {
			t.Fatal(err)
		}
		if chat.WorkspaceMode != model.WorkspaceModeProject || chat.WorkspaceBranch != "" || chat.WorkspaceBaseBranch != "" {
			t.Fatalf("legacy mode %q was not canonicalized: %#v", legacy, chat)
		}
	}
}

func TestWorkspaceChangesetStatsPreserveNewerLifecycleState(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowDirect)
	card, err := s.CreateChat(CreateCardInput{Project: project.ID, Title: "stats-card"})
	if err != nil {
		t.Fatal(err)
	}
	workspace, err := s.SaveWorkspace(model.Workspace{
		CardID: card.ID, ProjectID: project.ID, Mode: model.WorkspaceModeWorktree,
		Path: "/tmp/stats-worktree", State: model.WorkspaceStateCleanupPending,
		HeadSHA: "head", IntegratedHeadSHA: "head", IntegratedResultSHA: "result",
		IntegrationStrategy: "squash", IntegratedAt: "2026-08-29T20:00:00Z",
	})
	if err != nil {
		t.Fatal(err)
	}
	updated, err := s.UpdateWorkspaceChangesetStats(card.ID, 3, 12, 4)
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
	s, project, _ := setup(t, model.WorkflowDirect)
	card, err := s.CreateChat(CreateCardInput{Project: project.ID, Title: "refresh-card"})
	if err != nil {
		t.Fatal(err)
	}
	current, err := s.SaveWorkspace(model.Workspace{
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
	updated, err := s.UpdateWorkspaceGitState(observed, false)
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

func TestUpdateProjectRelocatesCanonicalWorkingTree(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowDirect)
	relocated := gitProject(t)
	updated, err := s.UpdateProject(project.ID, nil, nil, nil, &relocated)
	if err != nil {
		t.Fatal(err)
	}
	wantPath, err := filepath.EvalSymlinks(relocated)
	if err != nil {
		t.Fatal(err)
	}
	if updated.ID != project.ID || updated.Path != wantPath {
		t.Fatalf("relocated project = %#v", updated)
	}

	other, err := s.CreateProject(CreateProjectInput{Path: gitProject(t), Name: "Other"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpdateProject(project.ID, nil, nil, nil, &other.Path); err == nil {
		t.Fatal("expected duplicate project path to be rejected")
	}
}

func TestDraftAttachmentEventsReplayBeyondLegacyScannerLimit(t *testing.T) {
	s, project, board := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, Title: "Large attachment", Prompt: "Inspect it"})
	if err != nil {
		t.Fatal(err)
	}
	part := model.UIMessagePart{
		Type: "file", MediaType: "application/octet-stream", Filename: "fixture.bin",
		URL: "data:application/octet-stream;base64," + strings.Repeat("A", 5<<20),
	}
	if _, err := s.SetConversationDraftAttachments(card.ID, []model.UIMessagePart{part}); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(s.conversationPath(card.ID), "snapshot.json")); err != nil {
		t.Fatal(err)
	}
	replayed, err := s.Conversation(card.ID)
	if err != nil || len(replayed.DraftAttachments) != 1 || replayed.DraftAttachments[0].Filename != "fixture.bin" {
		t.Fatalf("replayed draft=%#v err=%v", replayed.DraftAttachments, err)
	}
}

func setup(t *testing.T, workflow string) (*Store, model.Project, model.Board) {
	t.Helper()
	s := New(t.TempDir())
	if err := s.Ensure(); err != nil {
		t.Fatal(err)
	}
	p, err := s.CreateProject(CreateProjectInput{ID: "kp_atlas", Name: "Atlas", Path: gitProject(t), Prompt: "Ship carefully."})
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.CreateBoard(CreateBoardInput{Project: p.ID, Name: "Delivery", Workflow: workflow})
	if err != nil {
		t.Fatal(err)
	}
	return s, p, b
}

func TestConversationCardLifecycle(t *testing.T) {
	s, p, b := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, ID: "card_1", Title: "Recover sessions", Prompt: "Implement it."})
	if err != nil || card.ID != "card_1" || card.Lane != model.LaneTodo {
		t.Fatalf("create: %#v %v", card, err)
	}
	if _, err = s.MarkPromptSent(card.ID); err != nil {
		t.Fatal(err)
	}
	card, err = s.MoveCard(card.ID, model.LaneReview, nil)
	if err != nil || card.Lane != model.LaneReview {
		t.Fatalf("review: %#v %v", card, err)
	}
	comment, err := s.AddComment(card.ID, "Ready for review.", model.Author{Kind: "agent", Provider: "codex", Model: "gpt-5.5"})
	if err != nil || comment.Author.CardID != card.ID {
		t.Fatalf("comment: %#v %v", comment, err)
	}
	detail, err := s.CardDetail(card.ID)
	if err != nil || len(detail.Comments) != 1 || detail.Card.InitialPrompt != "Implement it." {
		t.Fatalf("detail: %#v %v", detail, err)
	}
	if _, err := os.Stat(filepath.Join(p.Path, ".dieter")); !os.IsNotExist(err) {
		t.Fatalf("project repository was modified: %v", err)
	}
}

func TestConversationEventDoesNotOverwriteConcurrentLaneMove(t *testing.T) {
	s, project, board := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{
		Project: project.ID, Board: board.ID, ID: "card_lane_race", Lane: model.LaneRunning,
		Title: "Preserve review lane", Prompt: "Implement it.",
	})
	if err != nil {
		t.Fatal(err)
	}

	// Simulate another Dieter process holding the central storage lock. The
	// conversation writer must acquire that lock before reading the card whose
	// activity timestamp it will update.
	lockPath := filepath.Join(s.Root, ".write-lock")
	if err := os.Mkdir(lockPath, 0o700); err != nil {
		t.Fatal(err)
	}
	lockHeld := true
	t.Cleanup(func() {
		if lockHeld {
			_ = os.Remove(lockPath)
		}
	})

	appended := make(chan error, 1)
	go func() {
		_, _, appendErr := s.AppendUIChunk(card.ID, "turn_1", json.RawMessage(`{"type":"text","text":"Ready"}`))
		appended <- appendErr
	}()

	deadline := time.Now().Add(2 * time.Second)
	for writeMu.TryLock() {
		writeMu.Unlock()
		if time.Now().After(deadline) {
			t.Fatal("conversation writer did not wait on the storage lock")
		}
		time.Sleep(time.Millisecond)
	}

	// This direct write represents the mutation completed by the process that
	// owns lockPath. Releasing the lock lets the event writer continue.
	card.Lane = model.LaneReview
	card.PhaseChangedAt = "2026-08-24T07:34:45Z"
	card.UpdatedAt = card.PhaseChangedAt
	if err := s.writeCard(card); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(lockPath); err != nil {
		t.Fatal(err)
	}
	lockHeld = false

	select {
	case err := <-appended:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("conversation event did not finish")
	}
	stored, err := s.ResolveCard(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.Lane != model.LaneReview || stored.PhaseChangedAt != card.PhaseChangedAt {
		t.Fatalf("conversation event restored stale lane metadata: %#v", stored)
	}
}

func TestRenameBoardPersistsNameWithoutChangingIdentity(t *testing.T) {
	s, _, board := setup(t, model.WorkflowReview)
	updated, err := s.RenameBoard(board.ID, "  Platform delivery  ")
	if err != nil {
		t.Fatal(err)
	}
	if updated.ID != board.ID || updated.Name != "Platform delivery" || updated.UpdatedAt == board.UpdatedAt {
		t.Fatalf("renamed board=%#v original=%#v", updated, board)
	}
	stored, err := s.ResolveBoard("", board.ID)
	if err != nil || stored.Name != "Platform delivery" {
		t.Fatalf("stored board=%#v err=%v", stored, err)
	}
	if _, err := s.RenameBoard(board.ID, "   "); err == nil || err.Error() != "board name is required" {
		t.Fatalf("empty name error=%v", err)
	}
}

func TestUpdateCardEditsOnlyAnUnsentTask(t *testing.T) {
	s, project, board := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{
		Project: project.ID, Board: board.ID, ID: "card_edit", Title: "Original", Prompt: "Original task",
	})
	if err != nil {
		t.Fatal(err)
	}

	updated, err := s.UpdateCard(card.ID, " Edited title ", " Edited task ")
	if err != nil || updated.Title != "Edited title" || updated.InitialPrompt != "Edited task" {
		t.Fatalf("updated=%#v err=%v", updated, err)
	}
	if _, err := s.MarkPromptSent(card.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpdateCard(card.ID, "Another title", "Different task"); err == nil || err.Error() != "agent task can only be edited before it is sent" {
		t.Fatalf("late task edit error=%v", err)
	}
	stored, err := s.ResolveCard(card.ID)
	if err != nil || stored.Title != "Edited title" || stored.InitialPrompt != "Edited task" {
		t.Fatalf("stored=%#v err=%v", stored, err)
	}
	updated, err = s.UpdateCard(card.ID, "Title after send", stored.InitialPrompt)
	if err != nil || updated.Title != "Title after send" || updated.InitialPrompt != "Edited task" {
		t.Fatalf("title-only update=%#v err=%v", updated, err)
	}
}

func TestInterruptConversationReconcilesOrphanedRuntime(t *testing.T) {
	s, project, board := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, ID: "card_orphan", Title: "Recover me", Prompt: "Work"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.StartConversationTurn(card.ID, "turn_orphan", "user_orphan", "Start working"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpdateCardCache(card.ID, CardCacheInput{Runtime: "running"}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.AppendCapability(card.ID, "turn_orphan", json.RawMessage(`{"id":"subagents","operation":"upsert","subagent":{"id":"child","provider":"codex","messageId":"assistant","status":"running"}}`)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.AppendCapability(card.ID, "turn_orphan", json.RawMessage(`{"id":"task-plan","operation":"replace","plan":{"id":"plan","provider":"codex","messageId":"assistant","state":"active","phases":[{"tasks":[{"content":"Inspect","status":"in_progress"}]}]}}`)); err != nil {
		t.Fatal(err)
	}

	orphans, err := s.OrphanedTurnCards()
	if err != nil || len(orphans) != 1 || orphans[0].ID != card.ID {
		t.Fatalf("orphans=%#v err=%v", orphans, err)
	}
	interrupted, err := s.InterruptConversation(card.ID)
	if err != nil || !interrupted {
		t.Fatalf("interrupted=%v err=%v", interrupted, err)
	}
	conversation, err := s.Conversation(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	stored, err := s.ResolveCard(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if conversation.Status != "interrupted" || stored.Runtime != "idle" {
		t.Fatalf("conversation status=%q card runtime=%q", conversation.Status, stored.Runtime)
	}
	if len(conversation.Subagents) != 1 || conversation.Subagents[0].Status != "aborted" {
		t.Fatalf("subagents=%#v", conversation.Subagents)
	}
	if len(conversation.TaskPlans) != 1 || conversation.TaskPlans[0].State != "interrupted" || conversation.TaskPlans[0].Phases[0].Tasks[0].Status != "abandoned" {
		t.Fatalf("task plans=%#v", conversation.TaskPlans)
	}
	if again, err := s.InterruptConversation(card.ID); err != nil || again {
		t.Fatalf("second interrupt=%v err=%v", again, err)
	}
	if orphans, err := s.OrphanedTurnCards(); err != nil || len(orphans) != 0 {
		t.Fatalf("remaining orphans=%#v err=%v", orphans, err)
	}
}

func TestOrphanedTurnCardsDoesNotPublishSyncMutation(t *testing.T) {
	s := New(t.TempDir())
	if err := s.Ensure(); err != nil {
		t.Fatal(err)
	}
	before, events, err := s.SyncEvents(0, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 0 {
		t.Fatalf("fresh store events=%#v", events)
	}
	if orphans, err := s.OrphanedTurnCards(); err != nil || len(orphans) != 0 {
		t.Fatalf("orphans=%#v err=%v", orphans, err)
	}
	after, events, err := s.SyncEvents(before.Sequence, 10)
	if err != nil {
		t.Fatal(err)
	}
	if after != before || len(events) != 0 {
		t.Fatalf("read-only orphan inspection advanced sync from %#v to %#v with events=%#v", before, after, events)
	}
}

func TestInterruptConversationPreservesFailedRuntime(t *testing.T) {
	s, project, board := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, ID: "card_failed_orphan", Title: "Failed orphan", Prompt: "Work"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.StartConversationTurn(card.ID, "turn_failed", "user_failed", "Start working"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.AppendUIChunk(card.ID, "turn_failed", json.RawMessage(`{"type":"error","errorText":"disk write failed"}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpdateCardCache(card.ID, CardCacheInput{Runtime: "running"}); err != nil {
		t.Fatal(err)
	}
	if reconciled, err := s.InterruptConversation(card.ID); err != nil || !reconciled {
		t.Fatalf("reconciled=%v err=%v", reconciled, err)
	}
	stored, err := s.ResolveCard(card.ID)
	if err != nil || stored.Runtime != "failed" {
		t.Fatalf("card=%#v err=%v", stored, err)
	}
}

func TestProjectRemovalHidesResourcesAndCanBeRestored(t *testing.T) {
	s, project, board := setup(t, model.WorkflowReview)
	marker := filepath.Join(project.Path, "keep-me.txt")
	if err := os.WriteFile(marker, []byte("untouched"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, ID: "card_board", Title: "Board work"}); err != nil {
		t.Fatal(err)
	}
	chat, err := s.CreateChat(CreateCardInput{Project: project.ID, ID: "chat_standalone", Title: "Standalone"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateSchedule(ScheduleInput{
		Project: project.ID, Board: board.ID, Name: "Daily", Cron: "0 9 * * *", Timezone: "UTC",
		TitleTemplate: "Daily", PromptTemplate: "Run daily", Provider: "codex", Model: "gpt-5.5",
	}); err != nil {
		t.Fatal(err)
	}

	removed, err := s.ArchiveProject(project.ID, true)
	if err != nil || !removed.Archived {
		t.Fatalf("remove: %#v %v", removed, err)
	}
	if projects, _ := s.ListProjects(); len(projects) != 0 {
		t.Fatalf("active projects=%#v", projects)
	}
	archived, err := s.ListArchivedProjects()
	if err != nil || len(archived) != 1 || archived[0].BoardCount != 1 || archived[0].CardCount != 1 || archived[0].ChatCount != 1 {
		t.Fatalf("removed projects=%#v err=%v", archived, err)
	}
	if _, err := s.ResolveProject(project.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("removed project resolved: %v", err)
	}
	if boards, _ := s.ListBoards(""); len(boards) != 0 {
		t.Fatalf("removed boards leaked: %#v", boards)
	}
	if cards, _ := s.ListCards(CardFilter{}); len(cards) != 0 {
		t.Fatalf("removed cards leaked: %#v", cards)
	}
	if schedules, _ := s.ListSchedules(""); len(schedules) != 0 {
		t.Fatalf("removed schedules leaked: %#v", schedules)
	}
	if _, err := s.CardDetail(chat.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("removed chat detail resolved: %v", err)
	}
	if raw, err := os.ReadFile(marker); err != nil || string(raw) != "untouched" {
		t.Fatalf("working tree changed: %q %v", raw, err)
	}

	restored, err := s.ArchiveProject(project.ID, false)
	if err != nil || restored.Archived {
		t.Fatalf("restore: %#v %v", restored, err)
	}
	if projects, _ := s.ListProjects(); len(projects) != 1 {
		t.Fatalf("restored projects=%#v", projects)
	}
	if cards, _ := s.ListCards(CardFilter{}); len(cards) != 2 {
		t.Fatalf("restored cards=%#v", cards)
	}
	if schedules, _ := s.ListSchedules(""); len(schedules) != 1 {
		t.Fatalf("restored schedules=%#v", schedules)
	}
}

func TestProjectRemovalRejectsActiveAgentTurn(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowReview)
	lease, err := s.AcquireRuntimeLease(project.ID, "card_running")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.ReleaseRuntimeLease(lease) }()
	if _, err := s.ArchiveProject(project.ID, true); !errors.Is(err, ErrCardActive) {
		t.Fatalf("remove active project: %v", err)
	}
	if _, err := s.ResolveProject(project.ID); err != nil {
		t.Fatalf("active project was hidden after rejection: %v", err)
	}
}

func TestDoneArchivePolicyHidesAndRestoresCompletedCards(t *testing.T) {
	s, project, board := setup(t, model.WorkflowReview)
	now := time.Now().UTC()

	oldCard, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, ID: "card_old_done", Title: "Old completion"})
	if err != nil {
		t.Fatal(err)
	}
	oldCard, err = s.MoveCard(oldCard.ID, model.LaneDone, nil)
	if err != nil {
		t.Fatal(err)
	}
	oldCard.PhaseChangedAt = now.Add(-8 * 24 * time.Hour).Format(time.RFC3339Nano)
	if err := s.writeCard(oldCard); err != nil {
		t.Fatal(err)
	}

	youngCard, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, ID: "card_young_done", Title: "Recent completion"})
	if err != nil {
		t.Fatal(err)
	}
	if youngCard, err = s.MoveCard(youngCard.ID, model.LaneDone, nil); err != nil {
		t.Fatal(err)
	}

	activeCard, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, ID: "card_active_done", Title: "Active completion"})
	if err != nil {
		t.Fatal(err)
	}
	activeCard, err = s.MoveCard(activeCard.ID, model.LaneDone, nil)
	if err != nil {
		t.Fatal(err)
	}
	activeCard.PhaseChangedAt = now.Add(-8 * 24 * time.Hour).Format(time.RFC3339Nano)
	if err := s.writeCard(activeCard); err != nil {
		t.Fatal(err)
	}

	if archived, err := s.ArchiveDoneCards(now); err != nil || len(archived) != 0 {
		t.Fatalf("default policy archived cards: %#v err=%v", archived, err)
	}
	updated, err := s.UpdateBoardDoneArchivePolicy(board.ID, model.DoneArchiveAfter7Days)
	if err != nil || updated.DoneArchivePolicy != model.DoneArchiveAfter7Days {
		t.Fatalf("update policy: %#v err=%v", updated, err)
	}
	lease, err := s.AcquireRuntimeLease(project.ID, activeCard.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.ReleaseRuntimeLease(lease) }()

	archived, err := s.ArchiveDoneCards(now)
	if err != nil || len(archived) != 1 || archived[0].ID != oldCard.ID {
		t.Fatalf("timed archive: %#v err=%v", archived, err)
	}
	if _, err := s.ArchiveCard(activeCard.ID, true); !errors.Is(err, ErrCardActive) {
		t.Fatalf("archive active card: %v", err)
	}
	visible, err := s.ListCards(CardFilter{Board: board.ID})
	if err != nil || len(visible) != 2 {
		t.Fatalf("visible cards: %#v err=%v", visible, err)
	}
	all, err := s.ListCards(CardFilter{Board: board.ID, IncludeArchived: true})
	if err != nil || len(all) != 3 {
		t.Fatalf("all cards: %#v err=%v", all, err)
	}

	if err := s.ReleaseRuntimeLease(lease); err != nil {
		t.Fatal(err)
	}
	archived, err = s.ArchiveDoneCards(now)
	if err != nil || len(archived) != 1 || archived[0].ID != activeCard.ID {
		t.Fatalf("archive after turn completed: %#v err=%v", archived, err)
	}
	restored, err := s.ArchiveCard(oldCard.ID, false)
	if err != nil || restored.Archived {
		t.Fatalf("restore: %#v err=%v", restored, err)
	}
	if _, err := s.UpdateBoardDoneArchivePolicy(board.ID, model.DoneArchiveImmediately); err != nil {
		t.Fatal(err)
	}
	archived, err = s.ArchiveDoneCards(now.Add(time.Second))
	if err != nil || len(archived) != 1 || archived[0].ID != youngCard.ID {
		t.Fatalf("immediate archive: %#v err=%v", archived, err)
	}
	restored, err = s.ResolveCard(oldCard.ID)
	if err != nil || restored.Archived || !restored.DoneArchiveExempt {
		t.Fatalf("manual restore was not preserved: %#v err=%v", restored, err)
	}
}

func TestArchiveDoneCardsNoopDoesNotAdvanceSyncHighwater(t *testing.T) {
	s, project, board := setup(t, model.WorkflowReview)
	now := time.Now().UTC()
	card, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, Title: "Recent completion"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.MoveCard(card.ID, model.LaneDone, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := s.UpdateBoardDoneArchivePolicy(board.ID, model.DoneArchiveAfter7Days); err != nil {
		t.Fatal(err)
	}
	before, _, err := s.SyncEvents(0, 1)
	if err != nil {
		t.Fatal(err)
	}
	for range 4 {
		archived, archiveErr := s.ArchiveDoneCards(now)
		if archiveErr != nil || len(archived) != 0 {
			t.Fatalf("no-op archive=%#v err=%v", archived, archiveErr)
		}
	}
	after, events, err := s.SyncEvents(before.Sequence, 10)
	if err != nil {
		t.Fatal(err)
	}
	if after != before || len(events) != 0 {
		t.Fatalf("no-op archiving advanced sync: before=%#v after=%#v events=%#v", before, after, events)
	}
}

func TestArchiveDoneCardsActiveCandidateDoesNotPublishNoop(t *testing.T) {
	s, project, board := setup(t, model.WorkflowReview)
	now := time.Now().UTC()
	if _, err := s.UpdateBoardDoneArchivePolicy(board.ID, model.DoneArchiveAfter7Days); err != nil {
		t.Fatal(err)
	}
	card, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, Title: "Active old completion"})
	if err != nil {
		t.Fatal(err)
	}
	card, err = s.MoveCard(card.ID, model.LaneDone, nil)
	if err != nil {
		t.Fatal(err)
	}
	card.PhaseChangedAt = now.Add(-8 * 24 * time.Hour).Format(time.RFC3339Nano)
	if err := s.writeCard(card); err != nil {
		t.Fatal(err)
	}
	lease, err := s.AcquireRuntimeLease(project.ID, card.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.ReleaseRuntimeLease(lease) }()
	before, _, err := s.SyncEvents(0, 1)
	if err != nil {
		t.Fatal(err)
	}
	archived, err := s.ArchiveDoneCards(now)
	if err != nil || len(archived) != 0 {
		t.Fatalf("active archive=%#v err=%v", archived, err)
	}
	after, events, err := s.SyncEvents(before.Sequence, 10)
	if err != nil {
		t.Fatal(err)
	}
	if after != before || len(events) != 0 {
		t.Fatalf("active no-op advanced sync: before=%#v after=%#v events=%#v", before, after, events)
	}
}

func TestDirectWorkflowRejectsReview(t *testing.T) {
	s, p, b := setup(t, model.WorkflowDirect)
	card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, ID: "card_direct", Title: "Direct"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.MoveCard(card.ID, model.LaneReview, nil); err == nil {
		t.Fatal("expected review to be rejected")
	}
}

func TestBoardLabelsAssignFilterAndDelete(t *testing.T) {
	s, p, board := setup(t, model.WorkflowReview)
	board, err := s.CreateBoardLabel(board.ID, "Backend", "#3366ff")
	if err != nil || len(board.Labels) != 1 {
		t.Fatalf("create label: %#v %v", board.Labels, err)
	}
	label := board.Labels[0]
	card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: board.ID, ID: "card_labeled", Title: "Labeled", LabelIDs: []string{"Backend"}})
	if err != nil || len(card.LabelIDs) != 1 || card.LabelIDs[0] != label.ID {
		t.Fatalf("create labeled card: %#v %v", card, err)
	}
	other, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: board.ID, ID: "card_unlabeled", Title: "Unlabeled"})
	if err != nil {
		t.Fatal(err)
	}
	filtered, err := s.ListCards(CardFilter{Board: board.ID, Label: label.ID})
	if err != nil || len(filtered) != 1 || filtered[0].ID != card.ID {
		t.Fatalf("filter: %#v %v", filtered, err)
	}
	if _, err := s.SetCardLabels(other.ID, []string{label.ID}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetCardLabels(card.ID, []string{"missing"}); err == nil {
		t.Fatal("expected unknown label rejection")
	}
	if _, err := s.DeleteBoardLabel(board.ID, label.ID); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{card.ID, other.ID} {
		stored, _ := s.ResolveCard(id)
		if len(stored.LabelIDs) != 0 {
			t.Fatalf("label not removed from %s: %#v", id, stored.LabelIDs)
		}
	}
}

func TestCardIDsAreUnique(t *testing.T) {
	s, p, b := setup(t, model.WorkflowReview)
	input := CreateCardInput{Project: p.ID, Board: b.ID, ID: "card_unique", Title: "Unique"}
	if _, err := s.CreateCard(input); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateCard(input); err == nil {
		t.Fatal("expected duplicate card rejection")
	}
}

func TestConcurrentCommentsRemainReadable(t *testing.T) {
	s, p, b := setup(t, model.WorkflowReview)
	card, _ := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, ID: "card_concurrent", Title: "Concurrent"})
	var wg sync.WaitGroup
	for i := 0; i < 12; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := s.AddComment(card.ID, "progress", model.Author{Kind: "agent"}); err != nil {
				t.Errorf("comment: %v", err)
			}
		}()
	}
	wg.Wait()
	comments, err := s.ListComments(card.ID, 0)
	if err != nil || len(comments) != 12 {
		t.Fatalf("comments=%d err=%v", len(comments), err)
	}
}

func TestConversationEventsProjectToDurableMessages(t *testing.T) {
	s, p, b := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, Title: "Stream"})
	if err != nil {
		t.Fatal(err)
	}
	initialRevision, err := s.ConversationRevision(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.StartConversationTurn(card.ID, "turn_1", "user_1", "hello"); err != nil {
		t.Fatal(err)
	}
	startedRevision, err := s.ConversationRevision(card.ID)
	if err != nil || startedRevision == initialRevision {
		t.Fatalf("conversation revision did not advance: before=%q after=%q err=%v", initialRevision, startedRevision, err)
	}
	chunks := []string{
		`{"type":"start","messageId":"assistant_1","messageMetadata":{"createdAt":"2026-08-11T12:00:01Z"}}`,
		`{"type":"text-start","id":"text_1"}`,
		`{"type":"text-delta","id":"text_1","delta":"First sentence."}`,
		`{"type":"text-end","id":"text_1"}`,
		`{"type":"tool-input-available","toolCallId":"tool_1","toolName":"bash","input":{"command":"true"}}`,
		`{"type":"tool-output-available","toolCallId":"tool_1","output":{"exitCode":0}}`,
		`{"type":"text-start","id":"text_2"}`,
		`{"type":"text-delta","id":"text_2","delta":"Second sentence."}`,
		`{"type":"text-end","id":"text_2"}`,
		`{"type":"finish","finishReason":"stop"}`,
	}
	for _, chunk := range chunks {
		if _, _, err := s.AppendUIChunk(card.ID, "turn_1", []byte(chunk)); err != nil {
			t.Fatal(err)
		}
	}
	capability := `{"id":"subagents","operation":"upsert","subagent":{"id":"worker_1","provider":"omp","messageId":"assistant_1","parentToolCallId":"tool_1","name":"Scout","status":"running","activity":"Reading tests","tokens":1200}}`
	if _, _, err := s.AppendCapability(card.ID, "turn_1", []byte(capability)); err != nil {
		t.Fatal(err)
	}
	secondCapability := `{"id":"subagents","operation":"upsert","subagent":{"id":"worker_1","provider":"omp","messageId":"assistant_2","name":"Another scout","status":"completed"}}`
	if _, _, err := s.AppendCapability(card.ID, "turn_1", []byte(secondCapability)); err != nil {
		t.Fatal(err)
	}
	taskPlan := `{"id":"task-plan","operation":"replace","plan":{"id":"omp:assistant_1","provider":"omp","messageId":"assistant_1","revision":1,"state":"active","phases":[{"name":"Delivery","tasks":[{"content":"Inspect","status":"completed"},{"content":"Implement","activeForm":"Implementing","status":"in_progress","order":1}]}]}}`
	if _, _, err := s.AppendCapability(card.ID, "turn_1", []byte(taskPlan)); err != nil {
		t.Fatal(err)
	}
	newerTaskPlan := `{"id":"task-plan","operation":"replace","plan":{"id":"omp:assistant_1","provider":"omp","messageId":"assistant_1","revision":2,"state":"completed","phases":[{"name":"Delivery","tasks":[{"content":"Inspect","status":"completed"},{"content":"Implement","status":"completed","order":1}]}]}}`
	if _, _, err := s.AppendCapability(card.ID, "turn_1", []byte(newerTaskPlan)); err != nil {
		t.Fatal(err)
	}
	conversation, err := s.Conversation(card.ID)
	if err != nil || conversation.Status != "idle" || len(conversation.Messages) != 2 {
		t.Fatalf("conversation=%#v err=%v", conversation, err)
	}
	assistant := conversation.Messages[1]
	var metadata map[string]string
	_ = json.Unmarshal(assistant.Metadata, &metadata)
	if metadata["createdAt"] != "2026-08-11T12:00:01Z" || len(assistant.Parts) != 3 || assistant.Parts[0].Text != "First sentence." || assistant.Parts[2].Text != "Second sentence." {
		t.Fatalf("message part boundaries or metadata lost: %#v", assistant)
	}
	if assistant.Parts[1].ToolName != "bash" || assistant.Parts[1].State != "output-available" || len(assistant.Parts[1].Input) == 0 || len(assistant.Parts[1].Output) == 0 {
		t.Fatalf("tool transition lost fields: %#v", assistant.Parts[1])
	}
	if len(conversation.Subagents) != 2 || conversation.Subagents[0].Name != "Scout" || conversation.Subagents[0].Activity != "Reading tests" || conversation.Subagents[0].Tokens != 1200 || conversation.Subagents[1].MessageID != "assistant_2" {
		t.Fatalf("subagent capability was not projected: %#v", conversation.Subagents)
	}
	if len(conversation.TaskPlans) != 1 || conversation.TaskPlans[0].Revision != 2 || conversation.TaskPlans[0].State != "completed" || conversation.TaskPlans[0].Phases[0].Tasks[1].Status != "completed" {
		t.Fatalf("task plan capability was not replaced: %#v", conversation.TaskPlans)
	}
	encoded, _ := json.Marshal(conversation.Messages[0])
	if bytes.Contains(encoded, []byte(`"createdAt":`)) && !bytes.Contains(encoded, []byte(`"metadata":{"createdAt":`)) {
		t.Fatalf("timestamp escaped AI SDK metadata: %s", encoded)
	}

	// An older reducer discarded tool names on output. The event log is the
	// source of truth, so an outdated snapshot must be rebuilt rather than
	// patched heuristically.
	conversation.ProjectionVersion = 0
	conversation.Messages[1].Parts[1].ToolName = ""
	conversation.Messages[1].Parts[1].State = "tool-output-available"
	legacySnapshot, _ := json.Marshal(conversation)
	var legacyObject map[string]any
	_ = json.Unmarshal(legacySnapshot, &legacyObject)
	delete(legacyObject, "projectionVersion")
	legacySnapshot, _ = json.Marshal(legacyObject)
	if err := atomicWrite(filepath.Join(s.conversationPath(card.ID), "snapshot.json"), legacySnapshot); err != nil {
		t.Fatal(err)
	}
	rebuilt, err := s.Conversation(card.ID)
	if err != nil || rebuilt.ProjectionVersion != conversationProjectionVersion || rebuilt.Messages[1].Parts[1].ToolName != "bash" || rebuilt.Messages[1].Parts[1].State != "output-available" {
		t.Fatalf("outdated projection was not rebuilt from events: %#v err=%v", rebuilt, err)
	}
}

func TestConversationCoalescesAdjacentACPContentBlocks(t *testing.T) {
	s, project, board := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, Title: "OMP fragments"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.StartConversationTurn(card.ID, "turn_1", "user_1", "inspect"); err != nil {
		t.Fatal(err)
	}
	chunks := []string{
		`{"type":"start","messageId":"assistant_1"}`,
		`{"type":"reasoning-start","id":"reasoning_before"}`,
		`{"type":"reasoning-delta","id":"reasoning_before","delta":"Before tool."}`,
		`{"type":"reasoning-end","id":"reasoning_before"}`,
		`{"type":"tool-input-available","toolCallId":"tool_1","toolName":"task","input":{}}`,
		`{"type":"tool-output-available","toolCallId":"tool_1","output":{}}`,
		`{"type":"reasoning-start","id":"reasoning_after_1"}`,
		`{"type":"reasoning-delta","id":"reasoning_after_1","delta":"After"}`,
		`{"type":"reasoning-end","id":"reasoning_after_1"}`,
		`{"type":"reasoning-start","id":"reasoning_after_2"}`,
		`{"type":"reasoning-delta","id":"reasoning_after_2","delta":" tool."}`,
		`{"type":"reasoning-end","id":"reasoning_after_2"}`,
		`{"type":"text-start","id":"text_1"}`,
		`{"type":"text-delta","id":"text_1","delta":"All"}`,
		`{"type":"text-end","id":"text_1"}`,
		`{"type":"text-start","id":"text_2"}`,
		`{"type":"text-delta","id":"text_2","delta":" done."}`,
		`{"type":"text-end","id":"text_2"}`,
	}
	for _, chunk := range chunks {
		if _, _, err := s.AppendUIChunk(card.ID, "turn_1", []byte(chunk)); err != nil {
			t.Fatal(err)
		}
	}
	conversation, err := s.Conversation(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	parts := conversation.Messages[1].Parts
	if len(parts) != 4 || parts[0].Text != "Before tool." || parts[1].ToolCallID != "tool_1" || parts[2].Text != "After tool." || parts[3].Text != "All done." {
		t.Fatalf("adjacent ACP content blocks were not coalesced around the tool boundary: %#v", parts)
	}

	// Existing snapshots can contain the same ACP fragmentation. Loading them
	// must normalize the disposable projection without altering the event log.
	conversation.Messages[1].Parts = append(conversation.Messages[1].Parts,
		model.UIMessagePart{Type: "reasoning", Text: "Existing", State: "done"},
		model.UIMessagePart{Type: "reasoning", Text: " snapshot", State: "done"},
	)
	raw, _ := json.Marshal(conversation)
	if err := atomicWrite(filepath.Join(s.conversationPath(card.ID), "snapshot.json"), raw); err != nil {
		t.Fatal(err)
	}
	normalized, err := s.Conversation(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	normalizedParts := normalized.Messages[1].Parts
	if len(normalizedParts) != 5 || normalizedParts[4].Text != "Existing snapshot" {
		t.Fatalf("existing fragmented snapshot was not normalized: %#v", normalizedParts)
	}
}

func TestRuntimeLeaseAllowsParallelProjectTurnsButSerializesCards(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowReview)
	lease, err := s.AcquireRuntimeLease(project.ID, "card_one")
	if err != nil {
		t.Fatal(err)
	}
	next, err := New(s.Root).AcquireRuntimeLease(project.ID, "card_two")
	if err != nil {
		t.Fatalf("parallel turn in same project: %v", err)
	}
	if _, err := New(s.Root).AcquireRuntimeLease(project.ID, "card_one"); !errors.Is(err, ErrCardActive) {
		t.Fatalf("same card lease error = %v, want ErrCardActive", err)
	}
	if err := s.ReleaseRuntimeLease(lease); err != nil {
		t.Fatal(err)
	}
	if err := s.ReleaseRuntimeLease(next); err != nil {
		t.Fatal(err)
	}
}

func TestForkChatCopiesPrefixWithoutSharingSession(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowReview)
	source, err := s.CreateChat(CreateCardInput{Project: project.ID, Title: "Source", Provider: "codex", Model: "gpt-5.6-sol", Effort: "high"})
	if err != nil {
		t.Fatal(err)
	}
	messages := []model.UIMessage{
		{ID: "user-1", Role: "user", Parts: []model.UIMessagePart{{Type: "text", Text: "First question"}}},
		{ID: "assistant-1", Role: "assistant", Parts: []model.UIMessagePart{{Type: "text", Text: "First answer"}}},
		{ID: "user-2", Role: "user", Parts: []model.UIMessagePart{{Type: "text", Text: "Later question"}}},
	}
	if _, err := s.InitializeForkConversation(source.ID, messages); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetConversationSession(source.ID, "", json.RawMessage(`{"type":"resume-session","data":{"threadId":"source"}}`)); err != nil {
		t.Fatal(err)
	}
	fork, err := s.ForkChat(source.ID, "assistant-1", "Alternative")
	if err != nil {
		t.Fatal(err)
	}
	if fork.Scope != model.ConversationScopeChat || fork.Title != "Alternative" || fork.ID == source.ID {
		t.Fatalf("fork = %#v", fork)
	}
	conversation, err := s.Conversation(fork.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(conversation.Messages) != 2 || len(conversation.ForkSeed) != 2 {
		t.Fatalf("messages=%d seed=%d", len(conversation.Messages), len(conversation.ForkSeed))
	}
	if len(conversation.Session) != 0 {
		t.Fatalf("fork shared session: %s", conversation.Session)
	}
	if fork.InitialPromptSentAt == "" || fork.Provider != source.Provider || fork.Model != source.Model || fork.Effort != source.Effort {
		t.Fatalf("fork settings = %#v", fork)
	}
}

func TestArchivedCardsLeaveTheActiveScanAndRemainResolvable(t *testing.T) {
	s, project, board := setup(t, model.WorkflowReview)
	active, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, ID: "active-card", Title: "Active"})
	if err != nil {
		t.Fatal(err)
	}
	archived, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, ID: "archived-card", Title: "Archived"})
	if err != nil {
		t.Fatal(err)
	}
	if archived, err = s.ArchiveCard(archived.ID, true); err != nil || !archived.Archived {
		t.Fatalf("archive = %#v, %v", archived, err)
	}
	if _, err := os.Stat(filepath.Join(s.cardDir(), archived.ID+".md")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("archived card remained in active directory: %v", err)
	}
	if _, err := os.Stat(filepath.Join(s.archivedCardDir(), archived.ID+".md")); err != nil {
		t.Fatalf("archived card was not partitioned: %v", err)
	}
	visible, err := s.ListCards(CardFilter{Project: project.ID})
	if err != nil || len(visible) != 1 || visible[0].ID != active.ID {
		t.Fatalf("visible cards = %#v, %v", visible, err)
	}
	all, err := s.ListCards(CardFilter{Project: project.ID, IncludeArchived: true})
	if err != nil || len(all) != 2 {
		t.Fatalf("all cards = %#v, %v", all, err)
	}
	if resolved, err := s.ResolveCard(archived.ID); err != nil || !resolved.Archived {
		t.Fatalf("resolve archived = %#v, %v", resolved, err)
	}
	if _, err := s.ConversationByID(archived.ID); err != nil {
		t.Fatalf("archived conversation lookup: %v", err)
	}
	if _, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, ID: archived.ID, Title: "Duplicate"}); err == nil {
		t.Fatal("archived card ID was reused")
	}
	if restored, err := s.ArchiveCard(archived.ID, false); err != nil || restored.Archived {
		t.Fatalf("restore = %#v, %v", restored, err)
	}
	if _, err := os.Stat(filepath.Join(s.cardDir(), archived.ID+".md")); err != nil {
		t.Fatalf("restored card missing from active directory: %v", err)
	}
}

func TestEnsureMigratesLegacyArchivedCards(t *testing.T) {
	s, project, board := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, ID: "legacy-archived", Title: "Legacy"})
	if err != nil {
		t.Fatal(err)
	}
	card.Archived = true
	if err := writeMarkdown(filepath.Join(s.cardDir(), card.ID+".md"), card, card.InitialPrompt); err != nil {
		t.Fatal(err)
	}
	reopened := New(s.Root)
	if err := reopened.Ensure(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(reopened.archivedCardDir(), card.ID+".md")); err != nil {
		t.Fatalf("legacy card was not migrated: %v", err)
	}
	if visible, err := reopened.ListCards(CardFilter{Project: project.ID}); err != nil || len(visible) != 0 {
		t.Fatalf("legacy archived card leaked into active scan: %#v, %v", visible, err)
	}
}

func TestGlobalStateCacheAdvancesWithSyncCursor(t *testing.T) {
	s, project, board := setup(t, model.WorkflowReview)
	if _, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, Title: "First"}); err != nil {
		t.Fatal(err)
	}
	first, err := s.GlobalState()
	if err != nil || len(first.Cards) != 1 {
		t.Fatalf("first global state = %#v, %v", first, err)
	}
	if _, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, Title: "Second"}); err != nil {
		t.Fatal(err)
	}
	second, err := s.GlobalState()
	if err != nil || len(second.Cards) != 2 {
		t.Fatalf("updated global state = %#v, %v", second, err)
	}
}
