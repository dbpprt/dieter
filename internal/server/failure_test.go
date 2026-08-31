package server

import (
	"fmt"
	"testing"

	"github.com/dbpprt/dieter/internal/app"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestInsufficientStorageMapsToResourceExhausted(t *testing.T) {
	err := fmt.Errorf("%w: fixture", app.ErrInsufficientStorage)
	if code := status.Code(grpcFailure(err)); code != codes.ResourceExhausted {
		t.Fatalf("grpc code=%s", code)
	}
}
