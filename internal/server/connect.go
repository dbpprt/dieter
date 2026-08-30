package server

import (
	"context"
	"errors"
	"io/fs"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/terminal"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

// connectAPI is Dieter's only network application boundary. connect-go serves
// this adapter using Connect and native protobuf gRPC over the same handler.
type connectAPI struct {
	core *grpcAPI
}

func connectUnary[I, O any](ctx context.Context, request *connect.Request[I], call func(context.Context, *I) (*O, error)) (*connect.Response[O], error) {
	value, err := call(ctx, request.Msg)
	if err != nil {
		return nil, connectFailure(err)
	}
	return connect.NewResponse(value), nil
}

func (api *connectAPI) Health(ctx context.Context, request *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.HealthResponse], error) {
	return connectUnary(ctx, request, api.core.Health)
}

func (api *connectAPI) GetRuntimeStatus(ctx context.Context, request *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.RuntimeStatus], error) {
	return connectUnary(ctx, request, api.core.GetRuntimeStatus)
}

func (api *connectAPI) GetMachineInformation(ctx context.Context, request *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.MachineInformation], error) {
	return connectUnary(ctx, request, api.core.GetMachineInformation)
}

func (api *connectAPI) PerformMachineOperation(ctx context.Context, request *connect.Request[dieterv1.MachineOperationRequest]) (*connect.Response[dieterv1.MachineOperationResponse], error) {
	return connectUnary(ctx, request, api.core.PerformMachineOperation)
}

func (api *connectAPI) GetState(ctx context.Context, request *connect.Request[dieterv1.GetStateRequest]) (*connect.Response[dieterv1.State], error) {
	return connectUnary(ctx, request, api.core.GetState)
}

func (api *connectAPI) WatchState(ctx context.Context, request *connect.Request[dieterv1.WatchStateRequest], stream *connect.ServerStream[dieterv1.State]) error {
	if err := api.core.watchState(ctx, request.Msg, stream.Send); err != nil {
		return connectFailure(err)
	}
	return nil
}

func (api *connectAPI) WatchSync(ctx context.Context, request *connect.Request[dieterv1.SyncRequest], stream *connect.ServerStream[dieterv1.SyncFrame]) error {
	if err := api.core.watchSync(ctx, request.Msg, stream.Send); err != nil {
		return connectFailure(err)
	}
	return nil
}

func boundedInterval(milliseconds int32, fallback time.Duration) time.Duration {
	interval := time.Duration(milliseconds) * time.Millisecond
	if interval <= 0 {
		interval = fallback
	}
	if interval < 100*time.Millisecond {
		return 100 * time.Millisecond
	}
	if interval > 5*time.Second {
		return 5 * time.Second
	}
	return interval
}

func (api *connectAPI) GetHarnesses(ctx context.Context, request *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.HarnessCatalog], error) {
	return connectUnary(ctx, request, api.core.GetHarnesses)
}

func protoSettings(value model.Settings) *dieterv1.Settings {
	agents := make(map[string]int32, len(value.AgentParallelLimits))
	for key, limit := range value.AgentParallelLimits {
		agents[key] = int32(limit)
	}
	boards := make(map[string]int32, len(value.BoardParallelLimits))
	for key, limit := range value.BoardParallelLimits {
		boards[key] = int32(limit)
	}
	return &dieterv1.Settings{GlobalParallelLimit: int32(value.GlobalParallelLimit), AgentParallelLimits: agents, BoardParallelLimits: boards, UpdatedAt: value.UpdatedAt}
}

func modelSettings(value *dieterv1.Settings) model.Settings {
	result := model.Settings{AgentParallelLimits: map[string]int{}, BoardParallelLimits: map[string]int{}}
	if value == nil {
		return result
	}
	result.GlobalParallelLimit = int(value.GetGlobalParallelLimit())
	result.UpdatedAt = value.GetUpdatedAt()
	for key, limit := range value.GetAgentParallelLimits() {
		result.AgentParallelLimits[key] = int(limit)
	}
	for key, limit := range value.GetBoardParallelLimits() {
		result.BoardParallelLimits[key] = int(limit)
	}
	return result
}

func (api *connectAPI) GetSettings(ctx context.Context, request *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.Settings], error) {
	return connectUnary(ctx, request, api.core.GetSettings)
}

func (api *connectAPI) GetSettingsOptions(ctx context.Context, request *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.SettingsOptions], error) {
	return connectUnary(ctx, request, api.core.GetSettingsOptions)
}

func (api *connectAPI) UpdateSettings(ctx context.Context, request *connect.Request[dieterv1.UpdateSettingsRequest]) (*connect.Response[dieterv1.Settings], error) {
	return connectUnary(ctx, request, api.core.UpdateSettings)
}

func protoPromptSettings(value model.Settings) *dieterv1.PromptSettings {
	value = dieterprompt.NormalizeSettings(value)
	return &dieterv1.PromptSettings{PromptTemplate: value.PromptTemplate, BoardSkillTemplate: value.BoardSkillTemplate, ChatSkillTemplate: value.ChatSkillTemplate, Variables: dieterprompt.Variables()}
}

func (api *connectAPI) GetPromptSettings(ctx context.Context, request *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.PromptSettings], error) {
	return connectUnary(ctx, request, api.core.GetPromptSettings)
}

func (api *connectAPI) UpdatePromptSettings(ctx context.Context, request *connect.Request[dieterv1.UpdatePromptSettingsRequest]) (*connect.Response[dieterv1.PromptSettings], error) {
	return connectUnary(ctx, request, api.core.UpdatePromptSettings)
}

func (api *connectAPI) SetProjectPromptTemplate(ctx context.Context, request *connect.Request[dieterv1.SetScopedPromptTemplateRequest]) (*connect.Response[dieterv1.Project], error) {
	return connectUnary(ctx, request, api.core.SetProjectPromptTemplate)
}

func (api *connectAPI) SetBoardPromptTemplate(ctx context.Context, request *connect.Request[dieterv1.SetScopedPromptTemplateRequest]) (*connect.Response[dieterv1.Board], error) {
	return connectUnary(ctx, request, api.core.SetBoardPromptTemplate)
}

func (api *connectAPI) PreviewPrompt(ctx context.Context, request *connect.Request[dieterv1.PreviewPromptRequest]) (*connect.Response[dieterv1.PromptPreview], error) {
	return connectUnary(ctx, request, api.core.PreviewPrompt)
}

func (api *connectAPI) ListDirectories(ctx context.Context, request *connect.Request[dieterv1.ListDirectoriesRequest]) (*connect.Response[dieterv1.DirectoryListing], error) {
	return connectUnary(ctx, request, api.core.ListDirectories)
}

func (api *connectAPI) CreateProject(ctx context.Context, request *connect.Request[dieterv1.CreateProjectRequest]) (*connect.Response[dieterv1.CreateProjectResponse], error) {
	return connectUnary(ctx, request, api.core.CreateProject)
}

func (api *connectAPI) UpdateProject(ctx context.Context, request *connect.Request[dieterv1.UpdateProjectRequest]) (*connect.Response[dieterv1.Project], error) {
	return connectUnary(ctx, request, api.core.UpdateProject)
}

func (api *connectAPI) UpdateProjectWorkspaceSettings(ctx context.Context, request *connect.Request[dieterv1.UpdateProjectWorkspaceSettingsRequest]) (*connect.Response[dieterv1.Project], error) {
	return connectUnary(ctx, request, api.core.UpdateProjectWorkspaceSettings)
}

func (api *connectAPI) ArchiveProject(ctx context.Context, request *connect.Request[dieterv1.ArchiveProjectRequest]) (*connect.Response[dieterv1.Project], error) {
	return connectUnary(ctx, request, api.core.ArchiveProject)
}

func (api *connectAPI) ListArchivedProjects(ctx context.Context, request *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.ProjectsResponse], error) {
	return connectUnary(ctx, request, api.core.ListArchivedProjects)
}

func (api *connectAPI) CreateBoard(ctx context.Context, request *connect.Request[dieterv1.CreateBoardRequest]) (*connect.Response[dieterv1.Board], error) {
	return connectUnary(ctx, request, api.core.CreateBoard)
}

func (api *connectAPI) RenameBoard(ctx context.Context, request *connect.Request[dieterv1.RenameBoardRequest]) (*connect.Response[dieterv1.Board], error) {
	return connectUnary(ctx, request, api.core.RenameBoard)
}

func (api *connectAPI) SetBoardArchivePolicy(ctx context.Context, request *connect.Request[dieterv1.SetBoardArchivePolicyRequest]) (*connect.Response[dieterv1.Board], error) {
	return connectUnary(ctx, request, api.core.SetBoardArchivePolicy)
}

func (api *connectAPI) ListArchivedCards(ctx context.Context, request *connect.Request[dieterv1.BoardRef]) (*connect.Response[dieterv1.CardsResponse], error) {
	return connectUnary(ctx, request, api.core.ListArchivedCards)
}

func (api *connectAPI) CreateBoardLabel(ctx context.Context, request *connect.Request[dieterv1.CreateBoardLabelRequest]) (*connect.Response[dieterv1.Board], error) {
	return connectUnary(ctx, request, api.core.CreateBoardLabel)
}

func (api *connectAPI) UpdateBoardLabel(ctx context.Context, request *connect.Request[dieterv1.UpdateBoardLabelRequest]) (*connect.Response[dieterv1.Board], error) {
	return connectUnary(ctx, request, api.core.UpdateBoardLabel)
}

func (api *connectAPI) DeleteBoardLabel(ctx context.Context, request *connect.Request[dieterv1.DeleteBoardLabelRequest]) (*connect.Response[dieterv1.Board], error) {
	return connectUnary(ctx, request, api.core.DeleteBoardLabel)
}

func (api *connectAPI) CreateCard(ctx context.Context, request *connect.Request[dieterv1.CreateConversationRequest]) (*connect.Response[dieterv1.Card], error) {
	return connectUnary(ctx, request, api.core.CreateCard)
}

func (api *connectAPI) CreateChat(ctx context.Context, request *connect.Request[dieterv1.CreateConversationRequest]) (*connect.Response[dieterv1.Card], error) {
	return connectUnary(ctx, request, api.core.CreateChat)
}

func (api *connectAPI) ForkChat(ctx context.Context, request *connect.Request[dieterv1.ForkChatRequest]) (*connect.Response[dieterv1.Card], error) {
	return connectUnary(ctx, request, api.core.ForkChat)
}

func (api *connectAPI) ListChats(ctx context.Context, request *connect.Request[dieterv1.ListChatsRequest]) (*connect.Response[dieterv1.ChatsResponse], error) {
	return connectUnary(ctx, request, api.core.ListChats)
}

func (api *connectAPI) GetCard(ctx context.Context, request *connect.Request[dieterv1.GetCardRequest]) (*connect.Response[dieterv1.CardDetail], error) {
	return connectUnary(ctx, request, api.core.GetCard)
}

func (api *connectAPI) GetConversation(ctx context.Context, request *connect.Request[dieterv1.GetConversationRequest]) (*connect.Response[dieterv1.ConversationSnapshot], error) {
	return connectUnary(ctx, request, api.core.GetConversation)
}

func (api *connectAPI) PollConversation(ctx context.Context, request *connect.Request[dieterv1.PollConversationRequest]) (*connect.Response[dieterv1.ConversationUpdate], error) {
	return connectUnary(ctx, request, api.core.PollConversation)
}

func (api *connectAPI) WatchConversation(ctx context.Context, request *connect.Request[dieterv1.WatchConversationRequest], stream *connect.ServerStream[dieterv1.ConversationUpdate]) error {
	return connectFailure(api.core.watchConversation(ctx, request.Msg, stream.Send))
}

func (api *connectAPI) GetToolOutput(ctx context.Context, request *connect.Request[dieterv1.GetToolOutputRequest]) (*connect.Response[dieterv1.ToolOutput], error) {
	return connectUnary(ctx, request, api.core.GetToolOutput)
}

func (api *connectAPI) SendMessage(ctx context.Context, request *connect.Request[dieterv1.SendMessageRequest]) (*connect.Response[dieterv1.SendMessageResponse], error) {
	return connectUnary(ctx, request, api.core.SendMessage)
}

func (api *connectAPI) AddComment(ctx context.Context, request *connect.Request[dieterv1.AddCommentRequest]) (*connect.Response[dieterv1.Comment], error) {
	return connectUnary(ctx, request, api.core.AddComment)
}

func (api *connectAPI) MoveCard(ctx context.Context, request *connect.Request[dieterv1.MoveCardRequest]) (*connect.Response[dieterv1.Card], error) {
	return connectUnary(ctx, request, api.core.MoveCard)
}

func (api *connectAPI) StartCard(ctx context.Context, request *connect.Request[dieterv1.StartCardRequest]) (*connect.Response[dieterv1.StartCardResponse], error) {
	return connectUnary(ctx, request, api.core.StartCard)
}

func (api *connectAPI) SetCardLabels(ctx context.Context, request *connect.Request[dieterv1.SetCardLabelsRequest]) (*connect.Response[dieterv1.Card], error) {
	return connectUnary(ctx, request, api.core.SetCardLabels)
}

func (api *connectAPI) CancelCard(ctx context.Context, request *connect.Request[dieterv1.GetCardRequest]) (*connect.Response[emptypb.Empty], error) {
	return connectUnary(ctx, request, api.core.CancelCard)
}

func (api *connectAPI) RenameCard(ctx context.Context, request *connect.Request[dieterv1.RenameCardRequest]) (*connect.Response[dieterv1.Card], error) {
	return connectUnary(ctx, request, api.core.RenameCard)
}

func (api *connectAPI) UpdateCard(ctx context.Context, request *connect.Request[dieterv1.UpdateCardRequest]) (*connect.Response[dieterv1.Card], error) {
	return connectUnary(ctx, request, api.core.UpdateCard)
}

func (api *connectAPI) ArchiveCard(ctx context.Context, request *connect.Request[dieterv1.ArchiveCardRequest]) (*connect.Response[dieterv1.Card], error) {
	return connectUnary(ctx, request, api.core.ArchiveCard)
}

func (api *connectAPI) PinChat(ctx context.Context, request *connect.Request[dieterv1.PinChatRequest]) (*connect.Response[dieterv1.Card], error) {
	return connectUnary(ctx, request, api.core.PinChat)
}

func (api *connectAPI) ListFiles(ctx context.Context, request *connect.Request[dieterv1.ListFilesRequest]) (*connect.Response[dieterv1.FileList], error) {
	return connectUnary(ctx, request, api.core.ListFiles)
}

func (api *connectAPI) ReadFile(ctx context.Context, request *connect.Request[dieterv1.ReadFileRequest]) (*connect.Response[dieterv1.FileDocument], error) {
	return connectUnary(ctx, request, api.core.ReadFile)
}

func (api *connectAPI) SaveFile(ctx context.Context, request *connect.Request[dieterv1.SaveFileRequest]) (*connect.Response[dieterv1.FileDocument], error) {
	return connectUnary(ctx, request, api.core.SaveFile)
}

func (api *connectAPI) CreateFile(ctx context.Context, request *connect.Request[dieterv1.CreateFileRequest]) (*connect.Response[dieterv1.FileEntry], error) {
	return connectUnary(ctx, request, api.core.CreateFile)
}

func (api *connectAPI) MoveFile(ctx context.Context, request *connect.Request[dieterv1.MoveFileRequest]) (*connect.Response[dieterv1.MoveFileResponse], error) {
	return connectUnary(ctx, request, api.core.MoveFile)
}

func (api *connectAPI) DeleteFile(ctx context.Context, request *connect.Request[dieterv1.DeleteFileRequest]) (*connect.Response[emptypb.Empty], error) {
	return connectUnary(ctx, request, api.core.DeleteFile)
}

func (api *connectAPI) ListSchedules(ctx context.Context, request *connect.Request[dieterv1.ListSchedulesRequest]) (*connect.Response[dieterv1.SchedulesResponse], error) {
	return connectUnary(ctx, request, api.core.ListSchedules)
}

func (api *connectAPI) PreviewSchedule(ctx context.Context, request *connect.Request[dieterv1.PreviewScheduleRequest]) (*connect.Response[dieterv1.SchedulePreview], error) {
	return connectUnary(ctx, request, api.core.PreviewSchedule)
}

func (api *connectAPI) CreateSchedule(ctx context.Context, request *connect.Request[dieterv1.SaveScheduleRequest]) (*connect.Response[dieterv1.Schedule], error) {
	return connectUnary(ctx, request, api.core.CreateSchedule)
}

func (api *connectAPI) UpdateSchedule(ctx context.Context, request *connect.Request[dieterv1.SaveScheduleRequest]) (*connect.Response[dieterv1.Schedule], error) {
	return connectUnary(ctx, request, api.core.UpdateSchedule)
}

func (api *connectAPI) DeleteSchedule(ctx context.Context, request *connect.Request[dieterv1.ScheduleRef]) (*connect.Response[emptypb.Empty], error) {
	return connectUnary(ctx, request, api.core.DeleteSchedule)
}

func (api *connectAPI) RunSchedule(ctx context.Context, request *connect.Request[dieterv1.ScheduleRef]) (*connect.Response[dieterv1.ScheduleRun], error) {
	return connectUnary(ctx, request, api.core.RunSchedule)
}

func (api *connectAPI) SetScheduleEnabled(ctx context.Context, request *connect.Request[dieterv1.SetScheduleEnabledRequest]) (*connect.Response[dieterv1.Schedule], error) {
	return connectUnary(ctx, request, api.core.SetScheduleEnabled)
}

func (api *connectAPI) ListScheduleRuns(ctx context.Context, request *connect.Request[dieterv1.ListScheduleRunsRequest]) (*connect.Response[dieterv1.ScheduleRunsResponse], error) {
	return connectUnary(ctx, request, api.core.ListScheduleRuns)
}

func connectFailure(err error) error {
	if err == nil {
		return nil
	}
	if connectErr := new(connect.Error); errors.As(err, &connectErr) {
		return err
	}
	grpcStatus, ok := status.FromError(err)
	if ok && grpcStatus.Code() != codes.Unknown {
		return connect.NewError(connectCode(grpcStatus.Code()), errors.New(grpcStatus.Message()))
	}
	code := connect.CodeInvalidArgument
	switch {
	case errors.Is(err, context.Canceled):
		code = connect.CodeCanceled
	case errors.Is(err, context.DeadlineExceeded):
		code = connect.CodeDeadlineExceeded
	case errors.Is(err, store.ErrNotFound), errors.Is(err, fs.ErrNotExist):
		code = connect.CodeNotFound
	case errors.Is(err, store.ErrCapacity):
		code = connect.CodeResourceExhausted
	case errors.Is(err, store.ErrCardActive):
		code = connect.CodeFailedPrecondition
	case errors.Is(err, terminal.ErrNotFound):
		code = connect.CodeNotFound
	case errors.Is(err, terminal.ErrNotRunning):
		code = connect.CodeFailedPrecondition
	case errors.Is(err, terminal.ErrLimitReached):
		code = connect.CodeResourceExhausted
	}
	return connect.NewError(code, err)
}

func connectCode(code codes.Code) connect.Code {
	switch code {
	case codes.Canceled:
		return connect.CodeCanceled
	case codes.InvalidArgument:
		return connect.CodeInvalidArgument
	case codes.DeadlineExceeded:
		return connect.CodeDeadlineExceeded
	case codes.NotFound:
		return connect.CodeNotFound
	case codes.AlreadyExists:
		return connect.CodeAlreadyExists
	case codes.PermissionDenied:
		return connect.CodePermissionDenied
	case codes.ResourceExhausted:
		return connect.CodeResourceExhausted
	case codes.FailedPrecondition:
		return connect.CodeFailedPrecondition
	case codes.Aborted:
		return connect.CodeAborted
	case codes.OutOfRange:
		return connect.CodeOutOfRange
	case codes.Unimplemented:
		return connect.CodeUnimplemented
	case codes.Internal:
		return connect.CodeInternal
	case codes.Unavailable:
		return connect.CodeUnavailable
	case codes.Unauthenticated:
		return connect.CodeUnauthenticated
	default:
		return connect.CodeUnknown
	}
}
