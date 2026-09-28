package store

import (
	"errors"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/peerstore"
)

func lifecycleFixture(t *testing.T, s *Store) (model.Project, model.Board) {
	t.Helper()
	p, err := s.CreateProject(CreateProjectInput{Name: "Dieter", Path: sharedRepo(t), InitialBoardName: "Main", InitialWorkflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.InitialBoard(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	return p, b
}

func TestBoardRetirementReceiptPersistenceAndRestore(t *testing.T) {
	s := peerFixture(t, "owner")
	p, original := lifecycleFixture(t, s)
	duplicate, err := s.CreateBoard(CreateBoardInput{Project: p.ID, Name: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	duplicate, err = s.GetBoard(duplicate.ID)
	if err != nil {
		t.Fatal(err)
	}
	input := BoardRetirementInput{BoardID: duplicate.ID, Retired: true, ExpectedRevision: duplicate.RetirementRevision, OperationID: "retire-duplicate"}
	retired, err := s.SetBoardRetired(input)
	if err != nil || !retired.Retired {
		t.Fatalf("retire: %+v %v", retired, err)
	}
	if _, err = s.ResolveBoard(p.ID, duplicate.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("retired active resolution: %v", err)
	}
	if _, err = s.CreateCard(CreateCardInput{Project: p.ID, Board: duplicate.ID, Title: "must fail"}); err == nil {
		t.Fatal("created on retired board")
	}
	state, err := s.GlobalState()
	if err != nil || len(state.Boards) != 1 || state.Boards[0].ID != original.ID || state.Projects[0].BoardCount != 1 || len(state.RetiredBoards) != 1 {
		t.Fatalf("state: %+v %v", state, err)
	}
	reopened := New(s.Root)
	got, err := reopened.SetBoardRetired(input)
	if err != nil || !reflect.DeepEqual(got.RetirementVersions, retired.RetirementVersions) {
		t.Fatalf("replay: %+v %v", got, err)
	}
	input.Retired = false
	if _, err := reopened.SetBoardRetired(input); err == nil {
		t.Fatal("accepted changed replay input")
	}
	input.OperationID = "restore-stale"
	if _, err := reopened.SetBoardRetired(input); !errors.Is(err, peerstore.ErrConflict) {
		t.Fatalf("stale CAS: %v", err)
	}
	input.ExpectedRevision, input.OperationID = retired.RetirementRevision, "restore"
	restored, err := reopened.SetBoardRetired(input)
	if err != nil || restored.Retired || restored.ID != duplicate.ID {
		t.Fatalf("restore: %+v %v", restored, err)
	}
	unchanged, err := reopened.GetBoard(original.ID)
	if err != nil || !reflect.DeepEqual(unchanged, original) {
		t.Fatalf("original changed: %+v %v", unchanged, err)
	}
}

func TestBoardRetirementRefusesArchivedAndIncompleteReferences(t *testing.T) {
	for _, archived := range []bool{false, true} {
		s := peerFixture(t, "owner")
		p, b := lifecycleFixture(t, s)
		card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, Title: "Keep", WorkspaceMode: "project"})
		if err != nil {
			t.Fatal(err)
		}
		if archived {
			if _, err := s.ArchiveCard(card.ID, true); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := s.SetBoardRetired(BoardRetirementInput{BoardID: b.ID, Retired: true, ExpectedRevision: b.RetirementRevision, OperationID: "retire"}); err == nil {
			t.Fatalf("archived=%v accepted referenced board", archived)
		}
	}
	s := peerFixture(t, "owner")
	_, b := lifecycleFixture(t, s)
	identity, _ := s.PeerIdentity()
	if _, err := s.PutPeerRecord(identity, "item", "pending.placement", "", rawValue(map[string]string{"boardId": b.ID, "lane": "todo", "orderKey": "h"}), false); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetBoardRetired(BoardRetirementInput{BoardID: b.ID, Retired: true, ExpectedRevision: b.RetirementRevision, OperationID: "retire"}); err == nil {
		t.Fatal("incomplete item allowed retirement")
	}
}

func TestBoardRetirementConcurrentReferenceAndStaleIntent(t *testing.T) {
	a, b, c := peerFixture(t, "a"), peerFixture(t, "b"), peerFixture(t, "c")
	p, board := lifecycleFixture(t, a)
	joinStores(t, a, b)
	joinStores(t, a, c)
	if _, err := b.AttachCheckout(p.ID, sharedRepo(t), "B"); err != nil {
		t.Fatal(err)
	}
	retired, err := a.SetBoardRetired(BoardRetirementInput{BoardID: board.ID, Retired: true, ExpectedRevision: board.RetirementRevision, OperationID: "retire"})
	if err != nil {
		t.Fatal(err)
	}
	joinStores(t, a, c)
	card, err := b.CreateCard(CreateCardInput{Project: p.ID, Board: board.ID, Title: "Offline draft", WorkspaceMode: "project"})
	if err != nil {
		t.Fatal(err)
	}
	joinStores(t, b, a)
	joinStores(t, a, b)
	for _, s := range []*Store{a, b} {
		got, err := s.ResolveBoard(p.ID, board.ID)
		if err != nil || got.Retired || !got.RetirementBlocked {
			t.Fatalf("late reference orphaned: %+v %v", got, err)
		}
		cards, err := s.ListCards(CardFilter{Project: p.ID})
		if err != nil || len(cards) != 1 || cards[0].ID != card.ID || cards[0].OrderKey != card.OrderKey {
			t.Fatalf("card changed: %+v %v", cards, err)
		}
	}
	if _, err := a.SetBoardRetired(BoardRetirementInput{BoardID: board.ID, Retired: false, ExpectedRevision: retired.RetirementRevision, OperationID: "restore"}); err != nil {
		t.Fatal(err)
	}
	joinStores(t, c, a)
	joinStores(t, a, c)
	joinStores(t, a, b)
	for _, s := range []*Store{a, b, c} {
		got, err := s.GetBoard(board.ID)
		if err != nil || got.Retired || got.RetirementBlocked {
			t.Fatalf("stale retire won: %+v %v", got, err)
		}
	}
}

func TestBoardMissingParentAndStaleFieldTombstone(t *testing.T) {
	a, b := peerFixture(t, "a"), peerFixture(t, "b")
	p, board := lifecycleFixture(t, a)
	card, err := a.CreateCard(CreateCardInput{Project: p.ID, Board: board.ID, Title: "Keep", WorkspaceMode: "project"})
	if err != nil {
		t.Fatal(err)
	}
	identity, _ := b.PeerIdentity()
	data, _ := a.PeerData(identity.Account)
	var parents []peerstore.Record
	for _, record := range data.Sorted() {
		if record.Kind == "board" {
			parents = append(parents, record)
			continue
		}
		if err := b.MergePeerRecords(identity, []peerstore.Record{record}); err != nil {
			t.Fatal(err)
		}
	}
	if cards, err := b.ListCards(CardFilter{Project: p.ID}); err != nil || len(cards) != 0 {
		t.Fatalf("missing parent projection: %+v %v", cards, err)
	}
	if err := b.MergePeerRecords(identity, parents); err != nil {
		t.Fatal(err)
	}
	if cards, err := b.ListCards(CardFilter{Project: p.ID}); err != nil || len(cards) != 1 || cards[0].ID != card.ID {
		t.Fatalf("parent recovery: %+v %v", cards, err)
	}
	data, _ = b.PeerData(identity.Account)
	name := data.Records[peerstore.Key("board", board.ID+".name")]
	deleted, err := b.PutPeerRecord(identity, "board", name.ID, name.Revision(), nil, true)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = b.PutPeerRecord(identity, "board", name.ID, deleted.Revision(), rawValue("Main"), false); err != nil {
		t.Fatal(err)
	}
	if err = b.MergePeerRecords(identity, []peerstore.Record{deleted}); err != nil {
		t.Fatal(err)
	}
	if _, err = b.ResolveBoard(p.ID, board.ID); err != nil {
		t.Fatalf("stale tombstone hid restored board: %v", err)
	}
}

func TestSharedBoardLifecycleFixture(t *testing.T) {
	raw, err := os.ReadFile("../../tests/fixtures/board-lifecycle.tsv")
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
		if strings.HasPrefix(line, "#") {
			continue
		}
		columns := strings.Split(line, "\t")
		t.Run(columns[0], func(t *testing.T) {
			var record peerstore.Record
			for _, observation := range strings.Split(columns[1], ";") {
				if observation == "-" {
					continue
				}
				pair := strings.Split(observation, "=")
				clock := peerstore.Clock{}
				for _, entry := range strings.Split(pair[0], ",") {
					parts := strings.Split(entry, ":")
					clock[parts[0]], err = strconv.ParseUint(parts[1], 10, 64)
					if err != nil {
						t.Fatal(err)
					}
				}
				incoming := peerstore.Record{Kind: "board", ID: "b_fixture.retired", Versions: []peerstore.Version{{Clock: clock, Value: []byte(pair[1])}}}
				record, err = peerstore.Merge(record, incoming)
				if err != nil {
					t.Fatal(err)
				}
			}
			var refs []string
			if columns[2] == "true" {
				refs = []string{"item/card"}
			}
			board := model.Board{}
			projectBoardRetirement(&board, record, refs)
			if board.Retired != (columns[3] == "true") || board.RetirementBlocked != (columns[4] == "true") {
				t.Fatalf("projection: %+v", board)
			}
		})
	}
}

func TestBoardRetirementPausedScheduleAndPagination(t *testing.T) {
	s := peerFixture(t, "owner")
	p, board := lifecycleFixture(t, s)
	input := scheduleFixtureInput(p.ID, board.ID, "Paused")
	input.Enabled = false
	if _, err := s.CreateSchedule(input); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetBoardRetired(BoardRetirementInput{BoardID: board.ID, Retired: true, ExpectedRevision: board.RetirementRevision, OperationID: "refused"}); err == nil {
		t.Fatal("paused schedule allowed retirement")
	}
	for i := 0; i < 3; i++ {
		b, err := s.CreateBoard(CreateBoardInput{Project: p.ID, Name: "Empty"})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.SetBoardRetired(BoardRetirementInput{BoardID: b.ID, Retired: true, ExpectedRevision: "absent", OperationID: b.ID}); err != nil {
			t.Fatal(err)
		}
	}
	first, err := s.ListRetiredBoards(p.ID, "", "", 2)
	if err != nil || len(first.Boards) != 2 || first.NextID == "" {
		t.Fatalf("first: %+v %v", first, err)
	}
	second, err := s.ListRetiredBoards(p.ID, first.NextID, first.Revision, 2)
	if err != nil || len(second.Boards) != 1 || second.NextID != "" || second.Boards[0].ID <= first.NextID {
		t.Fatalf("second: %+v %v", second, err)
	}
	b := first.Boards[0]
	if _, err := s.SetBoardRetired(BoardRetirementInput{BoardID: b.ID, ExpectedRevision: b.RetirementRevision, OperationID: "restore-page"}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ListRetiredBoards(p.ID, first.NextID, first.Revision, 2); !errors.Is(err, peerstore.ErrConflict) {
		t.Fatalf("changed snapshot accepted: %v", err)
	}
}
