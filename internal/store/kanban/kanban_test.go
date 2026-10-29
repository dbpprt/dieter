package kanban_test

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/leases"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestCreateProjectAcceptsLinkedGitWorktree(t *testing.T) {
	t.Parallel()
	worktree := filepath.Join(t.TempDir(), "linked-worktree")
	if err := os.MkdirAll(worktree, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(worktree, ".git"), []byte("gitdir: ../repo/.git/worktrees/linked-worktree\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	data := store.New(t.TempDir())
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Path: worktree})
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

func TestUpdateProjectRelocatesCanonicalWorkingTree(t *testing.T) {
	t.Parallel()
	s, project, _ := testkit.BoardStore(t, model.WorkflowDirect)
	relocated := testkit.ProjectDir(t)
	updated, err := s.Kanban.UpdateProject(project.ID, nil, nil, nil, &relocated)
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

	other, err := s.Kanban.CreateProject(kanban.CreateProjectInput{Path: testkit.ProjectDir(t), Name: "Other"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.UpdateProject(project.ID, nil, nil, nil, &other.Path); err == nil {
		t.Fatal("expected duplicate project path to be rejected")
	}
}

func TestConversationCardLifecycle(t *testing.T) {
	t.Parallel()
	s, p, b := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, ID: "card_1", Title: "Recover sessions", Prompt: "Implement it."})
	if err != nil || card.ID != "card_1" || card.Lane != model.LaneTodo {
		t.Fatalf("create: %#v %v", card, err)
	}
	if _, err = s.Kanban.MarkPromptSent(card.ID); err != nil {
		t.Fatal(err)
	}
	card, err = s.Kanban.MoveCard(card.ID, model.LaneReview, nil)
	if err != nil || card.Lane != model.LaneReview {
		t.Fatalf("review: %#v %v", card, err)
	}
	detail, err := s.Kanban.CardDetail(card.ID)
	if err != nil || detail.Card.InitialPrompt != "Implement it." {
		t.Fatalf("detail: %#v %v", detail, err)
	}
	if _, err := os.Stat(filepath.Join(p.Path, ".dieter")); !os.IsNotExist(err) {
		t.Fatalf("project repository was modified: %v", err)
	}
}

func TestNewCardsSnapshotBoardGitDefaults(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	if _, err := s.Kanban.UpdateProjectWorkspaceSettings(project.ID, "origin", "main", nil); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.UpdateBoardGitSettings(board.ID, "private", model.RemotePublishPullRequest); err != nil {
		t.Fatal(err)
	}
	first, err := s.Kanban.CreateCard(kanban.CreateCardInput{
		Project: project.ID, Board: board.ID, Title: "First", WorkspaceMode: model.WorkspaceModeWorktree,
	})
	if err != nil {
		t.Fatal(err)
	}
	if first.WorkspaceBaseRemote != "private" || first.RemotePublishMode != model.RemotePublishPullRequest {
		t.Fatalf("first card did not snapshot board defaults: %#v", first)
	}
	if _, err := s.Kanban.UpdateBoardGitSettings(board.ID, "origin", model.RemotePublishPushBase); err != nil {
		t.Fatal(err)
	}
	first, err = s.Kanban.ResolveCard(first.ID)
	if err != nil {
		t.Fatal(err)
	}
	if first.WorkspaceBaseRemote != "private" || first.RemotePublishMode != model.RemotePublishPullRequest {
		t.Fatalf("existing card changed with board defaults: %#v", first)
	}
	second, err := s.Kanban.CreateCard(kanban.CreateCardInput{
		Project: project.ID, Board: board.ID, Title: "Second", WorkspaceMode: model.WorkspaceModeWorktree,
	})
	if err != nil {
		t.Fatal(err)
	}
	if second.WorkspaceBaseRemote != "origin" || second.RemotePublishMode != model.RemotePublishPushBase {
		t.Fatalf("second card did not snapshot updated defaults: %#v", second)
	}
	if _, err := s.Kanban.UpdateBoardGitSettings(board.ID, "private", "unexpected"); err == nil {
		t.Fatal("invalid remote publish mode was accepted")
	}
}

func TestRenameBoardPersistsNameWithoutChangingIdentity(t *testing.T) {
	t.Parallel()
	s, _, board := testkit.BoardStore(t, model.WorkflowReview)
	updated, err := s.Kanban.RenameBoard(board.ID, "  Platform delivery  ")
	if err != nil {
		t.Fatal(err)
	}
	if updated.ID != board.ID || updated.Name != "Platform delivery" || updated.UpdatedAt == board.UpdatedAt {
		t.Fatalf("renamed board=%#v original=%#v", updated, board)
	}
	stored, err := s.Kanban.ResolveBoard("", board.ID)
	if err != nil || stored.Name != "Platform delivery" {
		t.Fatalf("stored board=%#v err=%v", stored, err)
	}
	if _, err := s.Kanban.RenameBoard(board.ID, "   "); err == nil || err.Error() != "board name is required" {
		t.Fatalf("empty name error=%v", err)
	}
}

func TestUpdateCardEditsOnlyAnUnsentTask(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{
		Project: project.ID, Board: board.ID, ID: "card_edit", Title: "Original", Prompt: "Original task",
	})
	if err != nil {
		t.Fatal(err)
	}

	updated, err := s.Kanban.UpdateCard(card.ID, " Edited title ", " Edited task ")
	if err != nil || updated.Title != "Edited title" || updated.InitialPrompt != "Edited task" {
		t.Fatalf("updated=%#v err=%v", updated, err)
	}
	if _, err := s.Kanban.MarkPromptSent(card.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.UpdateCard(card.ID, "Another title", "Different task"); err == nil || err.Error() != "agent task can only be edited before it is sent" {
		t.Fatalf("late task edit error=%v", err)
	}
	stored, err := s.Kanban.ResolveCard(card.ID)
	if err != nil || stored.Title != "Edited title" || stored.InitialPrompt != "Edited task" {
		t.Fatalf("stored=%#v err=%v", stored, err)
	}
	updated, err = s.Kanban.UpdateCard(card.ID, "Title after send", stored.InitialPrompt)
	if err != nil || updated.Title != "Title after send" || updated.InitialPrompt != "Edited task" {
		t.Fatalf("title-only update=%#v err=%v", updated, err)
	}
}

func TestUpdateCardCachePersistsAndClearsProviderAccountKey(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{
		Project: project.ID, Board: board.ID, ID: "card_provider_account", Title: "Account", Prompt: "Work",
	})
	if err != nil {
		t.Fatal(err)
	}
	accountKey := "owner_scoped_account_key"
	updated, err := s.Kanban.UpdateCardCache(card.ID, kanban.CardCacheInput{ProviderAccountKey: &accountKey})
	if err != nil || updated.ProviderAccountKey != accountKey {
		t.Fatalf("provider account update = %#v, %v", updated, err)
	}
	empty := ""
	updated, err = s.Kanban.UpdateCardCache(card.ID, kanban.CardCacheInput{ProviderAccountKey: &empty})
	if err != nil || updated.ProviderAccountKey != "" {
		t.Fatalf("provider account clear = %#v, %v", updated, err)
	}
}

func TestProjectRemovalRejectsActiveAgentTurn(t *testing.T) {
	t.Parallel()
	s, project, _ := testkit.BoardStore(t, model.WorkflowReview)
	lease, err := s.Kanban.AcquireRuntimeLease(project.ID, "card_running")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.Leases.Release(lease) }()
	if _, err := s.Kanban.ArchiveProject(project.ID, true); !errors.Is(err, leases.ErrCardActive) {
		t.Fatalf("remove active project: %v", err)
	}
	if _, err := s.Kanban.ResolveProject(project.ID); err != nil {
		t.Fatalf("active project was hidden after rejection: %v", err)
	}
}

func TestDoneArchivePolicyHidesAndRestoresCompletedCards(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	now := time.Now().UTC()

	oldCard, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, ID: "card_old_done", Title: "Old completion"})
	if err != nil {
		t.Fatal(err)
	}
	oldCard, err = s.Kanban.MoveCard(oldCard.ID, model.LaneDone, nil)
	if err != nil {
		t.Fatal(err)
	}
	oldCard.PhaseChangedAt = now.Add(-8 * 24 * time.Hour).Format(time.RFC3339Nano)
	if err := s.Kanban.WriteCard(oldCard); err != nil {
		t.Fatal(err)
	}

	youngCard, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, ID: "card_young_done", Title: "Recent completion"})
	if err != nil {
		t.Fatal(err)
	}
	if youngCard, err = s.Kanban.MoveCard(youngCard.ID, model.LaneDone, nil); err != nil {
		t.Fatal(err)
	}

	activeCard, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, ID: "card_active_done", Title: "Active completion"})
	if err != nil {
		t.Fatal(err)
	}
	activeCard, err = s.Kanban.MoveCard(activeCard.ID, model.LaneDone, nil)
	if err != nil {
		t.Fatal(err)
	}
	activeCard.PhaseChangedAt = now.Add(-8 * 24 * time.Hour).Format(time.RFC3339Nano)
	if err := s.Kanban.WriteCard(activeCard); err != nil {
		t.Fatal(err)
	}

	if archived, err := s.Kanban.ArchiveDoneCards(now); err != nil || len(archived) != 0 {
		t.Fatalf("default policy archived cards: %#v err=%v", archived, err)
	}
	updated, err := s.Kanban.UpdateBoardDoneArchivePolicy(board.ID, model.DoneArchiveAfter7Days)
	if err != nil || updated.DoneArchivePolicy != model.DoneArchiveAfter7Days {
		t.Fatalf("update policy: %#v err=%v", updated, err)
	}
	lease, err := s.Kanban.AcquireRuntimeLease(project.ID, activeCard.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.Leases.Release(lease) }()

	archived, err := s.Kanban.ArchiveDoneCards(now)
	if err != nil || len(archived) != 1 || archived[0].ID != oldCard.ID {
		t.Fatalf("timed archive: %#v err=%v", archived, err)
	}
	if _, err := s.Kanban.ArchiveCard(activeCard.ID, true); !errors.Is(err, leases.ErrCardActive) {
		t.Fatalf("archive active card: %v", err)
	}
	visible, err := s.Kanban.ListCards(kanban.CardFilter{Board: board.ID})
	if err != nil || len(visible) != 2 {
		t.Fatalf("visible cards: %#v err=%v", visible, err)
	}
	all, err := s.Kanban.ListCards(kanban.CardFilter{Board: board.ID, IncludeArchived: true})
	if err != nil || len(all) != 3 {
		t.Fatalf("all cards: %#v err=%v", all, err)
	}

	if err := s.Leases.Release(lease); err != nil {
		t.Fatal(err)
	}
	archived, err = s.Kanban.ArchiveDoneCards(now)
	if err != nil || len(archived) != 1 || archived[0].ID != activeCard.ID {
		t.Fatalf("archive after turn completed: %#v err=%v", archived, err)
	}
	restored, err := s.Kanban.ArchiveCard(oldCard.ID, false)
	if err != nil || restored.Archived {
		t.Fatalf("restore: %#v err=%v", restored, err)
	}
	if _, err := s.Kanban.UpdateBoardDoneArchivePolicy(board.ID, model.DoneArchiveImmediately); err != nil {
		t.Fatal(err)
	}
	archived, err = s.Kanban.ArchiveDoneCards(time.Now().UTC())
	if err != nil || len(archived) != 1 || archived[0].ID != youngCard.ID {
		t.Fatalf("immediate archive: %#v err=%v", archived, err)
	}
	restored, err = s.Kanban.ResolveCard(oldCard.ID)
	if err != nil || restored.Archived || !restored.DoneArchiveExempt {
		t.Fatalf("manual restore was not preserved: %#v err=%v", restored, err)
	}
}

func TestArchiveDoneCardsNoopDoesNotAdvanceSyncHighwater(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	now := time.Now().UTC()
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Recent completion"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.MoveCard(card.ID, model.LaneDone, nil); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.UpdateBoardDoneArchivePolicy(board.ID, model.DoneArchiveAfter7Days); err != nil {
		t.Fatal(err)
	}
	beforeChanges, beforeMetadata := testkit.ChangeCounters(t, s)
	for range 4 {
		archived, archiveErr := s.Kanban.ArchiveDoneCards(now)
		if archiveErr != nil || len(archived) != 0 {
			t.Fatalf("no-op archive=%#v err=%v", archived, archiveErr)
		}
	}
	if changes, metadata := testkit.ChangeCounters(t, s); changes != beforeChanges || metadata != beforeMetadata {
		t.Fatalf("no-op archiving recorded a change: %d/%d -> %d/%d", beforeChanges, beforeMetadata, changes, metadata)
	}
}

func TestArchiveDoneCardsActiveCandidateDoesNotPublishNoop(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	now := time.Now().UTC()
	if _, err := s.Kanban.UpdateBoardDoneArchivePolicy(board.ID, model.DoneArchiveAfter7Days); err != nil {
		t.Fatal(err)
	}
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Active old completion"})
	if err != nil {
		t.Fatal(err)
	}
	card, err = s.Kanban.MoveCard(card.ID, model.LaneDone, nil)
	if err != nil {
		t.Fatal(err)
	}
	card.PhaseChangedAt = now.Add(-8 * 24 * time.Hour).Format(time.RFC3339Nano)
	if err := s.Kanban.WriteCard(card); err != nil {
		t.Fatal(err)
	}
	lease, err := s.Kanban.AcquireRuntimeLease(project.ID, card.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = s.Leases.Release(lease) }()
	beforeChanges, beforeMetadata := testkit.ChangeCounters(t, s)
	archived, err := s.Kanban.ArchiveDoneCards(now)
	if err != nil || len(archived) != 0 {
		t.Fatalf("active archive=%#v err=%v", archived, err)
	}
	if changes, metadata := testkit.ChangeCounters(t, s); changes != beforeChanges || metadata != beforeMetadata {
		t.Fatalf("active no-op recorded a change: %d/%d -> %d/%d", beforeChanges, beforeMetadata, changes, metadata)
	}
}

func TestDirectWorkflowRejectsReview(t *testing.T) {
	t.Parallel()
	s, p, b := testkit.BoardStore(t, model.WorkflowDirect)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, ID: "card_direct", Title: "Direct"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.MoveCard(card.ID, model.LaneReview, nil); err == nil {
		t.Fatal("expected review to be rejected")
	}
}

func TestBoardLabelsAssignFilterAndDelete(t *testing.T) {
	t.Parallel()
	s, p, board := testkit.BoardStore(t, model.WorkflowReview)
	board, err := s.Kanban.CreateBoardLabel(board.ID, "Backend", "#3366ff")
	if err != nil || len(board.Labels) != 1 {
		t.Fatalf("create label: %#v %v", board.Labels, err)
	}
	label := board.Labels[0]
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: board.ID, ID: "card_labeled", Title: "Labeled", LabelIDs: []string{"Backend"}})
	if err != nil || len(card.LabelIDs) != 1 || card.LabelIDs[0] != label.ID {
		t.Fatalf("create labeled card: %#v %v", card, err)
	}
	other, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: board.ID, ID: "card_unlabeled", Title: "Unlabeled"})
	if err != nil {
		t.Fatal(err)
	}
	filtered, err := s.Kanban.ListCards(kanban.CardFilter{Board: board.ID, Label: label.ID})
	if err != nil || len(filtered) != 1 || filtered[0].ID != card.ID {
		t.Fatalf("filter: %#v %v", filtered, err)
	}
	if _, err := s.Kanban.SetCardLabels(other.ID, []string{label.ID}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.SetCardLabels(card.ID, []string{"missing"}); err == nil {
		t.Fatal("expected unknown label rejection")
	}
	if _, err := s.Kanban.DeleteBoardLabel(board.ID, label.ID); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{card.ID, other.ID} {
		stored, _ := s.Kanban.ResolveCard(id)
		if len(stored.LabelIDs) != 0 {
			t.Fatalf("label not removed from %s: %#v", id, stored.LabelIDs)
		}
	}
}

func TestCardIDsAreUnique(t *testing.T) {
	t.Parallel()
	s, p, b := testkit.BoardStore(t, model.WorkflowReview)
	input := kanban.CreateCardInput{Project: p.ID, Board: b.ID, ID: "card_unique", Title: "Unique"}
	if _, err := s.Kanban.CreateCard(input); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.CreateCard(input); err == nil {
		t.Fatal("expected duplicate card rejection")
	}
}

func TestArchiveSurvivesStoreRestart(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, ID: "archived", Title: "Archived"})
	if err != nil {
		t.Fatal(err)
	}
	card.Archived = true
	if err := s.Kanban.WriteCard(card); err != nil {
		t.Fatal(err)
	}
	reopened := store.New(s.Root)
	if err := reopened.Ensure(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(reopened.ArchivedCardDir(), card.ID+".md")); err != nil {
		t.Fatalf("archived card was not retained: %v", err)
	}
	if visible, err := reopened.Kanban.ListCards(kanban.CardFilter{Project: project.ID}); err != nil || len(visible) != 0 {
		t.Fatalf("archived card leaked into active scan: %#v, %v", visible, err)
	}
}

func TestGlobalStateCacheAdvancesWithMetadataRevision(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	if _, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Title: "First"}); err != nil {
		t.Fatal(err)
	}
	first, err := s.Kanban.GlobalState()
	if err != nil || len(first.Cards) != 1 {
		t.Fatalf("first global state = %#v, %v", first, err)
	}
	if _, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Second"}); err != nil {
		t.Fatal(err)
	}
	second, err := s.Kanban.GlobalState()
	if err != nil || len(second.Cards) != 2 {
		t.Fatalf("updated global state = %#v, %v", second, err)
	}
}
