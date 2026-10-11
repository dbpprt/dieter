package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"syscall"
	"testing"

	"connectrpc.com/connect"
	"github.com/dbpprt/dieter/internal/engine"
	"github.com/dbpprt/dieter/internal/git"
	"github.com/dbpprt/dieter/internal/git/changeset"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/host/terminal"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/security/vault"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestRPCErrorPreservesGRPCDetails(t *testing.T) {
	t.Parallel()
	info := &errdetails.ErrorInfo{Reason: "causal_conflict", Domain: "dieter.peer", Metadata: map[string]string{"kind": "project-settings", "id": "rejected"}}
	value, err := status.New(codes.InvalidArgument, "record rejected").WithDetails(info)
	if err != nil {
		t.Fatal(err)
	}
	failure := connectError(t, rpcError(value.Err()))
	if failure.Code() != connect.CodeInvalidArgument || failure.Message() != value.Message() || len(failure.Details()) != 1 {
		t.Fatalf("Connect dropped status: %v", failure)
	}
	decoded, err := failure.Details()[0].Value()
	if err != nil || !proto.Equal(decoded, info) {
		t.Fatalf("Connect changed rich status: %v, %v", decoded, err)
	}
}

func TestPeerRecordErrorsCarryErrorInfo(t *testing.T) {
	t.Parallel()
	err := domainFailure(fmt.Errorf("merge: %w", &store.PeerRecordError{Code: "invalid-record", Kind: "board", ID: "b_1", Field: "name"}))
	failure := connectError(t, rpcError(err))
	if failure.Code() != connect.CodeInvalidArgument || len(failure.Details()) != 1 {
		t.Fatalf("peer record failure=%v", failure)
	}
	decoded, detailErr := failure.Details()[0].Value()
	if info, ok := decoded.(*errdetails.ErrorInfo); detailErr != nil || !ok || info.GetReason() != "invalid-record" || info.GetMetadata()["field"] != "name" {
		t.Fatalf("peer record detail=%v err=%v", decoded, detailErr)
	}
}

func TestInsufficientStorageMapsToResourceExhausted(t *testing.T) {
	t.Parallel()
	for _, cause := range []error{engine.ErrInsufficientStorage, syscall.ENOSPC, syscall.EDQUOT} {
		t.Run(cause.Error(), func(t *testing.T) {
			err := fmt.Errorf("save command: %w", &os.PathError{Op: "write", Path: "fixture", Err: cause})
			failure := connectError(t, rpcError(err))
			if failure.Code() != connect.CodeResourceExhausted {
				t.Fatalf("code=%s", failure.Code())
			}
			if failure.Message() != err.Error() {
				t.Fatalf("lost actionable storage detail: %v", failure)
			}
		})
	}
}

// Clients drop durable commands rejected with InvalidArgument and the other
// permanent codes, and retry Internal and Unavailable. Every user-facing
// validation error must therefore stay InvalidArgument, while host and
// storage failures must not be reported as the caller's fault.
func TestRPCErrorCodes(t *testing.T) {
	t.Parallel()
	_, _, harnessErr := harness.StaticCatalog(false).ResolveSelection("missing", "")
	_, _, modelErr := harness.StaticCatalog(false).ResolveSelection("codex", "missing-model")
	_, partsErr := model.NormalizeMessageParts([]model.UIMessagePart{{Type: "unsupported"}})
	for name, test := range map[string]struct {
		err  error
		code connect.Code
	}{
		"handler validation":          {fault.New(fault.Invalid, "project path is required"), connect.CodeInvalidArgument},
		"wrapped validation":          {fmt.Errorf("create card: %w", fault.Invalidf("title is required")), connect.CodeInvalidArgument},
		"unknown harness":             {harnessErr, connect.CodeInvalidArgument},
		"unregistered model":          {modelErr, connect.CodeInvalidArgument},
		"attachment validation":       {partsErr, connect.CodeInvalidArgument},
		"not found":                   {fmt.Errorf("card c_1: %w", store.ErrNotFound), connect.CodeNotFound},
		"missing file":                {&os.PathError{Op: "open", Path: "x", Err: os.ErrNotExist}, connect.CodeNotFound},
		"active card":                 {store.ErrCardActive, connect.CodeFailedPrecondition},
		"active card while sending":   {sendMessageFailure(store.ErrCardActive), connect.CodeAborted},
		"writer busy":                 {fmt.Errorf("%w: deadline", store.ErrWriterBusy), connect.CodeUnavailable},
		"stale changeset":             {changeset.ErrStaleRevision, connect.CodeAborted},
		"peer conflict":               {crdt.ErrConflict, connect.CodeAborted},
		"peer capacity":               {crdt.ErrCapacity, connect.CodeResourceExhausted},
		"catalog unavailable":         {fmt.Errorf("%w: fixture", harness.ErrCatalogUnavailable), connect.CodeUnavailable},
		"terminal limit":              {terminal.ErrLimitReached, connect.CodeResourceExhausted},
		"terminal unsupported":        {terminal.ErrUnsupported, connect.CodeUnimplemented},
		"vault tampered":              {vault.ErrTampered, connect.CodeDataLoss},
		"vault wrong recovery":        {vault.ErrWrongRecovery, connect.CodePermissionDenied},
		"git command":                 {&git.CommandError{Args: []string{"merge"}, Output: "conflict", ExitCode: 1}, connect.CodeFailedPrecondition},
		"canceled":                    {context.Canceled, connect.CodeCanceled},
		"deadline":                    {fmt.Errorf("wait: %w", context.DeadlineExceeded), connect.CodeDeadlineExceeded},
		"unclassified":                {errors.New("unexpected invariant"), connect.CodeInternal},
		"permission":                  {&os.PathError{Op: "open", Path: "x", Err: os.ErrPermission}, connect.CodePermissionDenied},
		"corrupt json":                {fmt.Errorf("decode snapshot: %w", &json.SyntaxError{}), connect.CodeInternal},
		"domain default":              {domainFailure(errors.New("invalid remote desktop configuration")), connect.CodeInvalidArgument},
		"domain keeps infrastructure": {domainFailure(&os.PathError{Op: "read", Path: "x", Err: syscall.EIO}), connect.CodeInternal},
		"file conflict":               {fileError(409, "%q changed since it was read", "a.txt"), connect.CodeAborted},
		"file too large":              {fileError(413, "file exceeds the limit"), connect.CodeResourceExhausted},
	} {
		t.Run(name, func(t *testing.T) {
			if test.err == nil {
				t.Fatal("fixture error is nil")
			}
			if code := connect.CodeOf(rpcError(test.err)); code != test.code {
				t.Fatalf("code=%s want %s for %v", code, test.code, test.err)
			}
		})
	}
	if rpcError(nil) != nil {
		t.Fatal("nil error was mapped")
	}
}

// codeOf is the gRPC code a client receives for a handler error.
func codeOf(err error) codes.Code { return codes.Code(connect.CodeOf(rpcError(err))) }

func connectError(t *testing.T, err error) *connect.Error {
	t.Helper()
	var failure *connect.Error
	if !errors.As(err, &failure) {
		t.Fatalf("not a Connect error: %v", err)
	}
	return failure
}
