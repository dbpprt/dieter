package server

import (
	"context"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
)

func (api *grpcAPI) GetBoard(_ context.Context, request *dieterv1.BoardRef) (*dieterv1.Board, error) {
	board, err := api.server.store.GetBoard(request.GetBoardId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoBoard(board), nil
}

func (api *grpcAPI) ListRetiredBoards(_ context.Context, request *dieterv1.ListRetiredBoardsRequest) (*dieterv1.ListRetiredBoardsResponse, error) {
	page, err := api.server.store.ListRetiredBoards(request.GetProjectId(), request.GetAfterId(), request.GetSnapshotRevision(), int(request.GetPageSize()))
	if err != nil {
		return nil, grpcFailure(err)
	}
	response := &dieterv1.ListRetiredBoardsResponse{NextId: page.NextID, SnapshotRevision: page.Revision}
	for _, board := range page.Boards {
		response.Boards = append(response.Boards, protoBoard(board))
	}
	return response, nil
}

func (api *grpcAPI) SetBoardRetired(_ context.Context, request *dieterv1.SetBoardRetiredRequest) (*dieterv1.Board, error) {
	board, err := api.server.store.SetBoardRetired(store.BoardRetirementInput{BoardID: request.GetBoardId(), Retired: request.GetRetired(), ExpectedRevision: request.GetExpectedRevision(), OperationID: request.GetOperationId()})
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoBoard(board), nil
}

func (api *connectAPI) GetBoard(ctx context.Context, request *connect.Request[dieterv1.BoardRef]) (*connect.Response[dieterv1.Board], error) {
	return connectUnary(controlOperatorContext(ctx, request), request, api.core.GetBoard)
}
func (api *connectAPI) ListRetiredBoards(ctx context.Context, request *connect.Request[dieterv1.ListRetiredBoardsRequest]) (*connect.Response[dieterv1.ListRetiredBoardsResponse], error) {
	return connectUnary(controlOperatorContext(ctx, request), request, api.core.ListRetiredBoards)
}
func (api *connectAPI) SetBoardRetired(ctx context.Context, request *connect.Request[dieterv1.SetBoardRetiredRequest]) (*connect.Response[dieterv1.Board], error) {
	return connectUnary(controlOperatorContext(ctx, request), request, api.core.SetBoardRetired)
}
