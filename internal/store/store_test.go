package store_test

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/schedules"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestProjectRemovalHidesResourcesAndCanBeRestored(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	marker := filepath.Join(project.Path, "keep-me.txt")
	if err := os.WriteFile(marker, []byte("untouched"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, ID: "card_board", Title: "Board work"}); err != nil {
		t.Fatal(err)
	}
	chat, err := s.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, ID: "chat_standalone", Title: "Standalone"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Schedules.Create(schedules.Input{
		Project: project.ID, Board: board.ID, Name: "Daily", Cron: "0 9 * * *", Timezone: "UTC",
		TitleTemplate: "Daily", PromptTemplate: "Run daily", Provider: "codex", Model: "gpt-5.5",
	}); err != nil {
		t.Fatal(err)
	}

	removed, err := s.Kanban.ArchiveProject(project.ID, true)
	if err != nil || !removed.Archived {
		t.Fatalf("remove: %#v %v", removed, err)
	}
	if projects, _ := s.Kanban.ListProjects(); len(projects) != 0 {
		t.Fatalf("active projects=%#v", projects)
	}
	archived, err := s.Kanban.ListArchivedProjects()
	if err != nil || len(archived) != 1 || archived[0].BoardCount != 1 || archived[0].CardCount != 1 || archived[0].ChatCount != 1 {
		t.Fatalf("removed projects=%#v err=%v", archived, err)
	}
	if _, err := s.Kanban.ResolveProject(project.ID); !errors.Is(err, home.ErrNotFound) {
		t.Fatalf("removed project resolved: %v", err)
	}
	if boards, _ := s.Kanban.ListBoards(""); len(boards) != 0 {
		t.Fatalf("removed boards leaked: %#v", boards)
	}
	if cards, _ := s.Kanban.ListCards(kanban.CardFilter{}); len(cards) != 0 {
		t.Fatalf("removed cards leaked: %#v", cards)
	}
	if schedules, _ := s.Schedules.List(""); len(schedules) != 0 {
		t.Fatalf("removed schedules leaked: %#v", schedules)
	}
	if _, err := s.Kanban.CardDetail(chat.ID); !errors.Is(err, home.ErrNotFound) {
		t.Fatalf("removed chat detail resolved: %v", err)
	}
	if raw, err := os.ReadFile(marker); err != nil || string(raw) != "untouched" {
		t.Fatalf("working tree changed: %q %v", raw, err)
	}

	restored, err := s.Kanban.ArchiveProject(project.ID, false)
	if err != nil || restored.Archived {
		t.Fatalf("restore: %#v %v", restored, err)
	}
	if projects, _ := s.Kanban.ListProjects(); len(projects) != 1 {
		t.Fatalf("restored projects=%#v", projects)
	}
	if cards, _ := s.Kanban.ListCards(kanban.CardFilter{}); len(cards) != 2 {
		t.Fatalf("restored cards=%#v", cards)
	}
	if schedules, _ := s.Schedules.List(""); len(schedules) != 1 {
		t.Fatalf("restored schedules=%#v", schedules)
	}
}

func TestArchivedCardsLeaveTheActiveScanAndRemainResolvable(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	active, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, ID: "active-card", Title: "Active"})
	if err != nil {
		t.Fatal(err)
	}
	archived, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, ID: "archived-card", Title: "Archived"})
	if err != nil {
		t.Fatal(err)
	}
	if archived, err = s.Kanban.ArchiveCard(archived.ID, true); err != nil || !archived.Archived {
		t.Fatalf("archive = %#v, %v", archived, err)
	}
	if _, err := os.Stat(filepath.Join(s.CardDir(), archived.ID+".md")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("archived card remained in active directory: %v", err)
	}
	if _, err := os.Stat(filepath.Join(s.ArchivedCardDir(), archived.ID+".md")); err != nil {
		t.Fatalf("archived card was not partitioned: %v", err)
	}
	visible, err := s.Kanban.ListCards(kanban.CardFilter{Project: project.ID})
	if err != nil || len(visible) != 1 || visible[0].ID != active.ID {
		t.Fatalf("visible cards = %#v, %v", visible, err)
	}
	all, err := s.Kanban.ListCards(kanban.CardFilter{Project: project.ID, IncludeArchived: true})
	if err != nil || len(all) != 2 {
		t.Fatalf("all cards = %#v, %v", all, err)
	}
	if resolved, err := s.Kanban.ResolveCard(archived.ID); err != nil || !resolved.Archived {
		t.Fatalf("resolve archived = %#v, %v", resolved, err)
	}
	if _, err := s.Conversations.ByID(archived.ID); err != nil {
		t.Fatalf("archived conversation lookup: %v", err)
	}
	if _, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, ID: archived.ID, Title: "Duplicate"}); err == nil {
		t.Fatal("archived card ID was reused")
	}
	if restored, err := s.Kanban.ArchiveCard(archived.ID, false); err != nil || restored.Archived {
		t.Fatalf("restore = %#v, %v", restored, err)
	}
	if _, err := os.Stat(filepath.Join(s.CardDir(), archived.ID+".md")); err != nil {
		t.Fatalf("restored card missing from active directory: %v", err)
	}
}

func TestSharedAccountSwitchHidesConversationAndLocalFiles(t *testing.T) {
	t.Parallel()
	s := testkit.PeerStore(t, "machine_a")
	p, err := s.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Private", Path: testkit.ProjectDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	card, err := s.Kanban.CreateChat(kanban.CreateCardInput{Project: p.ID, Title: "Private conversation", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Replica.BindPeerAccount("other-account", "other-subject", "machine_new", "https://gateway.test"); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Kanban.ResolveCard(card.ID); !errors.Is(err, home.ErrNotFound) {
		t.Fatalf("leaked directory: %v", err)
	}
	if _, err = s.Conversations.ByID(card.ID); !errors.Is(err, home.ErrNotFound) {
		t.Fatalf("leaked conversation: %v", err)
	}
	if projects, err := s.Kanban.ListProjects(); err != nil || len(projects) != 0 {
		t.Fatalf("leaked projects %v %v", projects, err)
	}
}

func TestBoardRetirementPausedScheduleAndPagination(t *testing.T) {
	t.Parallel()
	s := testkit.PeerStore(t, "owner")
	p, err := s.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Dieter", Path: testkit.ProjectDir(t), InitialBoardName: "Main", InitialWorkflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	board, err := s.Kanban.InitialBoard(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	input := schedules.Input{
		Project: p.ID, Board: board.ID, Name: "Paused", Cron: "* * * * *", Timezone: "UTC",
		Enabled: true, Action: model.ScheduleActionDraft, TitleTemplate: "Paused",
		PromptTemplate: "Run Paused", Provider: "codex", Model: "gpt-5.5",
		OpenCardPolicy: "always", WorkspaceMode: model.WorkspaceModeProject,
	}
	input.Enabled = false
	if _, err := s.Schedules.Create(input); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.SetBoardRetired(kanban.BoardRetirementInput{BoardID: board.ID, Retired: true, ExpectedRevision: board.RetirementRevision, OperationID: "refused"}); err == nil {
		t.Fatal("paused schedule allowed retirement")
	}
	for i := 0; i < 3; i++ {
		b, err := s.Kanban.CreateBoard(kanban.CreateBoardInput{Project: p.ID, Name: "Empty"})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.Kanban.SetBoardRetired(kanban.BoardRetirementInput{BoardID: b.ID, Retired: true, ExpectedRevision: "absent", OperationID: b.ID}); err != nil {
			t.Fatal(err)
		}
	}
	first, err := s.Kanban.ListRetiredBoards(p.ID, "", "", 2)
	if err != nil || len(first.Boards) != 2 || first.NextID == "" {
		t.Fatalf("first: %+v %v", first, err)
	}
	second, err := s.Kanban.ListRetiredBoards(p.ID, first.NextID, first.Revision, 2)
	if err != nil || len(second.Boards) != 1 || second.NextID != "" || second.Boards[0].ID <= first.NextID {
		t.Fatalf("second: %+v %v", second, err)
	}
	b := first.Boards[0]
	if _, err := s.Kanban.SetBoardRetired(kanban.BoardRetirementInput{BoardID: b.ID, ExpectedRevision: b.RetirementRevision, OperationID: "restore-page"}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.ListRetiredBoards(p.ID, first.NextID, first.Revision, 2); !errors.Is(err, crdt.ErrConflict) {
		t.Fatalf("changed snapshot accepted: %v", err)
	}
}
