package server

import (
	"context"
	"errors"
	"fmt"
	"os"

	"connectrpc.com/connect"
	"github.com/dbpprt/dieter/internal/compatibility"
	"github.com/dbpprt/dieter/internal/gen/dieter/v1/dieterv1connect"
	"github.com/dbpprt/dieter/internal/store"
)

const clientReleaseHeader = "x-dieter-client-version"

type clientCompatibilityInterceptor struct {
	store *store.Store
}

func (i *clientCompatibilityInterceptor) check(procedure, release string) error {
	if procedure == dieterv1connect.DieterServiceHealthProcedure {
		return nil
	}
	policy, err := i.store.GatewayCompatibilityPolicy()
	if errors.Is(err, os.ErrNotExist) {
		// A new or unenrolled daemon has no authenticated gateway policy yet.
		// Health remains available so clients can bootstrap that state.
		return nil
	}
	if err != nil {
		return connect.NewError(connect.CodeUnavailable, fmt.Errorf("load gateway compatibility policy: %w", err))
	}
	state, current := compatibility.Evaluate(release, policy.MinimumClientVersion)
	if state == compatibility.StatusCompatible {
		return nil
	}
	if current == "" {
		current = release
	}
	return connect.NewError(connect.CodeFailedPrecondition, fmt.Errorf(
		"Dieter client update required by daemon: installed %q, minimum %s", current, policy.MinimumClientVersion,
	))
}

func (i *clientCompatibilityInterceptor) WrapUnary(next connect.UnaryFunc) connect.UnaryFunc {
	return func(ctx context.Context, request connect.AnyRequest) (connect.AnyResponse, error) {
		if err := i.check(request.Spec().Procedure, request.Header().Get(clientReleaseHeader)); err != nil {
			return nil, err
		}
		return next(ctx, request)
	}
}

func (i *clientCompatibilityInterceptor) WrapStreamingClient(next connect.StreamingClientFunc) connect.StreamingClientFunc {
	return next
}

func (i *clientCompatibilityInterceptor) WrapStreamingHandler(next connect.StreamingHandlerFunc) connect.StreamingHandlerFunc {
	return func(ctx context.Context, stream connect.StreamingHandlerConn) error {
		if err := i.check(stream.Spec().Procedure, stream.RequestHeader().Get(clientReleaseHeader)); err != nil {
			return err
		}
		return next(ctx, stream)
	}
}
