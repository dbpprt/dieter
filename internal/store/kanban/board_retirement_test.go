package kanban_test

import (
	"errors"
	"reflect"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/replica"
	"github.com/dbpprt/dieter/internal/testkit"
)

func lifecycleFixture(t *testing.T, s *store.Store) (model.Project, model.Board) {
	t.Helper()
	p, err := s.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Dieter", Path: testkit.ProjectDir(t), InitialBoardName: "Main", InitialWorkflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.Kanban.InitialBoard(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	return p, b
}

func TestBoardRetirementReceiptPersistenceAndRestore(t *testing.T) {
	t.Parallel()
	s := testkit.PeerStore(t, "owner")
	p, original := lifecycleFixture(t, s)
	duplicate, err := s.Kanban.CreateBoard(kanban.CreateBoardInput{Project: p.ID, Name: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	duplicate, err = s.Kanban.GetBoard(duplicate.ID)
	if err != nil {
		t.Fatal(err)
	}
	input := kanban.BoardRetirementInput{BoardID: duplicate.ID, Retired: true, ExpectedRevision: duplicate.RetirementRevision, OperationID: "retire-duplicate"}
	retired, err := s.Kanban.SetBoardRetired(input)
	if err != nil || !retired.Retired {
		t.Fatalf("retire: %+v %v", retired, err)
	}
	if _, err = s.Kanban.ResolveBoard(p.ID, duplicate.ID); !errors.Is(err, home.ErrNotFound) {
		t.Fatalf("retired active resolution: %v", err)
	}
	if _, err = s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: duplicate.ID, Title: "must fail"}); err == nil {
		t.Fatal("created on retired board")
	}
	state, err := s.Kanban.GlobalState()
	if err != nil || len(state.Boards) != 1 || state.Boards[0].ID != original.ID || state.Projects[0].BoardCount != 1 {
		t.Fatalf("state: %+v %v", state, err)
	}
	if page, err := s.Kanban.ListRetiredBoards(p.ID, "", "", 10); err != nil || len(page.Boards) != 1 || page.Boards[0].ID != duplicate.ID {
		t.Fatalf("retired boards: %+v %v", page, err)
	}
	reopened := store.New(s.Root)
	got, err := reopened.Kanban.SetBoardRetired(input)
	if err != nil || !reflect.DeepEqual(got.RetirementVersions, retired.RetirementVersions) {
		t.Fatalf("replay: %+v %v", got, err)
	}
	input.Retired = false
	if _, err := reopened.Kanban.SetBoardRetired(input); err == nil {
		t.Fatal("accepted changed replay input")
	}
	input.OperationID = "restore-stale"
	if _, err := reopened.Kanban.SetBoardRetired(input); !errors.Is(err, crdt.ErrConflict) {
		t.Fatalf("stale CAS: %v", err)
	}
	input.ExpectedRevision, input.OperationID = retired.RetirementRevision, "restore"
	restored, err := reopened.Kanban.SetBoardRetired(input)
	if err != nil || restored.Retired || restored.ID != duplicate.ID {
		t.Fatalf("restore: %+v %v", restored, err)
	}
	unchanged, err := reopened.Kanban.GetBoard(original.ID)
	if err != nil || !reflect.DeepEqual(unchanged, original) {
		t.Fatalf("original changed: %+v %v", unchanged, err)
	}
}

func TestBoardRetirementRefusesArchivedAndIncompleteReferences(t *testing.T) {
	t.Parallel()
	for _, archived := range []bool{false, true} {
		s := testkit.PeerStore(t, "owner")
		p, b := lifecycleFixture(t, s)
		card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, Title: "Keep", WorkspaceMode: "project"})
		if err != nil {
			t.Fatal(err)
		}
		if archived {
			if _, err := s.Kanban.ArchiveCard(card.ID, true); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := s.Kanban.SetBoardRetired(kanban.BoardRetirementInput{BoardID: b.ID, Retired: true, ExpectedRevision: b.RetirementRevision, OperationID: "retire"}); err == nil {
			t.Fatalf("archived=%v accepted referenced board", archived)
		}
	}
	s := testkit.PeerStore(t, "owner")
	_, b := lifecycleFixture(t, s)
	identity, _ := s.Replica.PeerIdentity()
	if _, err := s.Replica.PutPeerRecord(identity, "item", "pending.placement", "", replica.RawValue(map[string]string{"boardId": b.ID, "lane": "todo", "orderKey": "h"}), false); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.SetBoardRetired(kanban.BoardRetirementInput{BoardID: b.ID, Retired: true, ExpectedRevision: b.RetirementRevision, OperationID: "retire"}); err == nil {
		t.Fatal("incomplete item allowed retirement")
	}
}

func TestBoardRetirementConcurrentReferenceAndStaleIntent(t *testing.T) {
	t.Parallel()
	a, b, c := testkit.PeerStore(t, "a"), testkit.PeerStore(t, "b"), testkit.PeerStore(t, "c")
	p, board := lifecycleFixture(t, a)
	testkit.JoinPeers(t, a, b)
	testkit.JoinPeers(t, a, c)
	if _, err := b.Kanban.AttachCheckout(p.ID, testkit.ProjectDir(t), "B"); err != nil {
		t.Fatal(err)
	}
	retired, err := a.Kanban.SetBoardRetired(kanban.BoardRetirementInput{BoardID: board.ID, Retired: true, ExpectedRevision: board.RetirementRevision, OperationID: "retire"})
	if err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, a, c)
	card, err := b.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: board.ID, Title: "Offline draft", WorkspaceMode: "project"})
	if err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, b, a)
	testkit.JoinPeers(t, a, b)
	for _, s := range []*store.Store{a, b} {
		got, err := s.Kanban.ResolveBoard(p.ID, board.ID)
		if err != nil || got.Retired || !got.RetirementBlocked {
			t.Fatalf("late reference orphaned: %+v %v", got, err)
		}
		cards, err := s.Kanban.ListCards(kanban.CardFilter{Project: p.ID})
		if err != nil || len(cards) != 1 || cards[0].ID != card.ID || cards[0].OrderKey != card.OrderKey {
			t.Fatalf("card changed: %+v %v", cards, err)
		}
	}
	if _, err := a.Kanban.SetBoardRetired(kanban.BoardRetirementInput{BoardID: board.ID, Retired: false, ExpectedRevision: retired.RetirementRevision, OperationID: "restore"}); err != nil {
		t.Fatal(err)
	}
	testkit.JoinPeers(t, c, a)
	testkit.JoinPeers(t, a, c)
	testkit.JoinPeers(t, a, b)
	for _, s := range []*store.Store{a, b, c} {
		got, err := s.Kanban.GetBoard(board.ID)
		if err != nil || got.Retired || got.RetirementBlocked {
			t.Fatalf("stale retire won: %+v %v", got, err)
		}
	}
}

func TestBoardMissingParentAndStaleFieldTombstone(t *testing.T) {
	t.Parallel()
	a, b := testkit.PeerStore(t, "a"), testkit.PeerStore(t, "b")
	p, board := lifecycleFixture(t, a)
	card, err := a.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: board.ID, Title: "Keep", WorkspaceMode: "project"})
	if err != nil {
		t.Fatal(err)
	}
	identity, _ := b.Replica.PeerIdentity()
	data, _ := a.Replica.PeerData(identity.Account)
	var parents []crdt.Record
	for _, record := range data.Sorted() {
		if record.Kind == "board" {
			parents = append(parents, record)
			continue
		}
		if err := b.Replica.MergePeerRecords(identity, []crdt.Record{record}); err != nil {
			t.Fatal(err)
		}
	}
	if cards, err := b.Kanban.ListCards(kanban.CardFilter{Project: p.ID}); err != nil || len(cards) != 0 {
		t.Fatalf("missing parent projection: %+v %v", cards, err)
	}
	if err := b.Replica.MergePeerRecords(identity, parents); err != nil {
		t.Fatal(err)
	}
	if cards, err := b.Kanban.ListCards(kanban.CardFilter{Project: p.ID}); err != nil || len(cards) != 1 || cards[0].ID != card.ID {
		t.Fatalf("parent recovery: %+v %v", cards, err)
	}
	data, _ = b.Replica.PeerData(identity.Account)
	name := data.Records[crdt.Key("board", board.ID+".name")]
	deleted, err := b.Replica.PutPeerRecord(identity, "board", name.ID, name.Revision(), nil, true)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = b.Replica.PutPeerRecord(identity, "board", name.ID, deleted.Revision(), replica.RawValue("Main"), false); err != nil {
		t.Fatal(err)
	}
	if err = b.Replica.MergePeerRecords(identity, []crdt.Record{deleted}); err != nil {
		t.Fatal(err)
	}
	if _, err = b.Kanban.ResolveBoard(p.ID, board.ID); err != nil {
		t.Fatalf("stale tombstone hid restored board: %v", err)
	}
}
