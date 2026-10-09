package server

import (
	"context"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

func (api *grpcAPI) GetRemoteDesktopVirtualDisplay(ctx context.Context, r *dieterv1.RemoteDesktopRef) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
	value, err := api.server.remoteDesktop.GetVirtualDisplay(ctx, r.GetSessionId())
	if err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return value, nil
}
func (api *connectAPI) GetRemoteDesktopVirtualDisplay(ctx context.Context, r *connect.Request[dieterv1.RemoteDesktopRef]) (*connect.Response[dieterv1.RemoteDesktopVirtualDisplay], error) {
	return connectUnary(ctx, r, api.core.GetRemoteDesktopVirtualDisplay)
}
func (api *grpcAPI) SetRemoteDesktopVirtualDisplay(ctx context.Context, r *dieterv1.SetRemoteDesktopVirtualDisplayRequest) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
	value, err := api.server.remoteDesktop.SetVirtualDisplay(ctx, r)
	if err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return value, nil
}
func (api *connectAPI) SetRemoteDesktopVirtualDisplay(ctx context.Context, r *connect.Request[dieterv1.SetRemoteDesktopVirtualDisplayRequest]) (*connect.Response[dieterv1.RemoteDesktopVirtualDisplay], error) {
	return connectUnary(ctx, r, api.core.SetRemoteDesktopVirtualDisplay)
}
func (api *grpcAPI) ConfirmRemoteDesktopVirtualDisplay(ctx context.Context, r *dieterv1.ConfirmRemoteDesktopVirtualDisplayRequest) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
	value, err := api.server.remoteDesktop.ConfirmVirtualDisplay(ctx, r)
	if err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return value, nil
}
func (api *connectAPI) ConfirmRemoteDesktopVirtualDisplay(ctx context.Context, r *connect.Request[dieterv1.ConfirmRemoteDesktopVirtualDisplayRequest]) (*connect.Response[dieterv1.RemoteDesktopVirtualDisplay], error) {
	return connectUnary(ctx, r, api.core.ConfirmRemoteDesktopVirtualDisplay)
}
func (api *grpcAPI) RestoreRemoteDesktopVirtualDisplay(ctx context.Context, r *dieterv1.RemoteDesktopRef) (*dieterv1.RemoteDesktopVirtualDisplay, error) {
	value, err := api.server.remoteDesktop.RestoreVirtualDisplay(ctx, r.GetSessionId())
	if err != nil {
		return nil, remoteDesktopFailure(err)
	}
	return value, nil
}
func (api *connectAPI) RestoreRemoteDesktopVirtualDisplay(ctx context.Context, r *connect.Request[dieterv1.RemoteDesktopRef]) (*connect.Response[dieterv1.RemoteDesktopVirtualDisplay], error) {
	return connectUnary(ctx, r, api.core.RestoreRemoteDesktopVirtualDisplay)
}
