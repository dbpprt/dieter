package api

import (
	"context"
	"errors"
	"strings"

	"github.com/dbpprt/dieter/internal/engine"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/home"
	"google.golang.org/protobuf/types/known/emptypb"
)

func (api *projectsAPI) AttachCheckout(ctx context.Context, r *dieterv1.AttachCheckoutRequest) (*dieterv1.Checkout, error) {
	value, err := api.server.store.Kanban.AttachCheckout(r.GetProjectId(), r.GetPath(), r.GetName())
	if err != nil {
		return nil, err
	}
	return protoCheckout(value), nil
}

func (api *projectsAPI) DetachCheckout(ctx context.Context, r *dieterv1.CheckoutRef) (*emptypb.Empty, error) {
	return &emptypb.Empty{}, api.server.store.Kanban.DetachCheckout(r.GetCheckoutId())
}

func (api *projectsAPI) ListCheckouts(ctx context.Context, r *dieterv1.ProjectRef) (*dieterv1.CheckoutsResponse, error) {
	values, err := api.server.store.Kanban.ListCheckouts(r.GetProjectId())
	if err != nil {
		return nil, err
	}
	result := &dieterv1.CheckoutsResponse{}
	for _, value := range values {
		result.Checkouts = append(result.Checkouts, protoCheckout(value))
	}
	return result, nil
}

func (api *projectsAPI) ConsolidateProject(ctx context.Context, r *dieterv1.ConsolidateProjectRequest) (*dieterv1.Project, error) {
	value, err := api.server.store.Kanban.ConsolidateProject(r.GetSourceProjectId(), r.GetDestinationProjectId())
	if err != nil {
		return nil, err
	}
	return protoProject(value), nil
}

func (api *projectsAPI) ListDirectories(_ context.Context, request *dieterv1.ListDirectoriesRequest) (*dieterv1.DirectoryListing, error) {
	listing, err := listProjectDirectories(request.GetPath())
	if err != nil {
		return nil, err
	}
	result := &dieterv1.DirectoryListing{
		Path: listing.Path, Parent: listing.Parent, Name: listing.Name,
		GitRepository: listing.GitRepository, Separator: listing.Separator,
	}
	for _, value := range listing.Entries {
		result.Entries = append(result.Entries, &dieterv1.DirectoryEntry{
			Name: value.Name, Path: value.Path, GitRepository: value.GitRepository, Hidden: value.Hidden,
		})
	}
	for _, value := range listing.Locations {
		result.Locations = append(result.Locations, &dieterv1.DirectoryLocation{Name: value.Name, Path: value.Path, Kind: value.Kind})
	}
	return result, nil
}

func (api *projectsAPI) CreateProject(ctx context.Context, request *dieterv1.CreateProjectRequest) (*dieterv1.CreateProjectResponse, error) {
	mode := strings.TrimSpace(request.GetMode())
	if mode == "" {
		mode = "open"
	}
	if mode != "open" && mode != "create" {
		return nil, fault.New(fault.Invalid, "project mode must be open or create")
	}
	boardName := strings.TrimSpace(request.GetBoardName())
	if boardName == "" {
		boardName = "Main"
	}
	project, err := api.server.app.RegisterProject(ctx, engine.ProjectInput{
		OperationID: request.GetOperationId(), InitialBoardName: boardName, InitialWorkflow: request.GetWorkflow(),
		Path: request.GetPath(), Name: request.GetName(), Summary: request.GetSummary(), Prompt: request.GetPrompt(),
		Create: mode == "create", BaseRemote: request.GetBaseRemote(), BaseBranch: request.GetBaseBranch(),
		ValidationCommands: modelValidationCommands(request.GetValidationCommands()),
	})
	if err != nil {
		return nil, err
	}
	board, err := api.server.store.Kanban.InitialBoard(project.ID)
	if errors.Is(err, home.ErrNotFound) {
		boards, listErr := api.server.store.Kanban.ListBoards(project.ID)
		if listErr != nil {
			return nil, listErr
		}
		if len(boards) == 0 {
			return nil, err
		}
		board, err = boards[0], nil
	}
	if err != nil {
		return nil, err
	}
	return &dieterv1.CreateProjectResponse{Project: protoProject(project), Board: protoBoard(board)}, nil
}

func (api *projectsAPI) UpdateProject(_ context.Context, request *dieterv1.UpdateProjectRequest) (*dieterv1.Project, error) {
	var hostnames *[]string
	if request.Hostnames != nil {
		values := request.Hostnames.GetValues()
		hostnames = &values
	}
	value, err := api.server.store.Kanban.UpdateProjectWithHostnames(request.GetProjectId(), request.Name, request.Summary, request.Prompt, request.Path, hostnames)
	if err != nil {
		return nil, err
	}
	return protoProject(value), nil
}

func (api *projectsAPI) UpdateProjectWorkspaceSettings(_ context.Context, request *dieterv1.UpdateProjectWorkspaceSettingsRequest) (*dieterv1.Project, error) {
	var validation []model.ValidationCommand
	if request.GetCheckoutId() != "" {
		validation = append([]model.ValidationCommand{}, modelValidationCommands(request.GetValidationCommands())...)
	} else if len(request.GetValidationCommands()) > 0 {
		return nil, fault.New(fault.Invalid, "choose a checkout to update its validation commands")
	}
	value, err := api.server.store.Kanban.UpdateProjectWorkspaceSettings(
		request.GetProjectId(), request.GetBaseRemote(), request.GetBaseBranch(), validation, request.GetCheckoutId(),
	)
	if err != nil {
		return nil, err
	}
	return protoProject(value), nil
}

func (api *projectsAPI) ArchiveProject(_ context.Context, request *dieterv1.ArchiveProjectRequest) (*dieterv1.Project, error) {
	value, err := api.server.store.Kanban.ArchiveProject(request.GetProjectId(), request.GetArchived())
	if err != nil {
		return nil, err
	}
	return protoProject(value), nil
}

func (api *projectsAPI) ListArchivedProjects(context.Context, *emptypb.Empty) (*dieterv1.ProjectsResponse, error) {
	values, err := api.server.store.Kanban.ListArchivedProjects()
	if err != nil {
		return nil, err
	}
	result := &dieterv1.ProjectsResponse{}
	for _, value := range values {
		result.Projects = append(result.Projects, protoProject(value))
	}
	return result, nil
}
