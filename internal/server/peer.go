package server

import (
	"context"
	"errors"

	"connectrpc.com/connect"
	"github.com/dbpprt/dieter/internal/daemon"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/peerstore"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
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
	var record *store.PeerRecordError
	if errors.As(err, &record) {
		s, e := status.New(codes.InvalidArgument, record.Error()).WithDetails(&errdetails.ErrorInfo{Reason: record.Code, Domain: "dieter.peer", Metadata: map[string]string{"kind": record.Kind, "id": record.ID, "field": record.Field}})
		if e == nil {
			return s.Err()
		}
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
	data, err := api.server.store.PeerStoreInfo(ctx, identity.Account)
	if err != nil {
		return nil, peerFailure(err)
	}
	out := &dieterv1.PeerStoreStatus{Account: identity.Account, Actor: identity.Actor, Records: data.Records, Conflicts: data.Conflicts, LastSyncAt: data.LastSyncAt, LastPeerId: data.LastPeerID, LastRoute: data.LastRoute}
	diagnostics, err := api.server.store.PeerSyncDiagnostics(identity.Account)
	if err != nil {
		return nil, peerFailure(err)
	}
	for _, d := range diagnostics {
		out.Peers = append(out.Peers, protoPeerDiagnostic(d))
	}
	return out, nil
}
func (api *grpcAPI) ListPeerRecords(ctx context.Context, r *dieterv1.PeerSnapshotRequest) (*dieterv1.PeerSnapshot, error) {
	identity, err := api.peerIdentity(ctx, r.GetAccount())
	if err != nil {
		return nil, err
	}
	if r.GetAfterKey() != "" && r.GetSnapshotRevision() == "" {
		return nil, status.Error(codes.InvalidArgument, "continuation requires snapshot revision")
	}
	page, err := api.server.store.ListPeerRecordPage(ctx, identity.Account, "", "", r.GetAfterKey(), r.GetSnapshotRevision(), nil)
	if err != nil {
		return nil, peerFailure(err)
	}
	out := &dieterv1.PeerSnapshot{Account: identity.Account, SnapshotRevision: page.Revision, NextKey: page.NextKey}
	for _, record := range page.Records {
		out.Records = append(out.Records, peerRecord(record))
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
	record, err := api.server.store.ReadPeerRecord(ctx, identity.Account, r.GetKind(), r.GetId())
	if errors.Is(err, store.ErrNotFound) {
		return nil, status.Error(codes.NotFound, "shared record not found")
	}
	if err != nil {
		return nil, peerFailure(err)
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

func protoPeerDiagnostic(d store.PeerSyncDiagnostic) *dieterv1.PeerSyncDiagnostic {
	return &dieterv1.PeerSyncDiagnostic{PeerId: d.PeerID, LastAttemptAt: d.LastAttemptAt, LastSuccessAt: d.LastSuccessAt, Route: d.Route, Direction: d.Direction, FailureCode: d.FailureCode, RecordKind: d.RecordKind, RecordId: d.RecordID, Field: d.Field, Actor: d.Actor, PullEpoch: d.Pull.Epoch, PullSequence: d.Pull.Sequence, PushEpoch: d.Push.Epoch, PushSequence: d.Push.Sequence}
}
