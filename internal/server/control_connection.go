package server

import (
	"context"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/types/known/emptypb"
)

func (api *grpcAPI) StartControlConnection(ctx context.Context, r *dieterv1.StartControlConnectionRequest) (*dieterv1.ControlConnection, error) {
	owner := remoteDesktopOperator(ctx)
	if owner == "" {
		owner = r.GetRtcConfiguration().GetOperatorSubject()
	}
	return api.server.controlRTC.Start(ctx, r, owner)
}
func (api *grpcAPI) GetControlConnection(ctx context.Context, r *dieterv1.ControlConnectionRef) (*dieterv1.ControlConnection, error) {
	return api.server.controlRTC.Get(r.GetSessionId(), remoteDesktopOperator(ctx))
}
func (api *grpcAPI) CloseControlConnection(ctx context.Context, r *dieterv1.ControlConnectionRef) (*emptypb.Empty, error) {
	err := api.server.controlRTC.CloseSession(r.GetSessionId(), remoteDesktopOperator(ctx))
	return &emptypb.Empty{}, err
}
func controlOperatorContext[T any](ctx context.Context, r *connect.Request[T]) context.Context {
	return context.WithValue(ctx, remoteDesktopOperatorKey{}, r.Header().Get(operatorSubjectMetadata))
}
func (api *connectAPI) StartControlConnection(ctx context.Context, r *connect.Request[dieterv1.StartControlConnectionRequest]) (*connect.Response[dieterv1.ControlConnection], error) {
	return connectUnary(controlOperatorContext(ctx, r), r, api.core.StartControlConnection)
}
func (api *connectAPI) GetControlConnection(ctx context.Context, r *connect.Request[dieterv1.ControlConnectionRef]) (*connect.Response[dieterv1.ControlConnection], error) {
	return connectUnary(controlOperatorContext(ctx, r), r, api.core.GetControlConnection)
}
func (api *connectAPI) CloseControlConnection(ctx context.Context, r *connect.Request[dieterv1.ControlConnectionRef]) (*connect.Response[emptypb.Empty], error) {
	return connectUnary(controlOperatorContext(ctx, r), r, api.core.CloseControlConnection)
}
