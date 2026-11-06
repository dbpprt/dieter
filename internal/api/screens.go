package api

import (
	"context"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/types/known/emptypb"
)

func (api *screensAPI) ProbeRemoteDesktopPermissions(ctx context.Context, request *dieterv1.ProbeRemoteDesktopPermissionsRequest) (*dieterv1.RemoteDesktopPermissionProbe, error) {
	value, err := api.server.remoteDesktop.ProbePermissions(ctx, request.GetRequestControl())
	if err != nil {
		return nil, domainFailure(err)
	}
	return value, nil
}

func (api *screensAPI) GetRemoteDesktopCapabilities(context.Context, *emptypb.Empty) (*dieterv1.RemoteDesktopCapabilities, error) {
	return api.server.remoteDesktop.Capabilities(), nil
}

func (s *Server) startRemoteDesktop(ctx context.Context, request *dieterv1.StartRemoteDesktopRequest) (*remotedesktop.Subscription, error) {
	subject := remoteDesktopOperator(ctx)
	// The raw loopback API has full local access and no gateway transport
	// subject. The manager still verifies the gateway signature, daemon,
	// generation and expiry before admitting this configuration's subject.
	if subject == "" {
		subject = request.GetRtcConfiguration().GetOperatorSubject()
	}
	subscription, err := s.remoteDesktop.Start(request, subject)
	if err != nil {
		return nil, domainFailure(err)
	}
	return subscription, nil
}

func (api *screensAPI) StartRemoteDesktop(ctx context.Context, request *dieterv1.StartRemoteDesktopRequest, stream *connect.ServerStream[dieterv1.RemoteDesktopSignal]) error {
	// connect-go terminates the gRPC HTTP/2 request, so transport metadata is
	// available as headers rather than grpc/metadata on this adapter boundary.
	ctx = operatorContext(ctx)
	subscription, err := api.server.startRemoteDesktop(ctx, request)
	if err != nil {
		return err
	}
	defer subscription.Close()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
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

func (api *screensAPI) SendRemoteDesktopSignal(_ context.Context, request *dieterv1.RemoteDesktopSignal) (*emptypb.Empty, error) {
	if err := api.server.remoteDesktop.Signal(request); err != nil {
		return nil, domainFailure(err)
	}
	return &emptypb.Empty{}, nil
}

func (api *screensAPI) GetRemoteDesktopSession(_ context.Context, request *dieterv1.RemoteDesktopRef) (*dieterv1.RemoteDesktopSessionState, error) {
	state, err := api.server.remoteDesktop.SessionState(request.GetSessionId())
	if err != nil {
		return nil, domainFailure(err)
	}
	return state, nil
}

func (api *screensAPI) ListRemoteDesktopSessions(context.Context, *emptypb.Empty) (*dieterv1.RemoteDesktopSessions, error) {
	return api.server.remoteDesktop.Sessions(), nil
}

func (api *screensAPI) SetRemoteDesktopControl(ctx context.Context, request *dieterv1.RemoteDesktopControlRequest) (*dieterv1.RemoteDesktopSessionState, error) {
	state, err := api.server.remoteDesktop.SetControl(ctx, request.GetSessionId(), request.GetTakeControl())
	if err != nil {
		return nil, domainFailure(err)
	}
	return state, nil
}

func (api *screensAPI) UpdateRemoteDesktopSession(ctx context.Context, request *dieterv1.UpdateRemoteDesktopSessionRequest) (*dieterv1.RemoteDesktopSessionState, error) {
	state, err := api.server.remoteDesktop.UpdateSession(ctx, request)
	if err != nil {
		return nil, domainFailure(err)
	}
	return state, nil
}

func (api *screensAPI) CloseRemoteDesktop(_ context.Context, request *dieterv1.RemoteDesktopRef) (*emptypb.Empty, error) {
	if err := api.server.remoteDesktop.Close(request.GetSessionId(), "closed by client"); err != nil {
		return nil, domainFailure(err)
	}
	return &emptypb.Empty{}, nil
}

func (api *screensAPI) ExchangeRemoteDesktopClipboard(ctx context.Context, request *dieterv1.RemoteDesktopClipboardRequest) (*dieterv1.RemoteDesktopClipboardResponse, error) {
	value, err := api.server.remoteDesktop.ExchangeClipboard(ctx, request)
	if err != nil {
		return nil, domainFailure(err)
	}
	return value, nil
}

func (api *screensAPI) ListRemoteDesktopDisplayModes(ctx context.Context, r *dieterv1.RemoteDesktopRef) (*dieterv1.RemoteDesktopDisplayModes, error) {
	value, err := api.server.remoteDesktop.ListDisplayModes(ctx, r.GetSessionId())
	if err != nil {
		return nil, domainFailure(err)
	}
	return value, nil
}

func (api *screensAPI) SetRemoteDesktopDisplayMode(ctx context.Context, r *dieterv1.SetRemoteDesktopDisplayModeRequest) (*dieterv1.RemoteDesktopDisplayModes, error) {
	value, err := api.server.remoteDesktop.SetDisplayMode(ctx, r)
	if err != nil {
		return nil, domainFailure(err)
	}
	return value, nil
}

func (api *screensAPI) RestoreRemoteDesktopDisplayMode(ctx context.Context, r *dieterv1.RemoteDesktopRef) (*dieterv1.RemoteDesktopDisplayModes, error) {
	value, err := api.server.remoteDesktop.RestoreDisplayMode(ctx, r.GetSessionId())
	if err != nil {
		return nil, domainFailure(err)
	}
	return value, nil
}

func (api *screensAPI) GetRemoteDesktopVirtualDisplay(ctx context.Context, r *dieterv1.RemoteDesktopRef) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
	value, err := api.server.remoteDesktop.GetVirtualDisplay(ctx, r.GetSessionId())
	if err != nil {
		return nil, domainFailure(err)
	}
	return value, nil
}

func (api *screensAPI) SetRemoteDesktopVirtualDisplay(ctx context.Context, r *dieterv1.SetRemoteDesktopVirtualDisplayRequest) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
	value, err := api.server.remoteDesktop.SetVirtualDisplay(ctx, r)
	if err != nil {
		return nil, domainFailure(err)
	}
	return value, nil
}

func (api *screensAPI) ConfirmRemoteDesktopVirtualDisplay(ctx context.Context, r *dieterv1.ConfirmRemoteDesktopVirtualDisplayRequest) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
	value, err := api.server.remoteDesktop.ConfirmVirtualDisplay(ctx, r)
	if err != nil {
		return nil, domainFailure(err)
	}
	return value, nil
}

func (api *screensAPI) RestoreRemoteDesktopVirtualDisplay(ctx context.Context, r *dieterv1.RemoteDesktopRef) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
	value, err := api.server.remoteDesktop.RestoreVirtualDisplay(ctx, r.GetSessionId())
	if err != nil {
		return nil, domainFailure(err)
	}
	return value, nil
}

const operatorSubjectMetadata = "x-dieter-operator-subject"

type remoteDesktopOperatorKey struct{}

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
