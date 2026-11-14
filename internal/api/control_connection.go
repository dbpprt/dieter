package api

import (
	"context"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/types/known/emptypb"
)

func (api *controlAPI) StartControlConnection(ctx context.Context, r *dieterv1.StartControlConnectionRequest) (*dieterv1.ControlConnection, error) {
	ctx = operatorContext(ctx)
	owner := remoteDesktopOperator(ctx)
	if owner == "" {
		owner = r.GetRtcConfiguration().GetOperatorSubject()
	}
	return api.server.controlRTC.Start(ctx, r, owner)
}

func (api *controlAPI) GetControlConnection(ctx context.Context, r *dieterv1.ControlConnectionRef) (*dieterv1.ControlConnection, error) {
	ctx = operatorContext(ctx)
	return api.server.controlRTC.Get(r.GetSessionId(), remoteDesktopOperator(ctx))
}

func (api *controlAPI) CloseControlConnection(ctx context.Context, r *dieterv1.ControlConnectionRef) (*emptypb.Empty, error) {
	ctx = operatorContext(ctx)
	err := api.server.controlRTC.CloseSession(r.GetSessionId(), remoteDesktopOperator(ctx))
	return &emptypb.Empty{}, err
}
