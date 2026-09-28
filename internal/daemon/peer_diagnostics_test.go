package daemon

import (
	"context"
	"errors"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/emptypb"
)

type rejectedPageClient struct{ dieterv1.DieterServiceClient }

func (rejectedPageClient) GetPeerStoreStatus(context.Context, *emptypb.Empty, ...grpc.CallOption) (*dieterv1.PeerStoreStatus, error) {
	return &dieterv1.PeerStoreStatus{Account: "account", Actor: "remote"}, nil
}
func (rejectedPageClient) GetPeerChanges(context.Context, *dieterv1.PeerChangesRequest, ...grpc.CallOption) (*dieterv1.PeerChangesResponse, error) {
	return &dieterv1.PeerChangesResponse{Epoch: "remote-epoch", AfterSequence: 2, Records: []*dieterv1.PeerRecord{
		{Kind: "board", Id: "b_good.name", Versions: []*dieterv1.PeerVersion{{Clock: map[string]uint64{"remote": 1}, ValueJson: []byte(`"Main"`)}}},
		{Kind: "board", Id: "b_bad.retired", Versions: []*dieterv1.PeerVersion{{Clock: map[string]uint64{"remote": 1}, ValueJson: []byte(`"secret-invalid-value"`)}}},
	}}, nil
}

func TestRejectedPeerPagePreservesCheckpointAndReportsBlocker(t *testing.T) {
	data := store.New(t.TempDir())
	binding, err := data.BindPeerAccount("account", "github:1", "local", "https://gateway.test")
	if err != nil {
		t.Fatal(err)
	}
	syncer := &PeerSync{Store: data}
	err = syncer.Exchange(context.Background(), binding, rejectedPageClient{})
	var blocker *store.PeerRecordError
	if !errors.As(err, &blocker) || blocker.ID != "b_bad.retired" {
		t.Fatalf("blocker: %v", err)
	}
	records, err := data.PeerData(binding.Account)
	if err != nil || len(records.Records) != 0 {
		t.Fatalf("partially committed: %+v %v", records, err)
	}
	checkpoint, err := data.PeerCheckpoint(binding.Account, "remote", "pull")
	if err != nil || checkpoint.Sequence != 0 || checkpoint.Epoch != "" {
		t.Fatalf("advanced: %+v %v", checkpoint, err)
	}
	reopened := store.New(data.Root)
	diagnostics, err := reopened.PeerSyncDiagnostics(binding.Account)
	if err != nil || len(diagnostics) != 1 || diagnostics[0].RecordID != "b_bad.retired" || diagnostics[0].Direction != "pull" {
		t.Fatalf("diagnostic: %+v %v", diagnostics, err)
	}
	initial, err := reopened.MetadataCursor()
	if err != nil {
		t.Fatal(err)
	}
	if err := reopened.RecordPeerSync(binding, store.PeerSyncDiagnostic{PeerID: "other", LastAttemptAt: "2026-09-28T08:00:00Z"}); err != nil {
		t.Fatal(err)
	}
	diagnostics, err = reopened.PeerSyncDiagnostics(binding.Account)
	if err != nil || len(diagnostics) != 2 {
		t.Fatalf("lost other peer blocker: %+v %v", diagnostics, err)
	}
	after, err := reopened.MetadataCursor()
	if err != nil || initial != after {
		t.Fatalf("diagnostics changed workspace cursor: %+v %+v %v", initial, after, err)
	}
}
