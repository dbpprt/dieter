package server

import (
	"fmt"
	"os"
	"syscall"
	"testing"

	"connectrpc.com/connect"
	"github.com/dbpprt/dieter/internal/app"
	"github.com/dbpprt/dieter/internal/harness"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

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
