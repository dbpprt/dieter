package store

import (
	"reflect"
	"sort"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/peerstore"
)

func TestCardStateFrontiersFollowIndependentCommitsAndReplicaJoin(t *testing.T) {
	owner, peer := peerFixture(t, "owner"), peerFixture(t, "peer")
	project, err := owner.CreateProject(CreateProjectInput{Name: "Test", Path: sharedRepo(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := owner.CreateBoard(CreateBoardInput{Project: project.ID, Name: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	card, err := owner.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, Title: "Task", Prompt: "private prompt", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	running, err := owner.UpdateCardCache(card.ID, CardCacheInput{Runtime: "running", Summary: "private summary"})
	if err != nil {
		t.Fatal(err)
	}
	joinStores(t, owner, peer)
	moved, err := peer.MoveCardBetween(card.ID, "done", "", "", running.PlacementRevision)
	if err != nil {
		t.Fatal(err)
	}
	idle, err := owner.UpdateCardCache(card.ID, CardCacheInput{Runtime: "idle"})
	if err != nil {
		t.Fatal(err)
	}
	field := func(card model.Card, name string) model.CardStateField {
		t.Helper()
		for _, f := range card.StateFields {
			if f.Name == name {
				return f
			}
		}
		t.Fatalf("missing %s frontier", name)
		return model.CardStateField{}
	}
	if field(moved, "summary").Revision != field(running, "summary").Revision || field(idle, "placement").Revision != field(running, "placement").Revision {
		t.Fatal("independent edits overwrote another register")
	}
	joinStores(t, peer, owner)
	joinStores(t, owner, peer)
	for _, replica := range []*Store{owner, peer} {
		result, err := replica.ResolveCard(card.ID)
		if err != nil {
			t.Fatal(err)
		}
		if result.Lane != "done" || result.Runtime != "idle" {
			t.Fatalf("regressed state: %+v", result)
		}
		if !reflect.DeepEqual(field(result, "placement"), field(moved, "placement")) || !reflect.DeepEqual(field(result, "summary"), field(idle, "summary")) {
			t.Fatal("projection lost the committed causal frontier")
		}
		for _, f := range result.StateFields {
			for _, v := range f.Versions {
				if len(v.Clock) == 0 || v.Rank == "" || v.Value.InitialPrompt != "" || v.Value.Summary != "" || len(v.Value.StateFields) > 0 {
					t.Fatalf("unbounded or private state projection: %+v", v)
				}
			}
		}
	}
	before := idle.RuntimeUpdatedAt
	metadata, err := owner.UpdateCardCache(card.ID, CardCacheInput{Model: "updated-model", Summary: "updated summary"})
	if err != nil {
		t.Fatal(err)
	}
	if metadata.RuntimeUpdatedAt != before {
		t.Fatal("metadata edit changed activity time")
	}
}

func TestConcurrentPlacementProjectionHasCanonicalFrontierAndUsableReceipt(t *testing.T) {
	owner, peer := peerFixture(t, "owner"), peerFixture(t, "peer")
	project, err := owner.CreateProject(CreateProjectInput{Name: "Test", Path: sharedRepo(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := owner.CreateBoard(CreateBoardInput{Project: project.ID, Name: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	card, err := owner.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, Title: "Task", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	joinStores(t, owner, peer)
	if _, err = owner.MoveCardBetween(card.ID, "review", "", "", card.PlacementRevision); err != nil {
		t.Fatal(err)
	}
	if _, err = peer.MoveCardBetween(card.ID, "done", "", "", card.PlacementRevision); err != nil {
		t.Fatal(err)
	}
	joinStores(t, owner, peer)
	joinStores(t, peer, owner)
	var first model.CardStateField
	for _, replica := range []*Store{owner, peer} {
		data, err := replica.PeerData("account")
		if err != nil {
			t.Fatal(err)
		}
		key := peerstore.Key("item", card.ID+".placement")
		record := data.Records[key]
		if len(record.Versions) != 2 {
			t.Fatalf("expected concurrent moves, got %d versions", len(record.Versions))
		}
		// Authentication proof hashes need not sort in presentation order.
		sort.Slice(record.Versions, func(i, j int) bool {
			return peerstore.PresentationRank(record.Versions[i]) > peerstore.PresentationRank(record.Versions[j])
		})
		data.Records[key] = record
		projected, ok, err := sharedCard(data, card.ID, card)
		if err != nil || !ok {
			t.Fatalf("projection failed: %v", err)
		}
		placement := projected.StateFields[0]
		if placement.Name != "placement" || placement.Versions[0].Rank >= placement.Versions[1].Rank {
			t.Fatal("frontier is not in canonical client join order")
		}
		if first.Name != "" && !reflect.DeepEqual(first, placement) {
			t.Fatal("replicas disagree on joined frontier or receipt")
		}
		first = placement
		if placement.Revision != projected.PlacementRevision {
			t.Fatal("frontier and placement receipts differ")
		}
		resolved, err := replica.MoveCardBetween(card.ID, "todo", "", "", placement.Revision)
		if err != nil || resolved.Lane != "todo" {
			t.Fatalf("joined receipt could not resolve concurrent moves: %v", err)
		}
	}
}
