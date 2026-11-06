package api

import (
	"context"
	"errors"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/replica"
	"google.golang.org/protobuf/types/known/emptypb"
)

func peerRecord(r crdt.Record) *dieterv1.PeerRecord {
	v := &dieterv1.PeerRecord{Kind: r.Kind, Id: r.ID, Revision: r.Revision()}
	for _, x := range r.Versions {
		v.Versions = append(v.Versions, &dieterv1.PeerVersion{Clock: x.Clock, ValueJson: x.Value, Deleted: x.Deleted, ProvenanceJson: x.Provenance})
	}
	return v
}

func protoPeerDiagnostic(d replica.PeerSyncDiagnostic) *dieterv1.PeerSyncDiagnostic {
	return &dieterv1.PeerSyncDiagnostic{PeerId: d.PeerID, LastAttemptAt: d.LastAttemptAt, LastSuccessAt: d.LastSuccessAt, Route: d.Route, Direction: d.Direction, FailureCode: d.FailureCode, RecordKind: d.RecordKind, RecordId: d.RecordID, Field: d.Field, Actor: d.Actor, PullEpoch: d.Pull.Epoch, PullSequence: d.Pull.Sequence, PushEpoch: d.Push.Epoch, PushSequence: d.Push.Sequence}
}

func (s *Server) peerIdentity(ctx context.Context, account string) (replica.PeerIdentity, error) {
	identity, err := s.store.Replica.PeerIdentity()
	if err != nil {
		return identity, fault.New(fault.FailedPrecondition, "peer store awaits enrolled account discovery")
	}
	enrolled, err := link.LoadIdentity(s.store.Root)
	if err != nil || !enrolled.Enrolled() || enrolled.ID != identity.DaemonID || enrolled.Issuer() != identity.Gateway {
		return identity, fault.New(fault.FailedPrecondition, "peer enrollment changed")
	}
	if account != "" && account != identity.Account {
		return identity, fault.New(fault.PermissionDenied, "peer account mismatch")
	}
	subject := remoteDesktopOperator(ctx)
	if subject != "" && subject != identity.Subject {
		return identity, fault.New(fault.PermissionDenied, "peer operator mismatch")
	}
	return identity, nil
}

func (api *peerAPI) GetPeerStoreStatus(ctx context.Context, _ *emptypb.Empty) (*dieterv1.PeerStoreStatus, error) {
	ctx = operatorContext(ctx)
	identity, err := api.server.peerIdentity(ctx, "")
	if err != nil {
		return nil, err
	}
	data, err := api.server.store.Replica.PeerStoreInfo(ctx, identity.Account)
	if err != nil {
		return nil, domainFailure(err)
	}
	out := &dieterv1.PeerStoreStatus{Account: identity.Account, Actor: identity.Actor, Records: data.Records, Conflicts: data.Conflicts, LastSyncAt: data.LastSyncAt, LastPeerId: data.LastPeerID, LastRoute: data.LastRoute}
	diagnostics, err := api.server.store.Replica.PeerSyncDiagnostics(identity.Account)
	if err != nil {
		return nil, domainFailure(err)
	}
	for _, d := range diagnostics {
		out.Peers = append(out.Peers, protoPeerDiagnostic(d))
	}
	return out, nil
}

func (api *peerAPI) ListPeerRecords(ctx context.Context, r *dieterv1.PeerSnapshotRequest) (*dieterv1.PeerSnapshot, error) {
	ctx = operatorContext(ctx)
	identity, err := api.server.peerIdentity(ctx, r.GetAccount())
	if err != nil {
		return nil, err
	}
	if r.GetAfterKey() != "" && r.GetSnapshotRevision() == "" {
		return nil, fault.New(fault.Invalid, "continuation requires snapshot revision")
	}
	page, err := api.server.store.Replica.ListPeerRecordPage(ctx, identity.Account, "", "", r.GetAfterKey(), r.GetSnapshotRevision(), nil)
	if err != nil {
		return nil, domainFailure(err)
	}
	out := &dieterv1.PeerSnapshot{Account: identity.Account, SnapshotRevision: page.Revision, NextKey: page.NextKey}
	for _, record := range page.Records {
		out.Records = append(out.Records, peerRecord(record))
	}
	return out, nil
}

func (api *peerAPI) PutPeerRecord(ctx context.Context, r *dieterv1.PutPeerRecordRequest) (*dieterv1.PeerRecord, error) {
	ctx = operatorContext(ctx)
	identity, err := api.server.peerIdentity(ctx, "")
	if err != nil {
		return nil, err
	}
	record, err := api.server.store.Replica.PutPeerRecord(identity, r.GetKind(), r.GetId(), r.GetExpectedRevision(), r.GetValueJson(), r.GetDeleted())
	if err != nil {
		return nil, domainFailure(err)
	}
	return peerRecord(record), nil
}

func (api *peerAPI) MergePeerRecords(ctx context.Context, r *dieterv1.MergePeerRecordsRequest) (*emptypb.Empty, error) {
	ctx = operatorContext(ctx)
	if r.GetAccount() == "" {
		return nil, fault.New(fault.Invalid, "account required")
	}
	identity, err := api.server.peerIdentity(ctx, r.GetAccount())
	if err != nil {
		return nil, err
	}
	if len(r.GetRecords()) > crdt.PageSize {
		return nil, domainFailure(crdt.ErrCapacity)
	}
	records := make([]crdt.Record, 0, len(r.GetRecords()))
	for _, v := range r.GetRecords() {
		record := crdt.Record{Kind: v.GetKind(), ID: v.GetId()}
		for _, x := range v.GetVersions() {
			record.Versions = append(record.Versions, crdt.Version{Clock: x.GetClock(), Value: x.GetValueJson(), Deleted: x.GetDeleted(), Provenance: x.GetProvenanceJson()})
		}
		records = append(records, record)
	}
	return &emptypb.Empty{}, domainFailure(api.server.store.Replica.MergePeerRecords(identity, records))
}

func (api *peerAPI) GetPeerRecord(ctx context.Context, r *dieterv1.PeerRecordRef) (*dieterv1.PeerRecord, error) {
	ctx = operatorContext(ctx)
	identity, err := api.server.peerIdentity(ctx, "")
	if err != nil {
		return nil, err
	}
	record, err := api.server.store.Replica.ReadPeerRecord(ctx, identity.Account, r.GetKind(), r.GetId())
	if errors.Is(err, home.ErrNotFound) {
		return nil, fault.New(fault.NotFound, "shared record not found")
	}
	if err != nil {
		return nil, domainFailure(err)
	}
	return peerRecord(record), nil
}

func (api *peerAPI) GetPeerChanges(ctx context.Context, r *dieterv1.PeerChangesRequest) (*dieterv1.PeerChangesResponse, error) {
	ctx = operatorContext(ctx)
	identity, err := api.server.peerIdentity(ctx, r.GetAccount())
	if err != nil {
		return nil, err
	}
	changes, err := api.server.store.Replica.PeerChanges(identity.Account, r.GetEpoch(), r.GetAfterSequence())
	if err != nil {
		return nil, domainFailure(err)
	}
	response := &dieterv1.PeerChangesResponse{Epoch: changes.Epoch, AfterSequence: changes.After, More: changes.More}
	for _, record := range changes.Records {
		response.Records = append(response.Records, peerRecord(record))
	}
	return response, nil
}
