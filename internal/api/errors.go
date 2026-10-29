package api

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"syscall"

	"connectrpc.com/connect"
	"github.com/dbpprt/dieter/internal/git"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/replica"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"modernc.org/sqlite"
)

// errorInterceptor is the one place where handler errors become RPC status
// codes, for unary and streaming RPCs alike.
type errorInterceptor struct{}

func (errorInterceptor) WrapUnary(next connect.UnaryFunc) connect.UnaryFunc {
	return func(ctx context.Context, request connect.AnyRequest) (connect.AnyResponse, error) {
		response, err := next(ctx, request)
		return response, rpcError(err)
	}
}

func (errorInterceptor) WrapStreamingClient(next connect.StreamingClientFunc) connect.StreamingClientFunc {
	return next
}

func (errorInterceptor) WrapStreamingHandler(next connect.StreamingHandlerFunc) connect.StreamingHandlerFunc {
	return func(ctx context.Context, conn connect.StreamingHandlerConn) error {
		return rpcError(next(ctx, conn))
	}
}

// rpcError maps err to a Connect error. Explicit classifications win: an
// existing Connect or gRPC status, cancellation, a fault kind, then the few
// standard-library and storage conditions with a defined meaning. Every
// other error is an internal failure the caller may retry.
func rpcError(err error) error {
	if err == nil {
		return nil
	}
	if connectErr := new(connect.Error); errors.As(err, &connectErr) {
		return err
	}
	if grpcStatus, ok := status.FromError(err); ok && grpcStatus.Code() != codes.Unknown {
		failure := connect.NewError(connect.Code(grpcStatus.Code()), errors.New(grpcStatus.Message()))
		for _, value := range grpcStatus.Proto().GetDetails() {
			if detail, detailErr := connect.NewErrorDetail(value); detailErr == nil {
				failure.AddDetail(detail)
			}
		}
		return failure
	}
	failure := connect.NewError(rpcCode(err), err)
	var record *replica.PeerRecordError
	if errors.As(err, &record) {
		info := &errdetails.ErrorInfo{Reason: record.Code, Domain: "dieter.peer", Metadata: map[string]string{"kind": record.Kind, "id": record.ID, "field": record.Field}}
		if detail, detailErr := connect.NewErrorDetail(info); detailErr == nil {
			failure.AddDetail(detail)
		}
	}
	return failure
}

func rpcCode(err error) connect.Code {
	switch {
	case errors.Is(err, context.Canceled):
		return connect.CodeCanceled
	case errors.Is(err, context.DeadlineExceeded):
		return connect.CodeDeadlineExceeded
	}
	if kind, ok := fault.KindOf(err); ok {
		return kindCode(kind)
	}
	var record *replica.PeerRecordError
	var command *git.CommandError
	switch {
	case errors.As(err, &record):
		return connect.CodeInvalidArgument
	case errors.Is(err, syscall.ENOSPC), errors.Is(err, syscall.EDQUOT):
		return connect.CodeResourceExhausted
	case errors.Is(err, fs.ErrNotExist):
		return connect.CodeNotFound
	case errors.Is(err, fs.ErrPermission):
		return connect.CodePermissionDenied
	case errors.As(err, &command):
		// A failed Git command reflects the repository's current state.
		return connect.CodeFailedPrecondition
	}
	return connect.CodeInternal
}

func kindCode(kind fault.Kind) connect.Code {
	switch kind {
	case fault.Invalid:
		return connect.CodeInvalidArgument
	case fault.NotFound:
		return connect.CodeNotFound
	case fault.AlreadyExists:
		return connect.CodeAlreadyExists
	case fault.FailedPrecondition:
		return connect.CodeFailedPrecondition
	case fault.PermissionDenied:
		return connect.CodePermissionDenied
	case fault.Conflict:
		return connect.CodeAborted
	case fault.ResourceExhausted:
		return connect.CodeResourceExhausted
	case fault.Unavailable:
		return connect.CodeUnavailable
	case fault.Unimplemented:
		return connect.CodeUnimplemented
	case fault.DataLoss:
		return connect.CodeDataLoss
	case fault.Unauthenticated:
		return connect.CodeUnauthenticated
	case fault.OutOfRange:
		return connect.CodeOutOfRange
	default:
		return connect.CodeInternal
	}
}

// domainFailure classifies an error of a domain whose unclassified errors
// reject the request (remote desktop, peer records, vault). Infrastructure
// failures and errors with an explicit kind keep their meaning.
func domainFailure(err error) error {
	if err == nil {
		return nil
	}
	if _, ok := fault.KindOf(err); ok || infrastructureFailure(err) {
		return err
	}
	if grpcStatus, ok := status.FromError(err); ok && grpcStatus.Code() != codes.Unknown {
		return err
	}
	return fault.Wrap(fault.Invalid, err)
}

// infrastructureFailure reports an error raised by the host rather than by
// Dieter's validation: cancellation, I/O, process, codec, and SQLite failures.
func infrastructureFailure(err error) bool {
	var (
		pathErr    *fs.PathError
		linkErr    *os.LinkError
		syscallErr *os.SyscallError
		errno      syscall.Errno
		exitErr    *exec.ExitError
		syntaxErr  *json.SyntaxError
		typeErr    *json.UnmarshalTypeError
		sqliteErr  *sqlite.Error
	)
	return errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) ||
		errors.As(err, &pathErr) || errors.As(err, &linkErr) || errors.As(err, &syscallErr) ||
		errors.As(err, &errno) || errors.As(err, &exitErr) || errors.As(err, &syntaxErr) ||
		errors.As(err, &typeErr) || errors.As(err, &sqliteErr)
}

// fileError is a project file failure with the HTTP-style status of the
// condition; the kind decides its RPC code.
func fileError(statusCode int, format string, args ...any) error {
	kind := fault.Invalid
	switch statusCode {
	case http.StatusForbidden:
		kind = fault.PermissionDenied
	case http.StatusNotFound:
		kind = fault.NotFound
	case http.StatusConflict:
		kind = fault.Conflict
	case http.StatusRequestEntityTooLarge:
		kind = fault.ResourceExhausted
	}
	return fault.Errorf(kind, format, args...)
}
