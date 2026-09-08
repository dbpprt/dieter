package server

import (
	"fmt"
	"testing"

	"github.com/dbpprt/dieter/internal/app"
	"github.com/dbpprt/dieter/internal/harness"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestInsufficientStorageMapsToResourceExhausted(t *testing.T) {
	err := fmt.Errorf("%w: fixture", app.ErrInsufficientStorage)
	if code := status.Code(grpcFailure(err)); code != codes.ResourceExhausted {
		t.Fatalf("grpc code=%s", code)
	}
}

func TestHarnessCatalogDiscoveryFailureMapsToUnavailable(t *testing.T) {
	err := fmt.Errorf("%w: fixture", harness.ErrCatalogUnavailable)
	if code := status.Code(grpcFailure(err)); code != codes.Unavailable {
		t.Fatalf("grpc code=%s", code)
	}
}
