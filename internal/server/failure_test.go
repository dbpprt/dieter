package server

import (
	"fmt"
	"os"
	"syscall"
	"testing"

	"connectrpc.com/connect"
	"github.com/dbpprt/dieter/internal/app"
	"github.com/dbpprt/dieter/internal/harness"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestConnectFailurePreservesGRPCDetails(t *testing.T) {
	info := &errdetails.ErrorInfo{Reason: "causal_conflict", Domain: "dieter.peer", Metadata: map[string]string{"kind": "project-settings", "id": "rejected"}}
	value, err := status.New(codes.InvalidArgument, "record rejected").WithDetails(info)
	if err != nil {
		t.Fatal(err)
	}
	failure := connectFailure(value.Err()).(*connect.Error)
	if failure.Code() != connect.CodeInvalidArgument || failure.Message() != value.Message() || len(failure.Details()) != 1 {
		t.Fatalf("Connect dropped status: %v", failure)
	}
	decoded, err := failure.Details()[0].Value()
	if err != nil || !proto.Equal(decoded, info) {
		t.Fatalf("Connect changed rich status: %v, %v", decoded, err)
	}
}

func TestInsufficientStorageMapsToResourceExhausted(t *testing.T) {
	for _, cause := range []error{app.ErrInsufficientStorage, syscall.ENOSPC, syscall.EDQUOT} {
		t.Run(cause.Error(), func(t *testing.T) {
			err := fmt.Errorf("save command: %w", &os.PathError{Op: "write", Path: "fixture", Err: cause})
			failure := grpcFailure(err)
			if code := status.Code(failure); code != codes.ResourceExhausted {
				t.Fatalf("grpc code=%s", code)
			}
			if status.Convert(failure).Message() != err.Error() {
				t.Fatalf("lost actionable storage detail: %v", failure)
			}
			if code := connect.CodeOf(connectFailure(failure)); code != connect.CodeResourceExhausted {
				t.Fatalf("connect code=%s", code)
			}
		})
	}
}

func TestHarnessCatalogDiscoveryFailureMapsToUnavailable(t *testing.T) {
	err := fmt.Errorf("%w: fixture", harness.ErrCatalogUnavailable)
	if code := status.Code(grpcFailure(err)); code != codes.Unavailable {
		t.Fatalf("grpc code=%s", code)
	}
}
