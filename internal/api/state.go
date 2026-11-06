package api

import (
	"context"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store/kanban"
)

func (api *stateAPI) WatchChanges(ctx context.Context, request *dieterv1.ChangesRequest, stream *connect.ServerStream[dieterv1.ChangesFrame]) error {
	return api.server.watchChanges(ctx, request, stream.Send)
}

func (api *stateAPI) GetState(ctx context.Context, request *dieterv1.GetStateRequest) (*dieterv1.State, error) {
	if request.GetAllProjects() {
		value, err := api.server.store.Kanban.GlobalStateContext(ctx)
		if err != nil {
			return nil, err
		}
		return protoState(value), nil
	}
	value, err := api.server.store.Kanban.State(request.GetProjectId(), kanban.CardFilter{
		Board: request.GetBoardId(), Lane: request.GetLane(), Runtime: request.GetRuntime(),
		Query: request.GetQuery(), Label: request.GetLabelId(), Limit: int(request.GetLimit()),
	})
	if err != nil {
		return nil, err
	}
	return protoState(value), nil
}
