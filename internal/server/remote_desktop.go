package server

import (
	"context"
	"errors"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

const operatorSubjectMetadata = "x-dieter-operator-subject"

func (api *grpcAPI) ProbeRemoteDesktopPermissions(ctx context.Context, request *dieterv1.ProbeRemoteDesktopPermissionsRequest) (*dieterv1.RemoteDesktopPermissionProbe, error) {
	value, err := api.server.remoteDesktop.ProbePermissions(ctx, request.GetRequestControl())
	if err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return value, nil
}

func (api *connectAPI) ProbeRemoteDesktopPermissions(ctx context.Context, request *connect.Request[dieterv1.ProbeRemoteDesktopPermissionsRequest]) (*connect.Response[dieterv1.RemoteDesktopPermissionProbe], error) {
	return connectUnary(ctx, request, api.core.ProbeRemoteDesktopPermissions)
}

type remoteDesktopOperatorKey struct{}

func (api *grpcAPI) GetRemoteDesktopCapabilities(context.Context, *emptypb.Empty) (*dieterv1.RemoteDesktopCapabilities, error) {
	return api.server.remoteDesktop.Capabilities(), nil
}

func (api *grpcAPI) StartRemoteDesktop(ctx context.Context, request *dieterv1.StartRemoteDesktopRequest) (*remotedesktop.Subscription, error) {
	subject := remoteDesktopOperator(ctx)
	// The raw loopback API has full local access and no gateway transport
	// subject. The manager still verifies the gateway signature, daemon,
	// generation and expiry before admitting this configuration's subject.
	if subject == "" {
		subject = request.GetRtcConfiguration().GetOperatorSubject()
	}
	subscription, err := api.server.remoteDesktop.Start(request, subject)
	if err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return subscription, nil
}

func (api *grpcAPI) SendRemoteDesktopSignal(_ context.Context, request *dieterv1.RemoteDesktopSignal) (*emptypb.Empty, error) {
	if err := api.server.remoteDesktop.Signal(request); err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return &emptypb.Empty{}, nil
}

func (api *grpcAPI) GetRemoteDesktopSession(_ context.Context, request *dieterv1.RemoteDesktopRef) (*dieterv1.RemoteDesktopSessionState, error) {
	state, err := api.server.remoteDesktop.SessionState(request.GetSessionId())
	if err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return state, nil
}

func (api *grpcAPI) ListRemoteDesktopSessions(context.Context, *emptypb.Empty) (*dieterv1.RemoteDesktopSessions, error) {
	return api.server.remoteDesktop.Sessions(), nil
}

func (api *grpcAPI) SetRemoteDesktopControl(ctx context.Context, request *dieterv1.RemoteDesktopControlRequest) (*dieterv1.RemoteDesktopSessionState, error) {
	state, err := api.server.remoteDesktop.SetControl(ctx, request.GetSessionId(), request.GetTakeControl())
	if err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return state, nil
}

func (api *connectAPI) ListRemoteDesktopSessions(ctx context.Context, request *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.RemoteDesktopSessions], error) {
	return connectUnary(ctx, request, api.core.ListRemoteDesktopSessions)
}

func (api *connectAPI) SetRemoteDesktopControl(ctx context.Context, request *connect.Request[dieterv1.RemoteDesktopControlRequest]) (*connect.Response[dieterv1.RemoteDesktopSessionState], error) {
	return connectUnary(ctx, request, api.core.SetRemoteDesktopControl)
}
func (api *grpcAPI) UpdateRemoteDesktopSession(ctx context.Context, request *dieterv1.UpdateRemoteDesktopSessionRequest) (*dieterv1.RemoteDesktopSessionState, error) {
	state, err := api.server.remoteDesktop.UpdateSession(ctx, request)
	if err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return state, nil
}
func (api *connectAPI) GetRemoteDesktopSession(ctx context.Context, request *connect.Request[dieterv1.RemoteDesktopRef]) (*connect.Response[dieterv1.RemoteDesktopSessionState], error) {
	return connectUnary(ctx, request, api.core.GetRemoteDesktopSession)
}
func (api *connectAPI) UpdateRemoteDesktopSession(ctx context.Context, request *connect.Request[dieterv1.UpdateRemoteDesktopSessionRequest]) (*connect.Response[dieterv1.RemoteDesktopSessionState], error) {
	return connectUnary(ctx, request, api.core.UpdateRemoteDesktopSession)
}

func (api *grpcAPI) CloseRemoteDesktop(_ context.Context, request *dieterv1.RemoteDesktopRef) (*emptypb.Empty, error) {
	if err := api.server.remoteDesktop.Close(request.GetSessionId(), "closed by client"); err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return &emptypb.Empty{}, nil
}

func (api *connectAPI) GetRemoteDesktopCapabilities(ctx context.Context, request *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.RemoteDesktopCapabilities], error) {
	return connectUnary(ctx, request, api.core.GetRemoteDesktopCapabilities)
}

func (api *connectAPI) StartRemoteDesktop(ctx context.Context, request *connect.Request[dieterv1.StartRemoteDesktopRequest], stream *connect.ServerStream[dieterv1.RemoteDesktopSignal]) error {
	// connect-go terminates the gRPC HTTP/2 request, so transport metadata is
	// available as headers rather than grpc/metadata on this adapter boundary.
	ctx = context.WithValue(ctx, remoteDesktopOperatorKey{}, request.Header().Get(operatorSubjectMetadata))
	subscription, err := api.core.StartRemoteDesktop(ctx, request.Msg)
	if err != nil {
		return connectFailure(err)
	}
	defer subscription.Close()
	for {
		select {
		case <-ctx.Done():
			return connectFailure(ctx.Err())
		case signal, ok := <-subscription.Signals:
			if !ok {
				return nil
			}
			if err := stream.Send(signal); err != nil {
				return err
			}
		}
	}
}

func (api *connectAPI) SendRemoteDesktopSignal(ctx context.Context, request *connect.Request[dieterv1.RemoteDesktopSignal]) (*connect.Response[emptypb.Empty], error) {
	return connectUnary(ctx, request, api.core.SendRemoteDesktopSignal)
}

func (api *connectAPI) CloseRemoteDesktop(ctx context.Context, request *connect.Request[dieterv1.RemoteDesktopRef]) (*connect.Response[emptypb.Empty], error) {
	return connectUnary(ctx, request, api.core.CloseRemoteDesktop)
}

func remoteDesktopOperator(ctx context.Context) string {
	if value, ok := ctx.Value(remoteDesktopOperatorKey{}).(string); ok && value != "" {
		return value
	}
	values, _ := metadata.FromIncomingContext(ctx)
	items := values.Get(operatorSubjectMetadata)
	if len(items) != 1 {
		return ""
	}
	return items[0]
}

func remoteDesktopFailure(err error) error {
	switch {
	case errors.Is(err, remotedesktop.ErrSessionClosed), errors.Is(err, remotedesktop.ErrControlUnavailable):
		return status.Error(codes.FailedPrecondition, err.Error())
	case errors.Is(err, remotedesktop.ErrBusy):
		return status.Error(codes.ResourceExhausted, err.Error())
	case errors.Is(err, remotedesktop.ErrCapacity), errors.Is(err, remotedesktop.ErrControlOwner):
		return status.Error(codes.FailedPrecondition, err.Error())
	case errors.Is(err, remotedesktop.ErrNotFound):
		return status.Error(codes.NotFound, err.Error())
	case errors.Is(err, remotedesktop.ErrInvalidSignal):
		return status.Error(codes.InvalidArgument, err.Error())
	default:
		return status.Error(codes.InvalidArgument, err.Error())
	}
}

func (api *grpcAPI) ExchangeRemoteDesktopClipboard(ctx context.Context, request *dieterv1.RemoteDesktopClipboardRequest) (*dieterv1.RemoteDesktopClipboardResponse, error) {
	value, err := api.server.remoteDesktop.ExchangeClipboard(ctx, request)
	if err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return value, nil
}
func (api *connectAPI) ExchangeRemoteDesktopClipboard(ctx context.Context, request *connect.Request[dieterv1.RemoteDesktopClipboardRequest]) (*connect.Response[dieterv1.RemoteDesktopClipboardResponse], error) {
	return connectUnary(ctx, request, api.core.ExchangeRemoteDesktopClipboard)
}
