package api

import (
	"context"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
)

func (api *boardsAPI) GetBoard(_ context.Context, request *dieterv1.BoardRef) (*dieterv1.Board, error) {
	board, err := api.server.store.GetBoard(request.GetBoardId())
	if err != nil {
		return nil, err
	}
	return protoBoard(board), nil
}

func (api *boardsAPI) ListRetiredBoards(_ context.Context, request *dieterv1.ListRetiredBoardsRequest) (*dieterv1.ListRetiredBoardsResponse, error) {
	page, err := api.server.store.ListRetiredBoards(request.GetProjectId(), request.GetAfterId(), request.GetSnapshotRevision(), int(request.GetPageSize()))
	if err != nil {
		return nil, err
	}
	response := &dieterv1.ListRetiredBoardsResponse{NextId: page.NextID, SnapshotRevision: page.Revision}
	for _, board := range page.Boards {
		response.Boards = append(response.Boards, protoBoard(board))
	}
	return response, nil
}

func (api *boardsAPI) SetBoardRetired(_ context.Context, request *dieterv1.SetBoardRetiredRequest) (*dieterv1.Board, error) {
	board, err := api.server.store.SetBoardRetired(store.BoardRetirementInput{BoardID: request.GetBoardId(), Retired: request.GetRetired(), ExpectedRevision: request.GetExpectedRevision(), OperationID: request.GetOperationId()})
	if err != nil {
		return nil, err
	}
	return protoBoard(board), nil
}

func (api *boardsAPI) RenameBoard(_ context.Context, request *dieterv1.RenameBoardRequest) (*dieterv1.Board, error) {
	value, err := api.server.store.RenameBoard(request.GetBoardId(), request.GetName())
	if err != nil {
		return nil, err
	}
	return protoBoard(value), nil
}

func (api *boardsAPI) CreateBoard(_ context.Context, request *dieterv1.CreateBoardRequest) (*dieterv1.Board, error) {
	value, err := api.server.store.CreateBoard(store.CreateBoardInput{
		Project: request.GetProjectId(), Name: request.GetName(), Workflow: request.GetWorkflow(),
		Description: request.GetDescription(), DoneArchivePolicy: request.GetDoneArchivePolicy(),
		BaseRemote: request.GetBaseRemote(), RemotePublishMode: request.GetRemotePublishMode(),
	})
	if err != nil {
		return nil, err
	}
	return protoBoard(value), nil
}

func (api *boardsAPI) UpdateBoardGitSettings(_ context.Context, request *dieterv1.UpdateBoardGitSettingsRequest) (*dieterv1.Board, error) {
	value, err := api.server.store.UpdateBoardGitSettings(
		request.GetBoardId(), request.GetBaseRemote(), request.GetRemotePublishMode(),
	)
	if err != nil {
		return nil, err
	}
	return protoBoard(value), nil
}

func (api *boardsAPI) SetBoardArchivePolicy(_ context.Context, request *dieterv1.SetBoardArchivePolicyRequest) (*dieterv1.Board, error) {
	value, err := api.server.store.UpdateBoardDoneArchivePolicy(request.GetBoardId(), request.GetDoneArchivePolicy())
	if err == nil {
		_, err = api.server.store.ArchiveDoneCards(time.Now())
	}
	if err != nil {
		return nil, err
	}
	return protoBoard(value), nil
}

func (api *boardsAPI) CreateBoardLabel(_ context.Context, request *dieterv1.CreateBoardLabelRequest) (*dieterv1.Board, error) {
	value, err := api.server.store.CreateBoardLabel(
		request.GetBoardId(), request.GetName(), request.GetColor(), request.GetInstructions(),
	)
	if err != nil {
		return nil, err
	}
	return protoBoard(value), nil
}

func (api *boardsAPI) UpdateBoardLabel(_ context.Context, request *dieterv1.UpdateBoardLabelRequest) (*dieterv1.Board, error) {
	value, err := api.server.store.UpdateBoardLabel(
		request.GetBoardId(), request.GetLabelId(), request.GetName(), request.GetColor(), request.GetInstructions(),
	)
	if err != nil {
		return nil, err
	}
	return protoBoard(value), nil
}

func (api *boardsAPI) DeleteBoardLabel(_ context.Context, request *dieterv1.DeleteBoardLabelRequest) (*dieterv1.Board, error) {
	value, err := api.server.store.DeleteBoardLabel(request.GetBoardId(), request.GetLabelId())
	if err != nil {
		return nil, err
	}
	return protoBoard(value), nil
}

func (api *boardsAPI) UpdateBoardHostnames(_ context.Context, request *dieterv1.UpdateBoardHostnamesRequest) (*dieterv1.Board, error) {
	value, err := api.server.store.UpdateBoardHostnames(request.GetBoardId(), request.GetHostnames(), request.GetAppend())
	if err != nil {
		return nil, err
	}
	return protoBoard(value), nil
}
