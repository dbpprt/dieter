package kanban_test

import (
	"context"
	"errors"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/replica"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestDetachedCheckoutRemainsInSharedProjection(t *testing.T) {
	t.Parallel()
	a, b := testkit.PeerStore(t, "machine_a"), testkit.PeerStore(t, "machine_b")
	path := testkit.ProjectDir(t)
	project, err := a.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Repo", Path: path})
	if err != nil {
		t.Fatal(err)
	}
	checkout := project.Checkouts[0]
	testkit.JoinPeers(t, a, b)
	if err := a.Kanban.DetachCheckout(checkout.ID); err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, a, b)
	for _, replica := range []*store.Store{a, b} {
		value, err := replica.Kanban.ResolveProject(project.ID)
		if err != nil || len(value.Checkouts) != 1 || !value.Checkouts[0].Detached || value.Path != "" {
			t.Fatalf("missing detach projection: %+v %v", value, err)
		}
		active, err := replica.Kanban.ListCheckouts(project.ID)
		if err != nil || len(active) != 0 {
			t.Fatalf("detached checkout remained selectable: %+v %v", active, err)
		}
	}
	// Attaching the path again creates a fresh immutable registration.
	next, err := a.Kanban.AttachCheckout(project.ID, path, "Reattached")
	if err != nil || next.ID == checkout.ID {
		t.Fatalf("reattach: %+v %v", next, err)
	}
}

func TestSharedProjectThreeMachinesOfflineEditsAndOwnerIsolation(t *testing.T) {
	t.Parallel()
	a, b, c := testkit.PeerStore(t, "machine_a"), testkit.PeerStore(t, "machine_b"), testkit.PeerStore(t, "machine_c")
	p, err := a.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Repo", Path: testkit.ProjectDir(t), Prompt: "original"})
	if err != nil {
		t.Fatal(err)
	}
	board, err := a.Kanban.CreateBoard(kanban.CreateBoardInput{Project: p.ID, Name: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	card, err := a.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: board.ID, Title: "Owned by A", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, a, b)
	testkit.JoinPeers(t, a, c)
	checkoutB, err := b.Kanban.AttachCheckout(p.ID, testkit.ProjectDir(t), "B")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = b.Kanban.AttachCheckout(p.ID, checkoutB.Path, "again"); err != nil {
		t.Fatal(err)
	}
	localB, err := b.Kanban.CreateChat(kanban.CreateCardInput{Project: p.ID, Title: "Owned by B", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	if localB.OwnerDaemonID != "machine_b" || localB.CheckoutID != checkoutB.ID {
		t.Fatalf("owner: %#v", localB)
	}
	if _, err = b.Kanban.AcquireRuntimeLeaseFor(p.ID, board.ID, card.ID, "mock"); !errors.Is(err, kanban.ErrRemoteConversation) {
		t.Fatalf("remote execution: %v", err)
	}
	if _, err = b.Kanban.CardDetail(card.ID); !errors.Is(err, kanban.ErrRemoteConversation) {
		t.Fatalf("remote detail: %v", err)
	}
	name, summary := "New name", "A different field"
	if _, err = b.Kanban.UpdateProject(p.ID, &name, nil, nil); err != nil {
		t.Fatal(err)
	}
	if _, err = c.Kanban.UpdateProject(p.ID, nil, &summary, nil); err != nil {
		t.Fatal(err)
	}
	if _, err = b.Kanban.CreateBoardLabel(board.ID, "B label", "#112233"); err != nil {
		t.Fatal(err)
	}
	if _, err = c.Kanban.CreateBoardLabel(board.ID, "C label", "#445566"); err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, b, c)
	testkit.JoinPeers(t, c, b)
	testkit.JoinPeers(t, b, a)
	for _, s := range []*store.Store{a, b, c} {
		projects, err := s.Kanban.ListProjects()
		if err != nil || len(projects) != 1 {
			t.Fatalf("projects=%v err=%v", projects, err)
		}
		got := projects[0]
		if got.Name != name || got.Summary != summary || len(got.ConflictKeys) != 0 {
			t.Fatalf("merged fields: %#v", got)
		}
		boards, err := s.Kanban.ListBoards(p.ID)
		if err != nil || len(boards) != 1 || len(boards[0].Labels) != 2 {
			t.Fatalf("boards=%v err=%v", boards, err)
		}
		items, err := s.Kanban.ListCards(kanban.CardFilter{Project: p.ID, Scope: "all"})
		if err != nil {
			t.Fatal(err)
		}
		_ = items
	}
	promptB, promptC := "B prompt", "C prompt"
	if _, err = b.Kanban.UpdateProject(p.ID, nil, nil, &promptB); err != nil {
		t.Fatal(err)
	}
	if _, err = c.Kanban.UpdateProject(p.ID, nil, nil, &promptC); err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, b, c)
	got, err := c.Kanban.ResolveProject(p.ID)
	if err != nil || len(got.ConflictKeys) != 1 {
		t.Fatalf("conflict=%v err=%v", got.ConflictKeys, err)
	}
	thirdPrompt := "a new resolution requires a revision"
	if _, err = c.Kanban.UpdateProject(p.ID, nil, nil, &thirdPrompt); !errors.Is(err, crdt.ErrConflict) {
		t.Fatalf("silent conflict resolution: %v", err)
	}
	identity, _ := c.Replica.PeerIdentity()
	data, _ := c.Replica.PeerData(identity.Account)
	record := data.Records[got.ConflictKeys[0]]
	if _, err = c.Replica.PutPeerRecord(identity, record.Kind, record.ID, record.Revision(), replica.RawValue("resolved"), false); err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, c, a)
	resolved, _ := a.Kanban.ResolveProject(p.ID)
	if resolved.Prompt != "resolved" || len(resolved.ConflictKeys) != 0 {
		t.Fatalf("resolution: %#v", resolved)
	}
}

func TestFirstEnrollmentAdoptsLocalCheckoutAndConversation(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	p, err := s.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Repo", Path: testkit.ProjectDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	card, err := s.Kanban.CreateChat(kanban.CreateCardInput{Project: p.ID, Title: "Local", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Replica.BindPeerAccount("account", "subject", "machine_a", "https://gateway.test"); err != nil {
		t.Fatal(err)
	}
	got, err := s.Kanban.CardDetail(card.ID)
	if err != nil || got.Card.OwnerDaemonID != "machine_a" || got.Project.Path != p.Path {
		t.Fatalf("adoption: %#v %v", got, err)
	}
}

func TestSharedProjectCreationReceiptAndAtomicBoard(t *testing.T) {
	t.Parallel()
	s := testkit.PeerStore(t, "machine_a")
	input := kanban.CreateProjectInput{OperationID: "create-retry", Name: "Repo", Path: testkit.ProjectDir(t), InitialBoardName: "Main"}
	p, err := s.Kanban.CreateProject(input)
	if err != nil {
		t.Fatal(err)
	}
	again, err := s.Kanban.CreateProject(input)
	if err != nil || again.ID != p.ID {
		t.Fatalf("retry: %v %v", again, err)
	}
	boards, err := s.Kanban.ListBoards(p.ID)
	if err != nil || len(boards) != 1 || boards[0].RemotePublishMode != model.RemotePublishManual {
		t.Fatalf("boards: %v %v", boards, err)
	}
	if _, err = s.Kanban.InitialBoard(p.ID); err != nil {
		t.Fatal(err)
	}
	input.Name = "Different"
	if _, err = s.Kanban.CreateProject(input); err == nil {
		t.Fatal("operation ID accepted different input")
	}
}

func TestCreateProjectRestoresArchivedPathAndAddsMissingInitialBoard(t *testing.T) {
	t.Parallel()
	s := testkit.PeerStore(t, "machine_a")
	path := testkit.ProjectDir(t)
	original, err := s.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Repo", Path: path})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Kanban.ArchiveProject(original.ID, true); err != nil {
		t.Fatal(err)
	}

	restored, err := s.Kanban.CreateProject(kanban.CreateProjectInput{
		OperationID: "restore-archived-project", Name: "Ignored replacement", Path: path,
		InitialBoardName: "Main", InitialWorkflow: model.WorkflowReview,
	})
	if err != nil {
		t.Fatal(err)
	}
	if restored.ID != original.ID || restored.Archived || restored.Name != original.Name {
		t.Fatalf("restored=%#v original=%#v", restored, original)
	}
	boards, err := s.Kanban.ListBoards(original.ID)
	if err != nil || len(boards) != 1 || boards[0].Name != "Main" || boards[0].RemotePublishMode != model.RemotePublishManual {
		t.Fatalf("boards=%#v err=%v", boards, err)
	}

	again, err := s.Kanban.CreateProject(kanban.CreateProjectInput{
		OperationID: "restore-archived-project", Name: "Ignored replacement", Path: path,
		InitialBoardName: "Main", InitialWorkflow: model.WorkflowReview,
	})
	if err != nil || again.ID != original.ID {
		t.Fatalf("receipt retry=%#v err=%v", again, err)
	}
	boards, err = s.Kanban.ListBoards(original.ID)
	if err != nil || len(boards) != 1 {
		t.Fatalf("retry boards=%#v err=%v", boards, err)
	}
}

func TestCreateProjectRestoresArchivedPathWithoutDuplicatingExistingBoard(t *testing.T) {
	t.Parallel()
	s := testkit.PeerStore(t, "machine_a")
	path := testkit.ProjectDir(t)
	original, err := s.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Repo", Path: path})
	if err != nil {
		t.Fatal(err)
	}
	existing, err := s.Kanban.CreateBoard(kanban.CreateBoardInput{Project: original.ID, Name: "Existing", Workflow: model.WorkflowDirect})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Kanban.ArchiveProject(original.ID, true); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Kanban.CreateProject(kanban.CreateProjectInput{Path: path, InitialBoardName: "Main"}); err != nil {
		t.Fatal(err)
	}
	boards, err := s.Kanban.ListBoards(original.ID)
	if err != nil || len(boards) != 1 || boards[0].ID != existing.ID {
		t.Fatalf("boards=%#v err=%v", boards, err)
	}
}

func TestSharedConsolidationRetainsBoardsOwnersAndOfflineEdits(t *testing.T) {
	t.Parallel()
	a, b := testkit.PeerStore(t, "machine_a"), testkit.PeerStore(t, "machine_b")
	source, err := a.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Duplicate", Path: testkit.ProjectDir(t), InitialBoardName: "Source board"})
	if err != nil {
		t.Fatal(err)
	}
	destination, err := b.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Canonical", Path: testkit.ProjectDir(t), InitialBoardName: "Destination board"})
	if err != nil {
		t.Fatal(err)
	}
	board, err := a.Kanban.InitialBoard(source.ID)
	if err != nil {
		t.Fatal(err)
	}
	card, err := a.Kanban.CreateCard(kanban.CreateCardInput{Project: source.ID, Board: board.ID, Title: "Retained", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, a, b)
	testkit.JoinPeers(t, b, a)
	if _, err = b.Kanban.ConsolidateProject(source.ID, destination.ID); err != nil {
		t.Fatal(err)
	}
	renamed := "Offline old-project edit"
	if _, err = a.Kanban.UpdateProject(source.ID, &renamed, nil, nil); err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, a, b)
	testkit.JoinPeers(t, b, a)
	for _, s := range []*store.Store{a, b} {
		projects, err := s.Kanban.ListProjects()
		if err != nil || len(projects) != 1 || projects[0].ID != destination.ID || len(projects[0].Checkouts) != 2 {
			t.Fatalf("projects %v %v", projects, err)
		}
		boards, err := s.Kanban.ListBoards(destination.ID)
		if err != nil || len(boards) != 2 {
			t.Fatalf("boards %v %v", boards, err)
		}
	}
	detail, err := a.Kanban.CardDetail(card.ID)
	if err != nil || detail.Card.OwnerDaemonID != "machine_a" || detail.Project.ID != destination.ID || detail.Project.Path != source.Path {
		t.Fatalf("owner: %+v %v", detail, err)
	}
	if _, err = a.Kanban.RenameCard(card.ID, "Still editable"); err != nil {
		t.Fatal(err)
	}
	if _, err = b.Kanban.ConsolidateProject(source.ID, destination.ID); err != nil {
		t.Fatalf("retry: %v", err)
	}
}

func TestSharedMoveUsesStableNeighborsAndRejectsStaleRevision(t *testing.T) {
	t.Parallel()
	s := testkit.PeerStore(t, "machine_a")
	p, err := s.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Repo", Path: testkit.ProjectDir(t), InitialBoardName: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.Kanban.InitialBoard(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	var cards []model.Card
	for _, title := range []string{"Left", "Hidden", "Right", "Moved"} {
		card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, Title: title, Lane: "todo", WorkspaceMode: "project"})
		if err != nil {
			t.Fatal(err)
		}
		cards = append(cards, card)
	}
	moved, err := s.Kanban.ResolveCard(cards[3].ID)
	if err != nil {
		t.Fatal(err)
	}
	next, err := s.Kanban.MoveCardBetween(moved.ID, "todo", cards[0].ID, cards[2].ID, moved.PlacementRevision)
	if err != nil {
		t.Fatal(err)
	}
	if next.OrderKey <= cards[0].OrderKey || next.OrderKey >= cards[2].OrderKey {
		t.Fatal("move escaped visible neighbors")
	}
	if _, err = s.Kanban.MoveCardBetween(moved.ID, "done", "", "", moved.PlacementRevision); !errors.Is(err, crdt.ErrConflict) {
		t.Fatalf("stale move: %v", err)
	}
	hidden, err := s.Kanban.ResolveCard(cards[1].ID)
	if err != nil || hidden.OrderKey != cards[1].OrderKey {
		t.Fatal("hidden card was renumbered")
	}
}

func TestSharedWorkspaceDefaultsDoNotReplicateCheckoutCommands(t *testing.T) {
	t.Parallel()
	a, b := testkit.PeerStore(t, "a"), testkit.PeerStore(t, "b")
	commands := []model.ValidationCommand{{Name: "Test", Executable: "just", Arguments: []string{"test"}, Environment: map[string]string{"LOCAL_ONLY": "secret"}}}
	project, err := a.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Repo", Path: testkit.ProjectDir(t), ValidationCommands: commands})
	if err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, a, b)
	// B has no checkout. Portable settings must remain editable while A is offline.
	if _, err = b.Kanban.UpdateProjectWorkspaceSettings(project.ID, "origin", "main", nil); err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, b, a)
	for _, replica := range []*store.Store{a, b} {
		value, err := replica.Kanban.ResolveProject(project.ID)
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
	checkouts, err := a.Kanban.ListCheckouts(project.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = a.Kanban.UpdateProjectWorkspaceSettings(project.ID, "origin", "main", []model.ValidationCommand{}, checkouts[0].ID); err != nil {
		t.Fatal(err)
	}
	checkouts, err = a.Kanban.ListCheckouts(project.ID)
	if err != nil || len(checkouts[0].ValidationCommands) != 0 {
		t.Fatalf("clear validation: %+v %v", checkouts, err)
	}
}

func TestReplicaArchivesRemainExplicitWithOwnerOffline(t *testing.T) {
	t.Parallel()
	a, b := testkit.PeerStore(t, "a"), testkit.PeerStore(t, "b")
	project, err := a.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Repo", Path: testkit.ProjectDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	item, err := a.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "Owned by A"})
	if err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, a, b)
	if _, err = b.Kanban.ArchiveCard(item.ID, true); err != nil {
		t.Fatal(err)
	}
	state, err := b.Kanban.GlobalStateContext(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if archived, err := b.Kanban.ResolveCard(item.ID); err != nil || !archived.Archived || len(state.Chats) != 0 {
		t.Fatalf("archive projection: %+v %+v %v", state, archived, err)
	}
	if _, err = b.Kanban.ArchiveCard(item.ID, false); err != nil {
		t.Fatal(err)
	}
	state, err = b.Kanban.GlobalStateContext(context.Background())
	if err != nil || len(state.Chats) != 1 || state.Chats[0].ID != item.ID {
		t.Fatalf("restore projection: %+v %v", state, err)
	}
	if _, err = b.Kanban.ArchiveProject(project.ID, true); err != nil {
		t.Fatal(err)
	}
	state, err = b.Kanban.GlobalStateContext(context.Background())
	if err != nil || len(state.Projects) != 0 || len(state.Chats) != 0 {
		t.Fatalf("project archive: %+v %v", state, err)
	}
}
