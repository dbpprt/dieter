package server

import (
	"context"
	"encoding/json"
	"errors"

	"connectrpc.com/connect"
	"github.com/dbpprt/dieter/internal/daemon"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/peerstore"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

func (api *grpcAPI) peerIdentity(ctx context.Context, account string) (store.PeerIdentity, error) {
	identity, err := api.server.store.PeerIdentity()
	if err != nil {
		return identity, status.Error(codes.FailedPrecondition, "peer store awaits enrolled account discovery")
	}
	enrolled, err := daemon.LoadIdentity(api.server.store.Root)
	if err != nil || !enrolled.Enrolled() || enrolled.ID != identity.DaemonID || enrolled.Issuer() != identity.Gateway {
		return identity, status.Error(codes.FailedPrecondition, "peer enrollment changed")
	}
	if account != "" && account != identity.Account {
		return identity, status.Error(codes.PermissionDenied, "peer account mismatch")
	}
	subject := remoteDesktopOperator(ctx)
	if subject != "" && subject != identity.Subject {
		return identity, status.Error(codes.PermissionDenied, "peer operator mismatch")
	}
	return identity, nil
}
func peerFailure(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, peerstore.ErrConflict) {
		return status.Error(codes.Aborted, err.Error())
	}
	if errors.Is(err, peerstore.ErrCapacity) {
		return status.Error(codes.ResourceExhausted, err.Error())
	}
	return status.Error(codes.InvalidArgument, err.Error())
}
func peerRecord(r peerstore.Record) *dieterv1.PeerRecord {
	v := &dieterv1.PeerRecord{Kind: r.Kind, Id: r.ID, Revision: r.Revision()}
	for _, x := range r.Versions {
		v.Versions = append(v.Versions, &dieterv1.PeerVersion{Clock: x.Clock, ValueJson: x.Value, Deleted: x.Deleted, ProvenanceJson: x.Provenance})
	}
	return v
}
func (api *grpcAPI) GetPeerStoreStatus(ctx context.Context, _ *emptypb.Empty) (*dieterv1.PeerStoreStatus, error) {
	identity, err := api.peerIdentity(ctx, "")
	if err != nil {
		return nil, err
	}
	data, err := api.server.store.PeerData(identity.Account)
	if err != nil {
		return nil, peerFailure(err)
	}
	out := &dieterv1.PeerStoreStatus{Account: identity.Account, Actor: identity.Actor, Records: uint32(len(data.Records)), LastSyncAt: data.LastSyncAt, LastPeerId: data.LastPeerID, LastRoute: data.LastRoute}
	for _, r := range data.Records {
		if len(r.Versions) > 1 {
			out.Conflicts++
		}
	}
	return out, nil
}
func (api *grpcAPI) ListPeerRecords(ctx context.Context, r *dieterv1.PeerSnapshotRequest) (*dieterv1.PeerSnapshot, error) {
	identity, err := api.peerIdentity(ctx, r.GetAccount())
	if err != nil {
		return nil, err
	}
	data, err := api.server.store.PeerData(identity.Account)
	if err != nil {
		return nil, peerFailure(err)
	}
	revision := peerstore.Revision(data.State)
	if r.GetSnapshotRevision() != "" && r.GetSnapshotRevision() != revision {
		return nil, status.Error(codes.Aborted, "peer snapshot changed; restart pagination")
	}
	if r.GetAfterKey() != "" && r.GetSnapshotRevision() == "" {
		return nil, status.Error(codes.InvalidArgument, "continuation requires snapshot revision")
	}
	out := &dieterv1.PeerSnapshot{Account: identity.Account, SnapshotRevision: revision}
	pageBytes := 2
	for _, v := range data.Sorted() {
		key := peerstore.Key(v.Kind, v.ID)
		if key <= r.GetAfterKey() {
			continue
		}
		raw, err := json.Marshal(v)
		if err != nil {
			return nil, peerFailure(err)
		}
		if len(out.Records) == peerstore.PageSize || len(out.Records) > 0 && pageBytes+len(raw)+1 > peerstore.MaxPageBytes {
			last := out.Records[len(out.Records)-1]
			out.NextKey = peerstore.Key(last.Kind, last.Id)
			break
		}
		out.Records = append(out.Records, peerRecord(v))
		pageBytes += len(raw) + 1
	}
	return out, nil
}
func (api *grpcAPI) PutPeerRecord(ctx context.Context, r *dieterv1.PutPeerRecordRequest) (*dieterv1.PeerRecord, error) {
	identity, err := api.peerIdentity(ctx, "")
	if err != nil {
		return nil, err
	}
	record, err := api.server.store.PutPeerRecord(identity, r.GetKind(), r.GetId(), r.GetExpectedRevision(), r.GetValueJson(), r.GetDeleted())
	if err != nil {
		return nil, peerFailure(err)
	}
	return peerRecord(record), nil
}
func (api *grpcAPI) MergePeerRecords(ctx context.Context, r *dieterv1.MergePeerRecordsRequest) (*emptypb.Empty, error) {
	if r.GetAccount() == "" {
		return nil, status.Error(codes.InvalidArgument, "account required")
	}
	identity, err := api.peerIdentity(ctx, r.GetAccount())
	if err != nil {
		return nil, err
	}
	if len(r.GetRecords()) > peerstore.PageSize {
		return nil, peerFailure(peerstore.ErrCapacity)
	}
	records := make([]peerstore.Record, 0, len(r.GetRecords()))
	for _, v := range r.GetRecords() {
		record := peerstore.Record{Kind: v.GetKind(), ID: v.GetId()}
		for _, x := range v.GetVersions() {
			record.Versions = append(record.Versions, peerstore.Version{Clock: x.GetClock(), Value: x.GetValueJson(), Deleted: x.GetDeleted(), Provenance: x.GetProvenanceJson()})
		}
		records = append(records, record)
	}
	return &emptypb.Empty{}, peerFailure(api.server.store.MergePeerRecords(identity, records))
}
func (api *connectAPI) GetPeerStoreStatus(ctx context.Context, r *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.PeerStoreStatus], error) {
	return connectUnary(controlOperatorContext(ctx, r), r, api.core.GetPeerStoreStatus)
}
func (api *connectAPI) ListPeerRecords(ctx context.Context, r *connect.Request[dieterv1.PeerSnapshotRequest]) (*connect.Response[dieterv1.PeerSnapshot], error) {
	return connectUnary(controlOperatorContext(ctx, r), r, api.core.ListPeerRecords)
}
func (api *connectAPI) PutPeerRecord(ctx context.Context, r *connect.Request[dieterv1.PutPeerRecordRequest]) (*connect.Response[dieterv1.PeerRecord], error) {
	return connectUnary(controlOperatorContext(ctx, r), r, api.core.PutPeerRecord)
}
func (api *connectAPI) MergePeerRecords(ctx context.Context, r *connect.Request[dieterv1.MergePeerRecordsRequest]) (*connect.Response[emptypb.Empty], error) {
	return connectUnary(controlOperatorContext(ctx, r), r, api.core.MergePeerRecords)
}

func (api *grpcAPI) GetPeerRecord(ctx context.Context, r *dieterv1.PeerRecordRef) (*dieterv1.PeerRecord, error) {
	identity, err := api.peerIdentity(ctx, "")
	if err != nil {
		return nil, err
	}
	data, err := api.server.store.PeerData(identity.Account)
	if err != nil {
		return nil, peerFailure(err)
	}
	record, ok := data.Records[peerstore.Key(r.GetKind(), r.GetId())]
	if !ok {
		return nil, status.Error(codes.NotFound, "shared record not found")
	}
	return peerRecord(record), nil
}
func (api *grpcAPI) GetPeerChanges(ctx context.Context, r *dieterv1.PeerChangesRequest) (*dieterv1.PeerChangesResponse, error) {
	identity, err := api.peerIdentity(ctx, r.GetAccount())
	if err != nil {
		return nil, err
	}
	changes, err := api.server.store.PeerChanges(identity.Account, r.GetEpoch(), r.GetAfterSequence())
	if err != nil {
		return nil, peerFailure(err)
	}
	response := &dieterv1.PeerChangesResponse{Epoch: changes.Epoch, AfterSequence: changes.After, More: changes.More}
	for _, record := range changes.Records {
		response.Records = append(response.Records, peerRecord(record))
	}
	return response, nil
}
func (api *connectAPI) GetPeerRecord(ctx context.Context, r *connect.Request[dieterv1.PeerRecordRef]) (*connect.Response[dieterv1.PeerRecord], error) {
	return connectUnary(controlOperatorContext(ctx, r), r, api.core.GetPeerRecord)
}
func (api *connectAPI) GetPeerChanges(ctx context.Context, r *connect.Request[dieterv1.PeerChangesRequest]) (*connect.Response[dieterv1.PeerChangesResponse], error) {
	return connectUnary(controlOperatorContext(ctx, r), r, api.core.GetPeerChanges)
}
