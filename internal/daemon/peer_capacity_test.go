package daemon

import (
	"context"
	"errors"
	"fmt"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/peerstore"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

// One record per page makes the round budget deterministic without a large
// fixture. The transport contract permits any nonempty bounded page size.
type retainedPeerClient struct {
	dieterv1.DieterServiceClient
	epoch         string
	records       []peerstore.Record
	pulls, pushes int
	received      map[string]peerstore.Record
	failPush      bool
}

func (c *retainedPeerClient) GetPeerStoreStatus(context.Context, *emptypb.Empty, ...grpc.CallOption) (*dieterv1.PeerStoreStatus, error) {
	return &dieterv1.PeerStoreStatus{Account: "account", Actor: "remote"}, nil
}
func (c *retainedPeerClient) GetPeerChanges(_ context.Context, r *dieterv1.PeerChangesRequest, _ ...grpc.CallOption) (*dieterv1.PeerChangesResponse, error) {
	c.pulls++
	if r.GetEpoch() != "" && r.GetEpoch() != c.epoch {
		return nil, status.Error(codes.Aborted, "replica replaced")
	}
	next := r.GetAfterSequence()
	out := &dieterv1.PeerChangesResponse{Epoch: c.epoch, AfterSequence: next}
	if next >= uint64(len(c.records)) {
		return out, nil
	}
	item := c.records[next]
	record := &dieterv1.PeerRecord{Kind: item.Kind, Id: item.ID}
	for _, v := range item.Versions {
		record.Versions = append(record.Versions, &dieterv1.PeerVersion{Clock: v.Clock, ValueJson: v.Value, Deleted: v.Deleted, ProvenanceJson: v.Provenance})
	}
	out.Records = []*dieterv1.PeerRecord{record}
	out.AfterSequence++
	out.More = out.AfterSequence < uint64(len(c.records))
	return out, nil
}
func (c *retainedPeerClient) MergePeerRecords(_ context.Context, r *dieterv1.MergePeerRecordsRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	for _, p := range r.GetRecords() {
		key := peerstore.Key(p.Kind, p.Id)
		incoming := peerstore.Record{Kind: p.Kind, ID: p.Id}
		for _, v := range p.Versions {
			incoming.Versions = append(incoming.Versions, peerstore.Version{Clock: v.Clock, Value: v.ValueJson, Deleted: v.Deleted, Provenance: v.ProvenanceJson})
		}
		joined, err := peerstore.Merge(c.received[key], incoming)
		if err != nil {
			return nil, err
		}
		c.received[key] = joined
	}
	c.pushes++
	if c.failPush {
		return nil, status.Error(codes.Unavailable, "reply lost after commit")
	}
	return &emptypb.Empty{}, nil
}
func TestPeerCatchUpRoundsAreBoundedAndResume(t *testing.T) {
	s := store.New(t.TempDir())
	defer s.Close()
	binding, err := s.BindPeerAccount("account", "github:1", "local", "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	remote := &retainedPeerClient{epoch: "epoch_1", received: map[string]peerstore.Record{}}
	for i := 0; i < peerExchangePages+1; i++ {
		r, err := peerstore.Put(peerstore.Record{}, "kv.retained", fmt.Sprintf("id_%03d", i), "remote_actor", "", []byte(`true`), false)
		if err != nil {
			t.Fatal(err)
		}
		remote.records = append(remote.records, r)
	}
	syncer := &PeerSync{Store: s}
	err = syncer.Exchange(t.Context(), binding, remote)
	if !errors.Is(err, ErrPeerCatchUp) || remote.pulls != peerExchangePages {
		t.Fatalf("round budget: calls=%d err=%v", remote.pulls, err)
	}
	diagnostics, err := s.PeerSyncDiagnostics(binding.Account)
	if err != nil || len(diagnostics) != 1 || diagnostics[0].Direction != "catchup" || diagnostics[0].LastSuccessAt != "" || diagnostics[0].FailureCode != "" {
		t.Fatalf("incomplete exchange marked complete/failed: %+v %v", diagnostics, err)
	}
	// A fresh store/worker resumes its persisted cursor.
	syncer.Store = store.New(s.Root)
	defer syncer.Store.Close()
	if err = syncer.Exchange(t.Context(), binding, remote); err != nil {
		t.Fatal(err)
	}
	if remote.pulls != peerExchangePages+1 || len(remote.received) != peerExchangePages+1 {
		t.Fatalf("did not resume: pulls=%d records=%d", remote.pulls, len(remote.received))
	}
	diagnostics, err = s.PeerSyncDiagnostics(binding.Account)
	if err != nil || diagnostics[0].Direction != "complete" || diagnostics[0].LastSuccessAt == "" {
		t.Fatalf("missing completed exchange: %+v %v", diagnostics, err)
	}
}
func TestPeerReplacedReplicaReceivesRetainedDeletesAndLostReplyReplay(t *testing.T) {
	s := store.New(t.TempDir())
	defer s.Close()
	binding, err := s.BindPeerAccount("account", "github:1", "local", "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	original, err := s.PutPeerRecord(binding, "kv.retained", "deleted", "", []byte(`true`), false)
	if err != nil {
		t.Fatal(err)
	}
	deleted, err := s.PutPeerRecord(binding, original.Kind, original.ID, original.Revision(), nil, true)
	if err != nil {
		t.Fatal(err)
	}
	remote := &retainedPeerClient{epoch: "epoch_1", received: map[string]peerstore.Record{}, failPush: true}
	syncer := &PeerSync{Store: s}
	if err = syncer.Exchange(t.Context(), binding, remote); status.Code(err) != codes.Unavailable {
		t.Fatalf("lost reply: %v", err)
	}
	checkpoint, err := s.PeerCheckpoint(binding.Account, "remote", "push")
	if err != nil || checkpoint.Sequence != 0 {
		t.Fatalf("uncertain reply advanced cursor: %+v %v", checkpoint, err)
	}
	remote.failPush = false
	if err = syncer.Exchange(t.Context(), binding, remote); err != nil {
		t.Fatal(err)
	}
	if remote.received["kv.retained/deleted"].Revision() != deleted.Revision() {
		t.Fatal("retry lost tombstone")
	}
	// Simulate a new receiving replica, retaining the same transport actor. Its
	// empty pull page must reset the prior push receipt too.
	remote.epoch = "epoch_2"
	remote.received = map[string]peerstore.Record{}
	if err = syncer.Exchange(t.Context(), binding, remote); err != nil {
		t.Fatal(err)
	}
	if remote.received["kv.retained/deleted"].Revision() != deleted.Revision() {
		t.Fatal("old push cursor skipped a replaced receiver")
	}
	checkpoint, err = s.PeerCheckpoint(binding.Account, "remote", "push")
	if err != nil || checkpoint.RemoteEpoch != "epoch_2" {
		t.Fatalf("push incarnation not durable: %+v %v", checkpoint, err)
	}
	// An offline peer returning the old value still cannot undo the deletion.
	remote.records = []peerstore.Record{original}
	if err = syncer.Exchange(t.Context(), binding, remote); err != nil {
		t.Fatal(err)
	}
	current, err := s.ReadPeerRecord(t.Context(), binding.Account, original.Kind, original.ID)
	if err != nil || current.Revision() != deleted.Revision() {
		t.Fatalf("offline resurrection: %+v %v", current, err)
	}
}
