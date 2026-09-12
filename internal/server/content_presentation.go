package server

import (
	"context"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
)

func (api *grpcAPI) PresentConversationContent(ctx context.Context, request *dieterv1.PresentConversationContentRequest) (*dieterv1.ContentPresentation, error) {
	value, err := api.server.app.PresentConversationContent(ctx, request.GetCardId(), "", model.ContentPresentation{
		Path: request.GetPath(), URL: request.GetUrl(), Line: int(request.GetLine()), Title: request.GetTitle(),
	})
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoContentPresentation(&value), nil
}

func (api *connectAPI) PresentConversationContent(ctx context.Context, request *connect.Request[dieterv1.PresentConversationContentRequest]) (*connect.Response[dieterv1.ContentPresentation], error) {
	return connectUnary(ctx, request, api.core.PresentConversationContent)
}
