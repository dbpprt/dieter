package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/peerstore"
)

func peerFixture(t *testing.T, id string) *Store {
	t.Helper()
	s := New(t.TempDir())
	if _, err := s.BindPeerAccount("account", "subject", id, "https://gateway.test"); err != nil {
		t.Fatal(err)
	}
	return s
}
func sharedRepo(t *testing.T) string {
	t.Helper()
	path := t.TempDir()
	if err := os.Mkdir(filepath.Join(path, ".git"), 0700); err != nil {
		t.Fatal(err)
	}
	return path
}
func joinStores(t *testing.T, from, to *Store) {
	t.Helper()
	identity, err := to.PeerIdentity()
	if err != nil {
		t.Fatal(err)
	}
	source, err := from.PeerData(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	records := source.Sorted()
	for len(records) > 0 {
		n := min(len(records), peerstore.PageSize)
		if err = to.MergePeerRecords(identity, records[:n]); err != nil {
			t.Fatal(err)
		}
		records = records[n:]
	}
}

func TestDetachedCheckoutRemainsInSharedProjection(t *testing.T) {
	a, b := peerFixture(t, "machine_a"), peerFixture(t, "machine_b")
	path := sharedRepo(t)
	project, err := a.CreateProject(CreateProjectInput{Name: "Repo", Path: path})
	if err != nil {
		t.Fatal(err)
	}
	checkout := project.Checkouts[0]
	joinStores(t, a, b)
	if err := a.DetachCheckout(checkout.ID); err != nil {
		t.Fatal(err)
	}
	joinStores(t, a, b)
	for _, replica := range []*Store{a, b} {
		value, err := replica.ResolveProject(project.ID)
		if err != nil || len(value.Checkouts) != 1 || !value.Checkouts[0].Detached || value.Path != "" {
			t.Fatalf("missing detach projection: %+v %v", value, err)
		}
		active, err := replica.ListCheckouts(project.ID)
		if err != nil || len(active) != 0 {
			t.Fatalf("detached checkout remained selectable: %+v %v", active, err)
		}
	}
	// Attaching the path again creates a fresh immutable registration.
	next, err := a.AttachCheckout(project.ID, path, "Reattached")
	if err != nil || next.ID == checkout.ID {
		t.Fatalf("reattach: %+v %v", next, err)
	}
}
func TestSharedProjectThreeMachinesOfflineEditsAndOwnerIsolation(t *testing.T) {
	a, b, c := peerFixture(t, "machine_a"), peerFixture(t, "machine_b"), peerFixture(t, "machine_c")
	p, err := a.CreateProject(CreateProjectInput{Name: "Repo", Path: sharedRepo(t), Prompt: "original"})
	if err != nil {
		t.Fatal(err)
	}
	board, err := a.CreateBoard(CreateBoardInput{Project: p.ID, Name: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	card, err := a.CreateCard(CreateCardInput{Project: p.ID, Board: board.ID, Title: "Owned by A", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	joinStores(t, a, b)
	joinStores(t, a, c)
	checkoutB, err := b.AttachCheckout(p.ID, sharedRepo(t), "B")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = b.AttachCheckout(p.ID, checkoutB.Path, "again"); err != nil {
		t.Fatal(err)
	}
	localB, err := b.CreateChat(CreateCardInput{Project: p.ID, Title: "Owned by B", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	if localB.OwnerDaemonID != "machine_b" || localB.CheckoutID != checkoutB.ID {
		t.Fatalf("owner: %#v", localB)
	}
	if _, err = b.AcquireRuntimeLeaseFor(p.ID, board.ID, card.ID, "mock"); !errors.Is(err, ErrRemoteConversation) {
		t.Fatalf("remote execution: %v", err)
	}
	if _, err = b.CardDetail(card.ID); !errors.Is(err, ErrRemoteConversation) {
		t.Fatalf("remote detail: %v", err)
	}
	name, summary := "New name", "A different field"
	if _, err = b.UpdateProject(p.ID, &name, nil, nil); err != nil {
		t.Fatal(err)
	}
	if _, err = c.UpdateProject(p.ID, nil, &summary, nil); err != nil {
		t.Fatal(err)
	}
	if _, err = b.CreateBoardLabel(board.ID, "B label", "#112233"); err != nil {
		t.Fatal(err)
	}
	if _, err = c.CreateBoardLabel(board.ID, "C label", "#445566"); err != nil {
		t.Fatal(err)
	}
	joinStores(t, b, c)
	joinStores(t, c, b)
	joinStores(t, b, a)
	for _, s := range []*Store{a, b, c} {
		projects, err := s.ListProjects()
		if err != nil || len(projects) != 1 {
			t.Fatalf("projects=%v err=%v", projects, err)
		}
		got := projects[0]
		if got.Name != name || got.Summary != summary || len(got.ConflictKeys) != 0 {
			t.Fatalf("merged fields: %#v", got)
		}
		boards, err := s.ListBoards(p.ID)
		if err != nil || len(boards) != 1 || len(boards[0].Labels) != 2 {
			t.Fatalf("boards=%v err=%v", boards, err)
		}
		items, err := s.ListCards(CardFilter{Project: p.ID, Scope: "all"})
		if err != nil {
			t.Fatal(err)
		}
		_ = items
	}
	promptB, promptC := "B prompt", "C prompt"
	if _, err = b.UpdateProject(p.ID, nil, nil, &promptB); err != nil {
		t.Fatal(err)
	}
	if _, err = c.UpdateProject(p.ID, nil, nil, &promptC); err != nil {
		t.Fatal(err)
	}
	joinStores(t, b, c)
	got, err := c.ResolveProject(p.ID)
	if err != nil || len(got.ConflictKeys) != 1 {
		t.Fatalf("conflict=%v err=%v", got.ConflictKeys, err)
	}
	thirdPrompt := "a new resolution requires a revision"
	if _, err = c.UpdateProject(p.ID, nil, nil, &thirdPrompt); !errors.Is(err, peerstore.ErrConflict) {
		t.Fatalf("silent conflict resolution: %v", err)
	}
	identity, _ := c.PeerIdentity()
	data, _ := c.PeerData(identity.Account)
	record := data.Records[got.ConflictKeys[0]]
	if _, err = c.PutPeerRecord(identity, record.Kind, record.ID, record.Revision(), rawValue("resolved"), false); err != nil {
		t.Fatal(err)
	}
	joinStores(t, c, a)
	resolved, _ := a.ResolveProject(p.ID)
	if resolved.Prompt != "resolved" || len(resolved.ConflictKeys) != 0 {
		t.Fatalf("resolution: %#v", resolved)
	}
}
func TestSharedOrderingConcurrentInsertionsRemainAddressable(t *testing.T) {
	first, err := orderBetween("", "")
	if err != nil {
		t.Fatal(err)
	}
	second, err := orderBetween("", "")
	if err != nil {
		t.Fatal(err)
	}
	if first == second {
		t.Fatal("concurrent positions collide")
	}
	if first > second {
		first, second = second, first
	}
	middle, err := orderBetween(first, second)
	if err != nil || !(first < middle && middle < second) {
		t.Fatalf("%q < %q < %q: %v", first, middle, second, err)
	}
	for i := 0; i < 100; i++ {
		next, err := orderBetween(first, middle)
		if err != nil || !(first < next && next < middle) {
			t.Fatal(err)
		}
		middle = next
	}
}
func TestFirstEnrollmentAdoptsLocalCheckoutAndConversation(t *testing.T) {
	s := New(t.TempDir())
	p, err := s.CreateProject(CreateProjectInput{Name: "Repo", Path: sharedRepo(t)})
	if err != nil {
		t.Fatal(err)
	}
	card, err := s.CreateChat(CreateCardInput{Project: p.ID, Title: "Local", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.BindPeerAccount("account", "subject", "machine_a", "https://gateway.test"); err != nil {
		t.Fatal(err)
	}
	got, err := s.CardDetail(card.ID)
	if err != nil || got.Card.OwnerDaemonID != "machine_a" || got.Project.Path != p.Path {
		t.Fatalf("adoption: %#v %v", got, err)
	}
}

func TestSharedProjectCreationReceiptAndAtomicBoard(t *testing.T) {
	s := peerFixture(t, "machine_a")
	input := CreateProjectInput{OperationID: "create-retry", Name: "Repo", Path: sharedRepo(t), InitialBoardName: "Main"}
	p, err := s.CreateProject(input)
	if err != nil {
		t.Fatal(err)
	}
	again, err := s.CreateProject(input)
	if err != nil || again.ID != p.ID {
		t.Fatalf("retry: %v %v", again, err)
	}
	boards, err := s.ListBoards(p.ID)
	if err != nil || len(boards) != 1 {
		t.Fatalf("boards: %v %v", boards, err)
	}
	if _, err = s.InitialBoard(p.ID); err != nil {
		t.Fatal(err)
	}
	input.Name = "Different"
	if _, err = s.CreateProject(input); err == nil {
		t.Fatal("operation ID accepted different input")
	}
}

func TestCreateProjectRestoresArchivedPathAndAddsMissingInitialBoard(t *testing.T) {
	s := peerFixture(t, "machine_a")
	path := sharedRepo(t)
	original, err := s.CreateProject(CreateProjectInput{Name: "Repo", Path: path})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.ArchiveProject(original.ID, true); err != nil {
		t.Fatal(err)
	}

	restored, err := s.CreateProject(CreateProjectInput{
		OperationID: "restore-archived-project", Name: "Ignored replacement", Path: path,
		InitialBoardName: "Main", InitialWorkflow: model.WorkflowReview,
	})
	if err != nil {
		t.Fatal(err)
	}
	if restored.ID != original.ID || restored.Archived || restored.Name != original.Name {
		t.Fatalf("restored=%#v original=%#v", restored, original)
	}
	boards, err := s.ListBoards(original.ID)
	if err != nil || len(boards) != 1 || boards[0].Name != "Main" {
		t.Fatalf("boards=%#v err=%v", boards, err)
	}

	again, err := s.CreateProject(CreateProjectInput{
		OperationID: "restore-archived-project", Name: "Ignored replacement", Path: path,
		InitialBoardName: "Main", InitialWorkflow: model.WorkflowReview,
	})
	if err != nil || again.ID != original.ID {
		t.Fatalf("receipt retry=%#v err=%v", again, err)
	}
	boards, err = s.ListBoards(original.ID)
	if err != nil || len(boards) != 1 {
		t.Fatalf("retry boards=%#v err=%v", boards, err)
	}
}

func TestCreateProjectRestoresArchivedPathWithoutDuplicatingExistingBoard(t *testing.T) {
	s := peerFixture(t, "machine_a")
	path := sharedRepo(t)
	original, err := s.CreateProject(CreateProjectInput{Name: "Repo", Path: path})
	if err != nil {
		t.Fatal(err)
	}
	existing, err := s.CreateBoard(CreateBoardInput{Project: original.ID, Name: "Existing", Workflow: model.WorkflowDirect})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.ArchiveProject(original.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err = s.CreateProject(CreateProjectInput{Path: path, InitialBoardName: "Main"}); err != nil {
		t.Fatal(err)
	}
	boards, err := s.ListBoards(original.ID)
	if err != nil || len(boards) != 1 || boards[0].ID != existing.ID {
		t.Fatalf("boards=%#v err=%v", boards, err)
	}
}

func TestSharedEffectsRecoveryDoesNotReplayOldMetadata(t *testing.T) {
	s := peerFixture(t, "machine_a")
	p, err := s.CreateProject(CreateProjectInput{Name: "Repo", Path: sharedRepo(t)})
	if err != nil {
		t.Fatal(err)
	}
	card, err := s.CreateChat(CreateCardInput{Project: p.ID, Title: "Before", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	identity, _ := s.PeerIdentity()
	db, err := s.peerDatabase(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	// Simulate a crash after committing metadata and before applying a file effect.
	if _, err = db.Exec("INSERT INTO peer_effects(path,value,remove_file) VALUES(?,?,0)", "receipts/recovered.json", []byte(`{"durable":true}`)); err != nil {
		t.Fatal(err)
	}
	reopened := New(s.Root)
	if _, err = reopened.RenameCard(card.ID, "After"); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Stat(filepath.Join(s.Root, "receipts/recovered.json")); err != nil {
		t.Fatal(err)
	}
	got, err := reopened.ResolveCard(card.ID)
	if err != nil || got.Title != "After" {
		t.Fatalf("%v %v", got, err)
	}
	var count int
	if err = db.QueryRow("SELECT COUNT(*) FROM peer_effects").Scan(&count); err != nil || count != 0 {
		t.Fatalf("effects=%d %v", count, err)
	}
}

func TestSharedAccountSwitchHidesConversationAndLocalFiles(t *testing.T) {
	s := peerFixture(t, "machine_a")
	p, err := s.CreateProject(CreateProjectInput{Name: "Private", Path: sharedRepo(t)})
	if err != nil {
		t.Fatal(err)
	}
	card, err := s.CreateChat(CreateCardInput{Project: p.ID, Title: "Private conversation", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.BindPeerAccount("other-account", "other-subject", "machine_new", "https://gateway.test"); err != nil {
		t.Fatal(err)
	}
	if _, err = s.ResolveCard(card.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("leaked directory: %v", err)
	}
	if _, err = s.ConversationByID(card.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("leaked conversation: %v", err)
	}
	if projects, err := s.ListProjects(); err != nil || len(projects) != 0 {
		t.Fatalf("leaked projects %v %v", projects, err)
	}
}

func TestSharedOrderingTenThousandEndInsertions(t *testing.T) {
	left := ""
	for i := 0; i < 10000; i++ {
		next, err := orderBetween(left, "")
		if err != nil || next <= left || len(next) > 32 {
			t.Fatalf("append %d %q: %v", i, next, err)
		}
		left = next
	}
}

func TestSharedConsolidationRetainsBoardsOwnersAndOfflineEdits(t *testing.T) {
	a, b := peerFixture(t, "machine_a"), peerFixture(t, "machine_b")
	source, err := a.CreateProject(CreateProjectInput{Name: "Duplicate", Path: sharedRepo(t), InitialBoardName: "Source board"})
	if err != nil {
		t.Fatal(err)
	}
	destination, err := b.CreateProject(CreateProjectInput{Name: "Canonical", Path: sharedRepo(t), InitialBoardName: "Destination board"})
	if err != nil {
		t.Fatal(err)
	}
	board, err := a.InitialBoard(source.ID)
	if err != nil {
		t.Fatal(err)
	}
	card, err := a.CreateCard(CreateCardInput{Project: source.ID, Board: board.ID, Title: "Retained", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	joinStores(t, a, b)
	joinStores(t, b, a)
	if _, err = b.ConsolidateProject(source.ID, destination.ID); err != nil {
		t.Fatal(err)
	}
	renamed := "Offline old-project edit"
	if _, err = a.UpdateProject(source.ID, &renamed, nil, nil); err != nil {
		t.Fatal(err)
	}
	joinStores(t, a, b)
	joinStores(t, b, a)
	for _, s := range []*Store{a, b} {
		projects, err := s.ListProjects()
		if err != nil || len(projects) != 1 || projects[0].ID != destination.ID || len(projects[0].Checkouts) != 2 {
			t.Fatalf("projects %v %v", projects, err)
		}
		boards, err := s.ListBoards(destination.ID)
		if err != nil || len(boards) != 2 {
			t.Fatalf("boards %v %v", boards, err)
		}
	}
	detail, err := a.CardDetail(card.ID)
	if err != nil || detail.Card.OwnerDaemonID != "machine_a" || detail.Project.ID != destination.ID || detail.Project.Path != source.Path {
		t.Fatalf("owner: %+v %v", detail, err)
	}
	if _, err = a.RenameCard(card.ID, "Still editable"); err != nil {
		t.Fatal(err)
	}
	if _, err = b.ConsolidateProject(source.ID, destination.ID); err != nil {
		t.Fatalf("retry: %v", err)
	}
}

func TestSharedMoveUsesStableNeighborsAndRejectsStaleRevision(t *testing.T) {
	s := peerFixture(t, "machine_a")
	p, err := s.CreateProject(CreateProjectInput{Name: "Repo", Path: sharedRepo(t), InitialBoardName: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.InitialBoard(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	var cards []model.Card
	for _, title := range []string{"Left", "Hidden", "Right", "Moved"} {
		card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, Title: title, Lane: "todo", WorkspaceMode: "project"})
		if err != nil {
			t.Fatal(err)
		}
		cards = append(cards, card)
	}
	moved, err := s.ResolveCard(cards[3].ID)
	if err != nil {
		t.Fatal(err)
	}
	next, err := s.MoveCardBetween(moved.ID, "todo", cards[0].ID, cards[2].ID, moved.PlacementRevision)
	if err != nil {
		t.Fatal(err)
	}
	if next.OrderKey <= cards[0].OrderKey || next.OrderKey >= cards[2].OrderKey {
		t.Fatal("move escaped visible neighbors")
	}
	if _, err = s.MoveCardBetween(moved.ID, "done", "", "", moved.PlacementRevision); !errors.Is(err, peerstore.ErrConflict) {
		t.Fatalf("stale move: %v", err)
	}
	hidden, err := s.ResolveCard(cards[1].ID)
	if err != nil || hidden.OrderKey != cards[1].OrderKey {
		t.Fatal("hidden card was renumbered")
	}
}

func TestScheduleHistoryCannotCrossAccountSwitch(t *testing.T) {
	s := peerFixture(t, "machine_a")
	p, err := s.CreateProject(CreateProjectInput{Name: "Repo", Path: sharedRepo(t), InitialBoardName: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.InitialBoard(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	schedule, err := s.CreateSchedule(ScheduleInput{Project: p.ID, Board: b.ID, Name: "Daily", Cron: "0 9 * * *", Timezone: "UTC", TitleTemplate: "Daily", PromptTemplate: "Check", Provider: "codex", Model: "gpt-5", WorkspaceMode: "project"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.BindPeerAccount("other-account", "other", "machine_b", "https://gateway.test"); err != nil {
		t.Fatal(err)
	}
	if _, err = s.ListScheduleRunsPage(schedule.ID, 10, ""); !errors.Is(err, ErrNotFound) {
		t.Fatalf("history leaked: %v", err)
	}
	items, err := s.ListSchedules("")
	if err != nil || len(items) != 0 {
		t.Fatalf("definitions leaked: %v %v", items, err)
	}
}

func TestSharedWorkspaceDefaultsDoNotReplicateCheckoutCommands(t *testing.T) {
	a, b := peerFixture(t, "a"), peerFixture(t, "b")
	commands := []model.ValidationCommand{{Name: "Test", Executable: "just", Arguments: []string{"test"}, Environment: map[string]string{"LOCAL_ONLY": "secret"}}}
	project, err := a.CreateProject(CreateProjectInput{Name: "Repo", Path: sharedRepo(t), ValidationCommands: commands})
	if err != nil {
		t.Fatal(err)
	}
	joinStores(t, a, b)
	// B has no checkout. Portable settings must remain editable while A is offline.
	if _, err = b.UpdateProjectWorkspaceSettings(project.ID, "origin", "main", nil); err != nil {
		t.Fatal(err)
	}
	joinStores(t, b, a)
	for _, replica := range []*Store{a, b} {
		value, err := replica.ResolveProject(project.ID)
		if err != nil {
			t.Fatal(err)
		}
		if value.BaseBranch != "main" {
			t.Fatalf("shared defaults: %+v", value)
		}
		checkout := value.Checkouts[0]
		if replica == a {
			if len(checkout.ValidationCommands) != 1 || checkout.ValidationCommands[0].Environment["LOCAL_ONLY"] != "secret" {
				t.Fatalf("owner settings lost: %+v", checkout)
			}
		} else if checkout.Path != "" || len(checkout.ValidationCommands) != 0 {
			t.Fatalf("local settings leaked: %+v", checkout)
		}
	}
	checkouts, err := a.ListCheckouts(project.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = a.UpdateProjectWorkspaceSettings(project.ID, "origin", "main", []model.ValidationCommand{}, checkouts[0].ID); err != nil {
		t.Fatal(err)
	}
	checkouts, err = a.ListCheckouts(project.ID)
	if err != nil || len(checkouts[0].ValidationCommands) != 0 {
		t.Fatalf("clear validation: %+v %v", checkouts, err)
	}
}

func TestReplicaArchivesRemainExplicitWithOwnerOffline(t *testing.T) {
	a, b := peerFixture(t, "a"), peerFixture(t, "b")
	project, err := a.CreateProject(CreateProjectInput{Name: "Repo", Path: sharedRepo(t)})
	if err != nil {
		t.Fatal(err)
	}
	item, err := a.CreateChat(CreateCardInput{Project: project.ID, Title: "Owned by A"})
	if err != nil {
		t.Fatal(err)
	}
	joinStores(t, a, b)
	if _, err = b.ArchiveCard(item.ID, true); err != nil {
		t.Fatal(err)
	}
	state, _, err := b.GlobalStateContext(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(state.ArchivedItemIDs) != 1 || state.ArchivedItemIDs[0] != item.ID || len(state.Chats) != 0 {
		t.Fatalf("archive projection: %+v", state)
	}
	if _, err = b.ArchiveCard(item.ID, false); err != nil {
		t.Fatal(err)
	}
	state, _, err = b.GlobalStateContext(context.Background())
	if err != nil || len(state.ArchivedItemIDs) != 0 || len(state.Chats) != 1 {
		t.Fatalf("restore projection: %+v %v", state, err)
	}
	if _, err = b.ArchiveProject(project.ID, true); err != nil {
		t.Fatal(err)
	}
	state, _, err = b.GlobalStateContext(context.Background())
	if err != nil || len(state.ArchivedProjectIDs) != 1 || len(state.Projects) != 0 {
		t.Fatalf("project archive: %+v %v", state, err)
	}
}

func TestPeerWakeCoalescesCommittedChangesOnly(t *testing.T) {
	s := peerFixture(t, "a")
	wake := s.PeerChangesAvailable()
	project, err := s.CreateProject(CreateProjectInput{Name: "Repo", Path: sharedRepo(t)})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-wake:
	default:
		t.Fatal("commit did not wake replication")
	}
	name := "Renamed"
	for i := 0; i < 3; i++ {
		if _, err = s.UpdateProject(project.ID, &name, nil, nil); err != nil {
			t.Fatal(err)
		}
	}
	select {
	case <-wake:
	default:
		t.Fatal("edit did not wake replication")
	}
	select {
	case <-wake:
		t.Fatal("wakeup queue did not coalesce")
	default:
	}
}
