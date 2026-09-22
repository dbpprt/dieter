package server

import (
	"context"
	"errors"
	"strings"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/peerstore"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func (api *grpcAPI) kvIdentity(ctx context.Context, account string) (store.PeerIdentity, error) {
	identity, err := api.server.store.KVIdentity()
	if err == nil && identity.Account == "local" && remoteDesktopOperator(ctx) == "" {
		if account != "" && account != identity.Account {
			return identity, status.Error(codes.PermissionDenied, "KV account mismatch")
		}
		return identity, nil
	}
	return api.peerIdentity(ctx, account)
}
func kvEntry(r peerstore.Record) *dieterv1.KVEntry {
	v := peerstore.SelectedKV(r)
	return &dieterv1.KVEntry{Namespace: strings.TrimPrefix(r.Kind, peerstore.KVKindPrefix), Key: r.ID, Revision: r.Revision(), ValueJson: v.Value, Deleted: v.Deleted, Versions: peerRecord(r).Versions}
}
func kvMatches(r peerstore.Record, ns, prefix string) bool {
	return strings.HasPrefix(r.Kind, peerstore.KVKindPrefix) && (ns == "" || r.Kind == peerstore.KVKindPrefix+ns) && strings.HasPrefix(r.ID, prefix)
}
func kvFilter(ns, prefix string) error {
	if ns != "" {
		if _, err := peerstore.KVKind(ns); err != nil {
			return peerFailure(err)
		}
	}
	if len(prefix) > 128 {
		return status.Error(codes.InvalidArgument, "KV prefix too long")
	}
	return nil
}
func (api *grpcAPI) GetKV(ctx context.Context, r *dieterv1.KVRef) (*dieterv1.KVEntry, error) {
	identity, err := api.kvIdentity(ctx, r.GetAccount())
	if err != nil {
		return nil, err
	}
	kind, err := peerstore.KVKind(r.GetNamespace())
	if err != nil {
		return nil, peerFailure(err)
	}
	data, err := api.server.store.PeerData(identity.Account)
	if err != nil {
		return nil, peerFailure(err)
	}
	record, ok := data.Records[peerstore.Key(kind, r.GetKey())]
	if !ok {
		return nil, status.Error(codes.NotFound, "KV key not found")
	}
	return kvEntry(record), nil
}
func (api *grpcAPI) ListKV(ctx context.Context, r *dieterv1.KVListRequest) (*dieterv1.KVPage, error) {
	identity, err := api.kvIdentity(ctx, r.GetAccount())
	if err != nil {
		return nil, err
	}
	if err = kvFilter(r.GetNamespace(), r.GetPrefix()); err != nil {
		return nil, err
	}
	data, err := api.server.store.PeerData(identity.Account)
	if err != nil {
		return nil, peerFailure(err)
	}
	if r.GetSnapshot() != nil && (r.Snapshot.Epoch != data.Epoch || r.Snapshot.Sequence != data.Sequence) {
		return nil, peerFailure(peerstore.ErrConflict)
	}
	out := &dieterv1.KVPage{Account: identity.Account, DaemonId: identity.DaemonID, Cursor: &dieterv1.KVCursor{Epoch: data.Epoch, Sequence: data.Sequence}}
	size := 0
	for _, record := range data.Sorted() {
		key := peerstore.Key(record.Kind, record.ID)
		if key <= r.GetAfterKey() || !kvMatches(record, r.GetNamespace(), r.GetPrefix()) {
			continue
		}
		entry := kvEntry(record)
		if len(out.Entries) >= peerstore.PageSize || (len(out.Entries) > 0 && size+len(entry.ValueJson) > peerstore.MaxPageBytes/2) {
			last := out.Entries[len(out.Entries)-1]
			out.NextKey = peerstore.Key(peerstore.KVKindPrefix+last.Namespace, last.Key)
			break
		}
		out.Entries = append(out.Entries, entry)
		for _, v := range entry.Versions {
			size += len(v.ValueJson) + 4096
		}
	}
	return out, nil
}
func (api *grpcAPI) mutateKV(ctx context.Context, ref *dieterv1.KVRef, m store.KVMutation) (*dieterv1.KVEntry, error) {
	identity, err := api.kvIdentity(ctx, ref.GetAccount())
	if err != nil {
		return nil, err
	}
	// Mutations must carry the account observed with List/Watch, even on loopback.
	if ref.GetAccount() == "" {
		return nil, status.Error(codes.InvalidArgument, "KV account required")
	}
	m.Namespace, m.Key = ref.GetNamespace(), ref.GetKey()
	record, err := api.server.store.MutateKV(identity, m)
	if err != nil {
		return nil, peerFailure(err)
	}
	return kvEntry(record), nil
}
func (api *grpcAPI) PutKV(ctx context.Context, r *dieterv1.KVPutRequest) (*dieterv1.KVEntry, error) {
	return api.mutateKV(ctx, r.GetRef(), store.KVMutation{Value: r.GetValueJson(), Revision: r.GetExpectedRevision(), OperationID: r.GetOperationId(), DaemonID: r.GetDaemonId()})
}
func (api *grpcAPI) DeleteKV(ctx context.Context, r *dieterv1.KVDeleteRequest) (*dieterv1.KVEntry, error) {
	return api.mutateKV(ctx, r.GetRef(), store.KVMutation{Delete: true, Revision: r.GetExpectedRevision(), OperationID: r.GetOperationId(), DaemonID: r.GetDaemonId()})
}
func (api *grpcAPI) MoveKV(ctx context.Context, r *dieterv1.KVMoveRequest) (*dieterv1.KVEntry, error) {
	return api.mutateKV(ctx, r.GetRef(), store.KVMutation{Move: &store.KVMove{Parent: r.GetParent(), After: r.GetAfterKey(), Before: r.GetBeforeKey()}, Revision: r.GetExpectedRevision(), OperationID: r.GetOperationId(), DaemonID: r.GetDaemonId()})
}
func (api *grpcAPI) watchKV(ctx context.Context, r *dieterv1.KVWatchRequest, send func(*dieterv1.KVFrame) error) error {
	if api.server.kvWatches.Add(1) > 64 {
		api.server.kvWatches.Add(-1)
		return status.Error(codes.ResourceExhausted, "too many KV subscriptions")
	}
	defer api.server.kvWatches.Add(-1)
	identity, err := api.kvIdentity(ctx, r.GetAccount())
	if err != nil {
		return err
	}
	if err = kvFilter(r.GetNamespace(), r.GetPrefix()); err != nil {
		return err
	}
	epoch, seq := r.GetAfter().GetEpoch(), r.GetAfter().GetSequence()
	reset := epoch == ""
	wake := newChangeWait(api.server.store)
	defer wake.close()
	first := true
	for {
		current, e := api.kvIdentity(ctx, identity.Account)
		if e != nil {
			return e
		}
		if current != identity {
			return status.Error(codes.FailedPrecondition, "KV account changed")
		}
		changes, e := api.server.store.PeerChanges(identity.Account, epoch, seq)
		if errors.Is(e, peerstore.ErrConflict) {
			epoch, seq, reset = "", 0, true
			continue
		}
		if e != nil {
			return peerFailure(e)
		}
		frame := &dieterv1.KVFrame{Account: identity.Account, DaemonId: identity.DaemonID, Cursor: &dieterv1.KVCursor{Epoch: changes.Epoch, Sequence: changes.After}, Reset_: reset, CaughtUp: !changes.More}
		for _, record := range changes.Records {
			if kvMatches(record, r.GetNamespace(), r.GetPrefix()) {
				frame.Entries = append(frame.Entries, kvEntry(record))
			}
		}
		if first || reset || changes.After != seq {
			if err = send(frame); err != nil {
				return err
			}
		}
		epoch, seq, reset, first = changes.Epoch, changes.After, false, false
		if changes.More {
			continue
		}
		if err := wake.wait(ctx); err != nil {
			return err
		}
	}
}
func (api *grpcAPI) WatchKV(r *dieterv1.KVWatchRequest, s dieterv1.DieterService_WatchKVServer) error {
	return api.watchKV(s.Context(), r, s.Send)
}
func (api *connectAPI) GetKV(ctx context.Context, r *connect.Request[dieterv1.KVRef]) (*connect.Response[dieterv1.KVEntry], error) {
	return connectUnary(controlOperatorContext(ctx, r), r, api.core.GetKV)
}
func (api *connectAPI) ListKV(ctx context.Context, r *connect.Request[dieterv1.KVListRequest]) (*connect.Response[dieterv1.KVPage], error) {
	return connectUnary(controlOperatorContext(ctx, r), r, api.core.ListKV)
}
func (api *connectAPI) PutKV(ctx context.Context, r *connect.Request[dieterv1.KVPutRequest]) (*connect.Response[dieterv1.KVEntry], error) {
	return connectUnary(controlOperatorContext(ctx, r), r, api.core.PutKV)
}
func (api *connectAPI) DeleteKV(ctx context.Context, r *connect.Request[dieterv1.KVDeleteRequest]) (*connect.Response[dieterv1.KVEntry], error) {
	return connectUnary(controlOperatorContext(ctx, r), r, api.core.DeleteKV)
}
func (api *connectAPI) MoveKV(ctx context.Context, r *connect.Request[dieterv1.KVMoveRequest]) (*connect.Response[dieterv1.KVEntry], error) {
	return connectUnary(controlOperatorContext(ctx, r), r, api.core.MoveKV)
}
func (api *connectAPI) WatchKV(ctx context.Context, r *connect.Request[dieterv1.KVWatchRequest], s *connect.ServerStream[dieterv1.KVFrame]) error {
	return connectFailure(api.core.watchKV(controlOperatorContext(ctx, r), r.Msg, s.Send))
}
