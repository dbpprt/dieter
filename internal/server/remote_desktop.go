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

type remoteDesktopOperatorKey struct{}

func (api *grpcAPI) GetRemoteDesktopCapabilities(context.Context, *emptypb.Empty) (*dieterv1.RemoteDesktopCapabilities, error) {
	settings, err := api.server.store.Settings()
	if err != nil {
		return nil, grpcFailure(err)
	}
	return api.server.remoteDesktop.Capabilities(settings.RemoteDesktopEnabled, settings.RemoteDesktopControlEnabled), nil
}

func (api *grpcAPI) GetRemoteDesktopSettings(context.Context, *emptypb.Empty) (*dieterv1.RemoteDesktopSettings, error) {
	settings, err := api.server.store.Settings()
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoRemoteDesktopSettings(settings.RemoteDesktopEnabled, settings.RemoteDesktopControlEnabled, settings.UpdatedAt), nil
}

func (api *grpcAPI) UpdateRemoteDesktopSettings(_ context.Context, request *dieterv1.UpdateRemoteDesktopSettingsRequest) (*dieterv1.RemoteDesktopSettings, error) {
	settings, err := api.server.store.UpdateRemoteDesktopSettings(request.GetEnabled(), request.GetControlEnabled())
	if err != nil {
		return nil, grpcFailure(err)
	}
	if !settings.RemoteDesktopEnabled {
		api.server.remoteDesktop.CloseActive("remote desktop disabled")
	} else if !settings.RemoteDesktopControlEnabled {
		api.server.remoteDesktop.CloseControlActive("remote desktop control disabled")
	}
	return protoRemoteDesktopSettings(settings.RemoteDesktopEnabled, settings.RemoteDesktopControlEnabled, settings.UpdatedAt), nil
}

func (api *grpcAPI) StartRemoteDesktop(ctx context.Context, request *dieterv1.StartRemoteDesktopRequest) (*remotedesktop.Subscription, error) {
	settings, err := api.server.store.Settings()
	if err != nil {
		return nil, grpcFailure(err)
	}
	subscription, err := api.server.remoteDesktop.Start(request, settings.RemoteDesktopEnabled, settings.RemoteDesktopControlEnabled, remoteDesktopOperator(ctx))
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

func (api *grpcAPI) CloseRemoteDesktop(_ context.Context, request *dieterv1.RemoteDesktopRef) (*emptypb.Empty, error) {
	if err := api.server.remoteDesktop.Close(request.GetSessionId(), "closed by client"); err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return &emptypb.Empty{}, nil
}

func (api *connectAPI) GetRemoteDesktopCapabilities(ctx context.Context, request *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.RemoteDesktopCapabilities], error) {
	return connectUnary(ctx, request, api.core.GetRemoteDesktopCapabilities)
}

func (api *connectAPI) GetRemoteDesktopSettings(ctx context.Context, request *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.RemoteDesktopSettings], error) {
	return connectUnary(ctx, request, api.core.GetRemoteDesktopSettings)
}

func (api *connectAPI) UpdateRemoteDesktopSettings(ctx context.Context, request *connect.Request[dieterv1.UpdateRemoteDesktopSettingsRequest]) (*connect.Response[dieterv1.RemoteDesktopSettings], error) {
	return connectUnary(ctx, request, api.core.UpdateRemoteDesktopSettings)
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

func protoRemoteDesktopSettings(enabled, controlEnabled bool, updatedAt string) *dieterv1.RemoteDesktopSettings {
	return &dieterv1.RemoteDesktopSettings{Enabled: enabled, ControlEnabled: enabled && controlEnabled, UpdatedAt: updatedAt}
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
	case errors.Is(err, remotedesktop.ErrDisabled), errors.Is(err, remotedesktop.ErrControlDisabled):
		return status.Error(codes.FailedPrecondition, err.Error())
	case errors.Is(err, remotedesktop.ErrBusy):
		return status.Error(codes.ResourceExhausted, err.Error())
	case errors.Is(err, remotedesktop.ErrNotFound):
		return status.Error(codes.NotFound, err.Error())
	case errors.Is(err, remotedesktop.ErrInvalidSignal):
		return status.Error(codes.InvalidArgument, err.Error())
	default:
		return status.Error(codes.InvalidArgument, err.Error())
	}
}
