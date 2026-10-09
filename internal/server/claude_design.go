package server

import (
	"context"
	"errors"
	"os/exec"
	"path/filepath"

	"connectrpc.com/connect"
	"github.com/dbpprt/dieter/internal/claudedesign"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

type claudeDesignCommander interface {
	ClaudeDesignCommand(ctx context.Context, operation, stateRoot string) (*exec.Cmd, error)
}

// claudeDesignHost drives Claude Code from the pinned harness runtime. Test
// runners without that runtime report Claude Design as unavailable.
func claudeDesignHost(runner harness.Runner, root string) claudedesign.Host {
	commander, ok := runner.(claudeDesignCommander)
	if !ok {
		return claudedesign.Unavailable("Claude Design needs Dieter's Claude Code runtime on this machine.")
	}
	stateRoot := filepath.Join(root, "runtime", "claude-design")
	return claudedesign.NewProcessHost(func(ctx context.Context, operation string) (*exec.Cmd, error) {
		return commander.ClaudeDesignCommand(ctx, operation, stateRoot)
	})
}

func protoClaudeDesignStatus(value claudedesign.Snapshot) *dieterv1.ClaudeDesignStatus {
	return &dieterv1.ClaudeDesignStatus{
		Available: value.Available, SignedIn: value.SignedIn, CanSignIn: value.CanSignIn,
		AccessEnabled: value.AccessEnabled, AccessUpdatedAt: value.AccessUpdatedAt, Reason: value.Reason,
		ClaudeCodeVersion: value.Version, RuntimeReady: value.RuntimeReady, SignInActive: value.SignInActive,
	}
}

func claudeDesignFailure(err error) error {
	var precondition claudedesign.FailedPrecondition
	switch {
	case err == nil:
		return nil
	case errors.Is(err, claudedesign.ErrInvalidCode):
		return status.Error(codes.InvalidArgument, err.Error())
	case errors.Is(err, claudedesign.ErrNoSignIn):
		return status.Error(codes.NotFound, err.Error())
	case errors.Is(err, claudedesign.ErrCodePending):
		return status.Error(codes.FailedPrecondition, err.Error())
	case errors.As(err, &precondition):
		return status.Error(codes.FailedPrecondition, precondition.Message)
	default:
		return grpcFailure(err)
	}
}

func (api *grpcAPI) GetClaudeDesignStatus(ctx context.Context, _ *emptypb.Empty) (*dieterv1.ClaudeDesignStatus, error) {
	value, err := api.server.claudeDesign.Status(ctx)
	if err != nil {
		return nil, claudeDesignFailure(err)
	}
	return protoClaudeDesignStatus(value), nil
}

func (api *grpcAPI) SignInClaudeDesign(request *dieterv1.SignInClaudeDesignRequest, stream dieterv1.DieterService_SignInClaudeDesignServer) error {
	return api.signInClaudeDesign(stream.Context(), request, stream.Send)
}

func (api *grpcAPI) signInClaudeDesign(ctx context.Context, _ *dieterv1.SignInClaudeDesignRequest, send func(*dieterv1.ClaudeDesignSignInEvent) error) error {
	return claudeDesignFailure(api.server.claudeDesign.SignIn(ctx, func(event claudedesign.Event) error {
		frame := &dieterv1.ClaudeDesignSignInEvent{
			SignInId: event.SignInID, Preparing: event.Kind == "preparing", Url: event.URL, ManualUrl: event.ManualURL,
			ManualFirst: event.ManualFirst, Done: event.Kind == "done", Ok: event.OK, Message: event.Message,
		}
		if event.Snapshot != nil {
			frame.Status = protoClaudeDesignStatus(*event.Snapshot)
		}
		return send(frame)
	}))
}

func (api *grpcAPI) SubmitClaudeDesignSignInCode(_ context.Context, request *dieterv1.SubmitClaudeDesignSignInCodeRequest) (*emptypb.Empty, error) {
	if err := api.server.claudeDesign.SubmitCode(request.GetSignInId(), request.GetCode()); err != nil {
		return nil, claudeDesignFailure(err)
	}
	return &emptypb.Empty{}, nil
}

func (api *grpcAPI) SetClaudeDesignAccess(ctx context.Context, request *dieterv1.SetClaudeDesignAccessRequest) (*dieterv1.ClaudeDesignStatus, error) {
	if request.GetEnabled() && request.GetRevokeGrant() {
		return nil, status.Error(codes.InvalidArgument, "revoke_grant applies only when disabling Claude Design")
	}
	value, err := api.server.claudeDesign.SetAccess(ctx, request.GetEnabled(), request.GetRevokeGrant())
	if err != nil {
		return nil, claudeDesignFailure(err)
	}
	return protoClaudeDesignStatus(value), nil
}

func (api *connectAPI) GetClaudeDesignStatus(ctx context.Context, request *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.ClaudeDesignStatus], error) {
	return connectUnary(ctx, request, api.core.GetClaudeDesignStatus)
}

func (api *connectAPI) SignInClaudeDesign(ctx context.Context, request *connect.Request[dieterv1.SignInClaudeDesignRequest], stream *connect.ServerStream[dieterv1.ClaudeDesignSignInEvent]) error {
	return connectFailure(api.core.signInClaudeDesign(ctx, request.Msg, stream.Send))
}

func (api *connectAPI) SubmitClaudeDesignSignInCode(ctx context.Context, request *connect.Request[dieterv1.SubmitClaudeDesignSignInCodeRequest]) (*connect.Response[emptypb.Empty], error) {
	return connectUnary(ctx, request, api.core.SubmitClaudeDesignSignInCode)
}

func (api *connectAPI) SetClaudeDesignAccess(ctx context.Context, request *connect.Request[dieterv1.SetClaudeDesignAccessRequest]) (*connect.Response[dieterv1.ClaudeDesignStatus], error) {
	return connectUnary(ctx, request, api.core.SetClaudeDesignAccess)
}
