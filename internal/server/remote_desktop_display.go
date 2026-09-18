package server

import (
	"context"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

func (api *grpcAPI) ListRemoteDesktopDisplayModes(ctx context.Context, r *dieterv1.RemoteDesktopRef) (*dieterv1.RemoteDesktopDisplayModes, error) {
	value, err := api.server.remoteDesktop.ListDisplayModes(ctx, r.GetSessionId())
	if err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return value, nil
}
func (api *grpcAPI) SetRemoteDesktopDisplayMode(ctx context.Context, r *dieterv1.SetRemoteDesktopDisplayModeRequest) (*dieterv1.RemoteDesktopDisplayModes, error) {
	value, err := api.server.remoteDesktop.SetDisplayMode(ctx, r)
	if err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return value, nil
}
func (api *grpcAPI) RestoreRemoteDesktopDisplayMode(ctx context.Context, r *dieterv1.RemoteDesktopRef) (*dieterv1.RemoteDesktopDisplayModes, error) {
	value, err := api.server.remoteDesktop.RestoreDisplayMode(ctx, r.GetSessionId())
	if err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return value, nil
}
func (api *connectAPI) ListRemoteDesktopDisplayModes(ctx context.Context, r *connect.Request[dieterv1.RemoteDesktopRef]) (*connect.Response[dieterv1.RemoteDesktopDisplayModes], error) {
	return connectUnary(ctx, r, api.core.ListRemoteDesktopDisplayModes)
}
func (api *connectAPI) SetRemoteDesktopDisplayMode(ctx context.Context, r *connect.Request[dieterv1.SetRemoteDesktopDisplayModeRequest]) (*connect.Response[dieterv1.RemoteDesktopDisplayModes], error) {
	return connectUnary(ctx, r, api.core.SetRemoteDesktopDisplayMode)
}
func (api *connectAPI) RestoreRemoteDesktopDisplayMode(ctx context.Context, r *connect.Request[dieterv1.RemoteDesktopRef]) (*connect.Response[dieterv1.RemoteDesktopDisplayModes], error) {
	return connectUnary(ctx, r, api.core.RestoreRemoteDesktopDisplayMode)
}
