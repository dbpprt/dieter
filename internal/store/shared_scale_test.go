package store

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/peerstore"
)

// Run explicitly with DIETER_PEER_SCALE=1. This qualifies the complete persisted
// directory and incremental replication, without provisioning 10,000 Git trees
// or starting provider sessions.
func TestSharedScaleTenThousandItemsThreeReplicas(t *testing.T) {
	if os.Getenv("DIETER_PEER_SCALE") != "1" {
		t.Skip("set DIETER_PEER_SCALE=1 for the 10,000-item qualification")
	}
	started := time.Now()
	a, b, c := peerFixture(t, "scale_a"), peerFixture(t, "scale_b"), peerFixture(t, "scale_c")
	p, err := a.CreateProject(CreateProjectInput{Name: "Scale", Path: sharedRepo(t), InitialBoardName: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	board, err := a.InitialBoard(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	label, err := a.CreateBoardLabel(board.ID, "Scale label", "#112233")
	if err != nil {
		t.Fatal(err)
	}
	identity, data, err := a.sharedData()
	if err != nil {
		t.Fatal(err)
	}
	data.State = clonePeerState(data.State)
	left := ""
	for i := 0; i < 10000; i++ {
		id := fmt.Sprintf("c_scale_%05d", i)
		next, e := orderBetween(left, "")
		if e != nil {
			t.Fatal(e)
		}
		left = next
		card := model.Card{ID: id, ProjectID: p.ID, BoardID: board.ID, Scope: model.ConversationScopeBoard, OwnerDaemonID: identity.DaemonID, CheckoutID: p.Checkouts[0].ID, Title: id, Lane: model.LaneTodo, OrderKey: next, CreatedAt: timestamp()}
		fields := pickFields(card, "item")
		fields["identity"] = rawValue(map[string]any{"id": id, "projectId": p.ID, "ownerDaemonId": identity.DaemonID, "checkoutId": card.CheckoutID, "scope": "board", "createdAt": card.CreatedAt})
		fields["placement"] = rawValue(map[string]any{"boardId": board.ID, "lane": "todo", "orderKey": next, "position": 0, "phaseChangedAt": card.CreatedAt})
		fields["summary"] = rawValue(map[string]any{"runtime": "idle"})
		if err = applyFields(&data, identity, "item", id, nil, fields); err != nil {
			t.Fatal(err)
		}
		if err = applyFields(&data, identity, "assignment", id+"."+label.Labels[0].ID, nil, map[string]json.RawMessage{"membership": rawValue(true)}); err != nil {
			t.Fatal(err)
		}
	}
	release, err := a.beginWrite()
	if err != nil {
		t.Fatal(err)
	}
	err = a.savePeerData(identity.Account, data)
	release()
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("create 10,000 item directory: %s, records=%d", time.Since(started), len(data.Records))
	for _, pair := range [][2]*Store{{a, b}, {b, c}, {c, a}} {
		source, target := pair[0], pair[1]
		targetIdentity, _ := target.PeerIdentity()
		var cursor PeerCheckpoint
		var maximum time.Duration
		for {
			page, e := source.PeerChanges(identity.Account, cursor.Epoch, cursor.Sequence)
			if e != nil {
				t.Fatal(e)
			}
			pageStart := time.Now()
			if e = target.MergePeerRecords(targetIdentity, page.Records); e != nil {
				t.Fatal(e)
			}
			maximum = max(maximum, time.Since(pageStart))
			cursor = PeerCheckpoint{Epoch: page.Epoch, Sequence: page.After}
			if !page.More {
				break
			}
		}
		t.Logf("replica %s caught up; maximum page write=%s, elapsed=%s", targetIdentity.DaemonID, maximum, time.Since(started))
	}
	expected := peerstore.Revision(data.State)
	for _, replica := range []*Store{a, b, c} {
		restarted := New(replica.Root)
		identity, _ := restarted.PeerIdentity()
		projectionStart := time.Now()
		items, e := restarted.ListCards(CardFilter{Project: p.ID, Board: board.ID})
		if e != nil || len(items) != 10000 {
			t.Fatalf("items=%d: %v", len(items), e)
		}
		recovered, e := restarted.PeerData(identity.Account)
		if e != nil || peerstore.Revision(recovered.State) != expected {
			t.Fatalf("recovery mismatch: %v", e)
		}
		var disk int64
		_ = filepath.WalkDir(filepath.Join(replica.Root, "peers"), func(path string, d os.DirEntry, e error) error {
			if e == nil && !d.IsDir() {
				if info, e := d.Info(); e == nil {
					disk += info.Size()
				}
			}
			return e
		})
		t.Logf("replica %s: disk=%d bytes, recovery/projection=%s", identity.DaemonID, disk, time.Since(projectionStart))
	}
}
