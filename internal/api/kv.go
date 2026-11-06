package api

import (
	"context"
	"errors"
	"strings"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kv"
	"github.com/dbpprt/dieter/internal/store/replica"
)

func kvEntry(r crdt.Record) *dieterv1.KVEntry {
	v := schema.SelectedKV(r)
	return &dieterv1.KVEntry{Namespace: strings.TrimPrefix(r.Kind, schema.KVKindPrefix), Key: r.ID, Revision: r.Revision(), ValueJson: v.Value, Deleted: v.Deleted, Versions: peerRecord(r).Versions}
}
func kvMatches(r crdt.Record, ns, prefix string) bool {
	return strings.HasPrefix(r.Kind, schema.KVKindPrefix) && (ns == "" || r.Kind == schema.KVKindPrefix+ns) && strings.HasPrefix(r.ID, prefix)
}
func kvFilter(ns, prefix string) error {
	if ns != "" {
		if _, err := schema.KVKind(ns); err != nil {
			return domainFailure(err)
		}
	}
	if len(prefix) > 128 {
		return fault.New(fault.Invalid, "KV prefix too long")
	}
	return nil
}

func (s *Server) kvIdentity(ctx context.Context, account string) (replica.PeerIdentity, error) {
	identity, err := s.store.Replica.EnsureIdentity()
	if err == nil && identity.Account == "local" && remoteDesktopOperator(ctx) == "" {
		if account != "" && account != identity.Account {
			return identity, fault.New(fault.PermissionDenied, "KV account mismatch")
		}
		return identity, nil
	}
	return s.peerIdentity(ctx, account)
}

func (api *kvAPI) GetKV(ctx context.Context, r *dieterv1.KVRef) (*dieterv1.KVEntry, error) {
	ctx = operatorContext(ctx)
	identity, err := api.server.kvIdentity(ctx, r.GetAccount())
	if err != nil {
		return nil, err
	}
	kind, err := schema.KVKind(r.GetNamespace())
	if err != nil {
		return nil, domainFailure(err)
	}
	record, err := api.server.store.Replica.ReadPeerRecord(ctx, identity.Account, kind, r.GetKey())
	if errors.Is(err, home.ErrNotFound) {
		return nil, fault.New(fault.NotFound, "KV key not found")
	}
	if err != nil {
		return nil, domainFailure(err)
	}
	return kvEntry(record), nil
}

func (api *kvAPI) ListKV(ctx context.Context, r *dieterv1.KVListRequest) (*dieterv1.KVPage, error) {
	ctx = operatorContext(ctx)
	identity, err := api.server.kvIdentity(ctx, r.GetAccount())
	if err != nil {
		return nil, err
	}
	if err = kvFilter(r.GetNamespace(), r.GetPrefix()); err != nil {
		return nil, err
	}
	var cursor *replica.PeerCheckpoint
	if r.GetSnapshot() != nil {
		cursor = &replica.PeerCheckpoint{Epoch: r.Snapshot.Epoch, Sequence: r.Snapshot.Sequence}
	}
	kind := schema.KVKindPrefix
	if r.GetNamespace() != "" {
		kind += r.GetNamespace()
	}
	page, err := api.server.store.Replica.ListPeerRecordPage(ctx, identity.Account, kind, r.GetPrefix(), r.GetAfterKey(), "", cursor)
	if err != nil {
		return nil, domainFailure(err)
	}
	out := &dieterv1.KVPage{Account: identity.Account, DaemonId: identity.DaemonID, Cursor: &dieterv1.KVCursor{Epoch: page.Epoch, Sequence: page.Sequence}, NextKey: page.NextKey}
	for _, record := range page.Records {
		out.Entries = append(out.Entries, kvEntry(record))
	}
	return out, nil
}

func (s *Server) mutateKV(ctx context.Context, ref *dieterv1.KVRef, m kv.Mutation) (*dieterv1.KVEntry, error) {
	identity, err := s.kvIdentity(ctx, ref.GetAccount())
	if err != nil {
		return nil, err
	}
	// Mutations must carry the account observed with List/Watch, even on loopback.
	if ref.GetAccount() == "" {
		return nil, fault.New(fault.Invalid, "KV account required")
	}
	// Agent channel records have one writer each, their daemon; clients post
	// through ChannelService.
	if schema.ChannelNamespaceKind(ref.GetNamespace()) {
		return nil, fault.New(fault.PermissionDenied, "agent channel records are written by their daemon; use dieter channel")
	}
	m.Namespace, m.Key = ref.GetNamespace(), ref.GetKey()
	record, err := s.store.KV.Mutate(identity, m)
	if err != nil {
		return nil, domainFailure(err)
	}
	return kvEntry(record), nil
}

func (api *kvAPI) PutKV(ctx context.Context, r *dieterv1.KVPutRequest) (*dieterv1.KVEntry, error) {
	ctx = operatorContext(ctx)
	return api.server.mutateKV(ctx, r.GetRef(), kv.Mutation{Value: r.GetValueJson(), Revision: r.GetExpectedRevision(), OperationID: r.GetOperationId(), DaemonID: r.GetDaemonId()})
}

func (api *kvAPI) DeleteKV(ctx context.Context, r *dieterv1.KVDeleteRequest) (*dieterv1.KVEntry, error) {
	ctx = operatorContext(ctx)
	return api.server.mutateKV(ctx, r.GetRef(), kv.Mutation{Delete: true, Revision: r.GetExpectedRevision(), OperationID: r.GetOperationId(), DaemonID: r.GetDaemonId()})
}

func (api *kvAPI) MoveKV(ctx context.Context, r *dieterv1.KVMoveRequest) (*dieterv1.KVEntry, error) {
	ctx = operatorContext(ctx)
	return api.server.mutateKV(ctx, r.GetRef(), kv.Mutation{Move: &kv.Move{Parent: r.GetParent(), After: r.GetAfterKey(), Before: r.GetBeforeKey()}, Revision: r.GetExpectedRevision(), OperationID: r.GetOperationId(), DaemonID: r.GetDaemonId()})
}

func (s *Server) watchKV(ctx context.Context, r *dieterv1.KVWatchRequest, send func(*dieterv1.KVFrame) error) error {
	if s.kvWatches.Add(1) > 64 {
		s.kvWatches.Add(-1)
		return fault.New(fault.ResourceExhausted, "too many KV subscriptions")
	}
	defer s.kvWatches.Add(-1)
	identity, err := s.kvIdentity(ctx, r.GetAccount())
	if err != nil {
		return err
	}
	if err = kvFilter(r.GetNamespace(), r.GetPrefix()); err != nil {
		return err
	}
	epoch, seq := r.GetAfter().GetEpoch(), r.GetAfter().GetSequence()
	reset := epoch == ""
	wake := newChangeWait(s.store)
	defer wake.close()
	first := true
	for {
		current, e := s.kvIdentity(ctx, identity.Account)
		if e != nil {
			return e
		}
		if current != identity {
			return fault.New(fault.FailedPrecondition, "KV account changed")
		}
		changes, e := s.store.Replica.PeerChanges(identity.Account, epoch, seq)
		if errors.Is(e, crdt.ErrConflict) {
			epoch, seq, reset = "", 0, true
			continue
		}
		if e != nil {
			return domainFailure(e)
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

func (api *kvAPI) WatchKV(ctx context.Context, request *dieterv1.KVWatchRequest, stream *connect.ServerStream[dieterv1.KVFrame]) error {
	ctx = operatorContext(ctx)
	return api.server.watchKV(ctx, request, stream.Send)
}
