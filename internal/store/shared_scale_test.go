package store_test

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/replica"
	"github.com/dbpprt/dieter/internal/testkit"
)

// Run explicitly with DIETER_PEER_SCALE=1. This qualifies the complete persisted
// directory and incremental replication, without provisioning 10,000 Git trees
// or starting provider sessions.
func TestSharedScaleTenThousandItemsThreeReplicas(t *testing.T) {
	t.Parallel()
	if os.Getenv("DIETER_PEER_SCALE") != "1" {
		t.Skip("set DIETER_PEER_SCALE=1 for the 10,000-item qualification")
	}
	started := time.Now()
	a, b, c := testkit.PeerStore(t, "scale_a"), testkit.PeerStore(t, "scale_b"), testkit.PeerStore(t, "scale_c")
	p, err := a.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Scale", Path: testkit.ProjectDir(t), InitialBoardName: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	board, err := a.Kanban.InitialBoard(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	label, err := a.Kanban.CreateBoardLabel(board.ID, "Scale label", "#112233")
	if err != nil {
		t.Fatal(err)
	}
	identity, err := a.Replica.PeerIdentity()
	if err != nil {
		t.Fatal(err)
	}
	// This fixture deliberately builds a complete replica, including its initial
	// project/board/checkout records, before exercising operational paged joins.
	data, err := a.Replica.PeerData(identity.Account)
	if err != nil {
		t.Fatal(err)
	}
	data.State = replica.ClonePeerState(data.State)
	left := ""
	for i := 0; i < 10000; i++ {
		id := fmt.Sprintf("c_scale_%05d", i)
		next, e := replica.OrderBetween(left, "")
		if e != nil {
			t.Fatal(e)
		}
		left = next
		card := model.Card{ID: id, ProjectID: p.ID, BoardID: board.ID, Scope: model.ConversationScopeBoard, OwnerDaemonID: identity.DaemonID, CheckoutID: p.Checkouts[0].ID, Title: id, Lane: model.LaneTodo, OrderKey: next, CreatedAt: home.Timestamp()}
		fields := replica.PickFields(card, "item")
		fields["identity"] = replica.RawValue(map[string]any{"id": id, "projectId": p.ID, "ownerDaemonId": identity.DaemonID, "checkoutId": card.CheckoutID, "scope": "board", "createdAt": card.CreatedAt})
		fields["placement"] = replica.RawValue(map[string]any{"boardId": board.ID, "lane": "todo", "orderKey": next, "position": 0, "phaseChangedAt": card.CreatedAt})
		fields["summary"] = replica.RawValue(map[string]any{"runtime": "idle"})
		if err = replica.ApplyFields(&data, identity, "item", id, nil, fields); err != nil {
			t.Fatal(err)
		}
		if err = replica.ApplyFields(&data, identity, "assignment", id+"."+label.Labels[0].ID, nil, map[string]json.RawMessage{"membership": replica.RawValue(true)}); err != nil {
			t.Fatal(err)
		}
	}
	release, err := a.BeginWrite()
	if err != nil {
		t.Fatal(err)
	}
	err = a.Replica.SavePeerData(identity.Account, data)
	release()
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("create 10,000 item directory: %s, records=%d", time.Since(started), len(data.Records))
	for _, pair := range [][2]*store.Store{{a, b}, {b, c}, {c, a}} {
		source, target := pair[0], pair[1]
		targetIdentity, _ := target.Replica.PeerIdentity()
		var cursor replica.PeerCheckpoint
		var maximum time.Duration
		for {
			page, e := source.Replica.PeerChanges(identity.Account, cursor.Epoch, cursor.Sequence)
			if e != nil {
				t.Fatal(e)
			}
			pageStart := time.Now()
			if e = target.Replica.MergePeerRecords(targetIdentity, page.Records); e != nil {
				t.Fatal(e)
			}
			maximum = max(maximum, time.Since(pageStart))
			cursor = replica.PeerCheckpoint{Epoch: page.Epoch, Sequence: page.After}
			if !page.More {
				break
			}
		}
		t.Logf("replica %s caught up; maximum page write=%s, elapsed=%s", targetIdentity.DaemonID, maximum, time.Since(started))
	}
	expected := crdt.Revision(data.State)
	for _, replica := range []*store.Store{a, b, c} {
		restarted := store.New(replica.Root)
		identity, _ := restarted.Replica.PeerIdentity()
		projectionStart := time.Now()
		items, e := restarted.Kanban.ListCards(kanban.CardFilter{Project: p.ID, Board: board.ID})
		if e != nil || len(items) != 10000 {
			t.Fatalf("items=%d: %v", len(items), e)
		}
		recovered, e := restarted.Replica.PeerData(identity.Account)
		if e != nil || crdt.Revision(recovered.State) != expected {
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
