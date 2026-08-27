package server

import (
	"context"
	"crypto/sha256"
	"errors"
	"io/fs"
	"net/http"
	"os"
	"path"
	"strings"
	"time"

	"connectrpc.com/connect"
	"github.com/dbpprt/dieter/internal/app"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/terminal"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

// connectAPI is Board's only network application boundary. connect-go serves
// this implementation using Connect for browsers and native gRPC for mobile.
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

func (api *connectAPI) GetRuntimeStatus(context.Context, *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.RuntimeStatus], error) {
	return connect.NewResponse(&dieterv1.RuntimeStatus{Ready: true, Mode: "local-host", Sandboxed: false, NodeRequired: true}), nil
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
	interval := boundedInterval(request.Msg.GetIntervalMs(), time.Second)
	filter := request.Msg.GetFilter()
	if filter == nil {
		filter = &dieterv1.GetStateRequest{}
	}
	var previous [sha256.Size]byte
	sendChanged := func() error {
		value, err := api.core.GetState(ctx, filter)
		if err != nil {
			return connectFailure(err)
		}
		raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(value)
		if err != nil {
			return connectFailure(err)
		}
		digest := sha256.Sum256(raw)
		if digest == previous {
			return nil
		}
		previous = digest
		return stream.Send(value)
	}
	if err := sendChanged(); err != nil {
		return err
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return connectFailure(ctx.Err())
		case <-ticker.C:
			if err := sendChanged(); err != nil {
				return err
			}
		}
	}
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

func (api *connectAPI) GetSettings(context.Context, *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.Settings], error) {
	value, err := api.core.server.store.Settings()
	if err != nil {
		return nil, connectFailure(err)
	}
	return connect.NewResponse(protoSettings(value)), nil
}

func (api *connectAPI) GetSettingsOptions(ctx context.Context, _ *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.SettingsOptions], error) {
	projects, err := api.core.server.store.ListProjects()
	if err != nil {
		return nil, connectFailure(err)
	}
	boards, err := api.core.server.store.ListBoards("")
	if err != nil {
		return nil, connectFailure(err)
	}
	result := &dieterv1.SettingsOptions{Agents: protoHarnessCatalog(harness.RefreshCatalog(ctx, os.Getenv("DIETER_ENABLE_MOCK_HARNESS") == "1"))}
	for _, value := range projects {
		result.Projects = append(result.Projects, protoProject(value))
	}
	for _, value := range boards {
		result.Boards = append(result.Boards, protoBoard(value))
	}
	return connect.NewResponse(result), nil
}

func (api *connectAPI) UpdateSettings(_ context.Context, request *connect.Request[dieterv1.UpdateSettingsRequest]) (*connect.Response[dieterv1.Settings], error) {
	value, err := api.core.server.store.UpdateSettings(modelSettings(request.Msg.GetSettings()))
	if err != nil {
		return nil, connectFailure(err)
	}
	return connect.NewResponse(protoSettings(value)), nil
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

func (api *connectAPI) ListDirectories(_ context.Context, request *connect.Request[dieterv1.ListDirectoriesRequest]) (*connect.Response[dieterv1.DirectoryListing], error) {
	listing, err := listProjectDirectories(request.Msg.GetPath())
	if err != nil {
		return nil, connectFailure(err)
	}
	result := &dieterv1.DirectoryListing{Path: listing.Path, Parent: listing.Parent, Name: listing.Name, GitRepository: listing.GitRepository, Separator: listing.Separator}
	for _, value := range listing.Entries {
		result.Entries = append(result.Entries, &dieterv1.DirectoryEntry{Name: value.Name, Path: value.Path, GitRepository: value.GitRepository, Hidden: value.Hidden})
	}
	for _, value := range listing.Locations {
		result.Locations = append(result.Locations, &dieterv1.DirectoryLocation{Name: value.Name, Path: value.Path, Kind: value.Kind})
	}
	return connect.NewResponse(result), nil
}

func (api *connectAPI) CreateProject(ctx context.Context, request *connect.Request[dieterv1.CreateProjectRequest]) (*connect.Response[dieterv1.CreateProjectResponse], error) {
	input := request.Msg
	project, err := api.core.server.app.RegisterProject(ctx, app.ProjectInput{Path: input.GetPath(), Name: input.GetName(), Summary: input.GetSummary(), Prompt: input.GetPrompt(), Create: input.GetMode() == "create"})
	if err != nil {
		return nil, connectFailure(err)
	}
	boardName := strings.TrimSpace(input.GetBoardName())
	if boardName == "" {
		boardName = "Main"
	}
	board, err := api.core.server.store.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: boardName, Workflow: input.GetWorkflow()})
	if err != nil {
		return nil, connectFailure(err)
	}
	return connect.NewResponse(&dieterv1.CreateProjectResponse{Project: protoProject(project), Board: protoBoard(board)}), nil
}

func (api *connectAPI) UpdateProject(_ context.Context, request *connect.Request[dieterv1.UpdateProjectRequest]) (*connect.Response[dieterv1.Project], error) {
	value, err := api.core.server.store.UpdateProject(request.Msg.GetProjectId(), request.Msg.Name, request.Msg.Summary, request.Msg.Prompt)
	if err != nil {
		return nil, connectFailure(err)
	}
	return connect.NewResponse(protoProject(value)), nil
}

func (api *connectAPI) ArchiveProject(_ context.Context, request *connect.Request[dieterv1.ArchiveProjectRequest]) (*connect.Response[dieterv1.Project], error) {
	value, err := api.core.server.store.ArchiveProject(request.Msg.GetProjectId(), request.Msg.GetArchived())
	if err != nil {
		return nil, connectFailure(err)
	}
	return connect.NewResponse(protoProject(value)), nil
}

func (api *connectAPI) ListArchivedProjects(context.Context, *connect.Request[emptypb.Empty]) (*connect.Response[dieterv1.ProjectsResponse], error) {
	values, err := api.core.server.store.ListArchivedProjects()
	if err != nil {
		return nil, connectFailure(err)
	}
	result := &dieterv1.ProjectsResponse{}
	for _, value := range values {
		result.Projects = append(result.Projects, protoProject(value))
	}
	return connect.NewResponse(result), nil
}

func (api *connectAPI) CreateBoard(_ context.Context, request *connect.Request[dieterv1.CreateBoardRequest]) (*connect.Response[dieterv1.Board], error) {
	input := request.Msg
	value, err := api.core.server.store.CreateBoard(store.CreateBoardInput{Project: input.GetProjectId(), Name: input.GetName(), Workflow: input.GetWorkflow(), Description: input.GetDescription(), DoneArchivePolicy: input.GetDoneArchivePolicy()})
	if err != nil {
		return nil, connectFailure(err)
	}
	return connect.NewResponse(protoBoard(value)), nil
}

func (api *connectAPI) RenameBoard(_ context.Context, request *connect.Request[dieterv1.RenameBoardRequest]) (*connect.Response[dieterv1.Board], error) {
	value, err := api.core.server.store.RenameBoard(request.Msg.GetBoardId(), request.Msg.GetName())
	if err != nil {
		return nil, connectFailure(err)
	}
	return connect.NewResponse(protoBoard(value)), nil
}

func (api *connectAPI) SetBoardArchivePolicy(_ context.Context, request *connect.Request[dieterv1.SetBoardArchivePolicyRequest]) (*connect.Response[dieterv1.Board], error) {
	value, err := api.core.server.store.UpdateBoardDoneArchivePolicy(request.Msg.GetBoardId(), request.Msg.GetDoneArchivePolicy())
	if err == nil {
		_, err = api.core.server.store.ArchiveDoneCards(time.Now())
	}
	if err != nil {
		return nil, connectFailure(err)
	}
	return connect.NewResponse(protoBoard(value)), nil
}

func (api *connectAPI) ListArchivedCards(_ context.Context, request *connect.Request[dieterv1.BoardRef]) (*connect.Response[dieterv1.CardsResponse], error) {
	board, err := api.core.server.store.ResolveBoard("", request.Msg.GetBoardId())
	if err != nil {
		return nil, connectFailure(err)
	}
	values, err := api.core.server.store.ListCards(store.CardFilter{Board: board.ID, Scope: model.ConversationScopeBoard, IncludeArchived: true})
	if err != nil {
		return nil, connectFailure(err)
	}
	result := &dieterv1.CardsResponse{}
	for _, value := range values {
		if value.Archived {
			result.Cards = append(result.Cards, protoCard(value))
		}
	}
	return connect.NewResponse(result), nil
}

func (api *connectAPI) CreateBoardLabel(_ context.Context, request *connect.Request[dieterv1.CreateBoardLabelRequest]) (*connect.Response[dieterv1.Board], error) {
	value, err := api.core.server.store.CreateBoardLabel(request.Msg.GetBoardId(), request.Msg.GetName(), request.Msg.GetColor(), request.Msg.GetInstructions())
	if err != nil {
		return nil, connectFailure(err)
	}
	return connect.NewResponse(protoBoard(value)), nil
}

func (api *connectAPI) UpdateBoardLabel(_ context.Context, request *connect.Request[dieterv1.UpdateBoardLabelRequest]) (*connect.Response[dieterv1.Board], error) {
	value, err := api.core.server.store.UpdateBoardLabel(request.Msg.GetBoardId(), request.Msg.GetLabelId(), request.Msg.GetName(), request.Msg.GetColor(), request.Msg.GetInstructions())
	if err != nil {
		return nil, connectFailure(err)
	}
	return connect.NewResponse(protoBoard(value)), nil
}

func (api *connectAPI) DeleteBoardLabel(_ context.Context, request *connect.Request[dieterv1.DeleteBoardLabelRequest]) (*connect.Response[dieterv1.Board], error) {
	value, err := api.core.server.store.DeleteBoardLabel(request.Msg.GetBoardId(), request.Msg.GetLabelId())
	if err != nil {
		return nil, connectFailure(err)
	}
	return connect.NewResponse(protoBoard(value)), nil
}

func (api *connectAPI) CreateCard(ctx context.Context, request *connect.Request[dieterv1.CreateConversationRequest]) (*connect.Response[dieterv1.Card], error) {
	return connectUnary(ctx, request, api.core.CreateCard)
}

func (api *connectAPI) CreateChat(ctx context.Context, request *connect.Request[dieterv1.CreateConversationRequest]) (*connect.Response[dieterv1.Card], error) {
	return connectUnary(ctx, request, api.core.CreateChat)
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

func (api *connectAPI) SaveFile(_ context.Context, request *connect.Request[dieterv1.SaveFileRequest]) (*connect.Response[dieterv1.FileDocument], error) {
	api.core.server.filesMu.Lock()
	defer api.core.server.filesMu.Unlock()
	project, err := api.core.server.store.ResolveProject(request.Msg.GetProjectId())
	if err != nil {
		return nil, connectFailure(err)
	}
	relative, err := cleanProjectPath(request.Msg.GetPath(), false)
	if err != nil {
		return nil, connectFailure(err)
	}
	root, target, err := existingProjectPath(project, relative)
	if err != nil {
		return nil, connectFailure(err)
	}
	if err := ensureNonSymlinkRegular(target, relative); err != nil {
		return nil, connectFailure(err)
	}
	current, err := readLimitedProjectFile(target)
	if err != nil {
		return nil, connectFailure(err)
	}
	if request.Msg.GetRevision() == "" || request.Msg.GetRevision() != projectFileRevision(current) {
		return nil, connectFailure(fileError(http.StatusConflict, "%q changed on disk; reload it before saving", relative))
	}
	content := []byte(request.Msg.GetContent())
	if len(content) > maxProjectFileSize {
		return nil, connectFailure(fileError(http.StatusRequestEntityTooLarge, "file exceeds the %d MiB editor limit", maxProjectFileSize>>20))
	}
	if err := ensureContained(root, target); err != nil {
		return nil, connectFailure(err)
	}
	if err := atomicWriteProjectFile(target, content); err != nil {
		return nil, connectFailure(projectPathIOError(relative, err))
	}
	info, err := os.Stat(target)
	if err != nil {
		return nil, connectFailure(projectPathIOError(relative, err))
	}
	return connect.NewResponse(&dieterv1.FileDocument{Path: relative, Name: path.Base(relative), Size: int64(len(content)), ModifiedAt: info.ModTime().UTC().Format(projectTimeFormat), Revision: projectFileRevision(content), Content: request.Msg.GetContent()}), nil
}

func (api *connectAPI) CreateFile(_ context.Context, request *connect.Request[dieterv1.CreateFileRequest]) (*connect.Response[dieterv1.FileEntry], error) {
	api.core.server.filesMu.Lock()
	defer api.core.server.filesMu.Unlock()
	project, err := api.core.server.store.ResolveProject(request.Msg.GetProjectId())
	if err != nil {
		return nil, connectFailure(err)
	}
	relative, err := cleanProjectPath(request.Msg.GetPath(), false)
	if err != nil {
		return nil, connectFailure(err)
	}
	_, target, err := newProjectPath(project, relative)
	if err != nil {
		return nil, connectFailure(err)
	}
	kind := request.Msg.GetKind()
	if kind != "file" && kind != "directory" {
		return nil, connectFailure(errors.New("kind must be file or directory"))
	}
	content := []byte(request.Msg.GetContent())
	if len(content) > maxProjectFileSize {
		return nil, connectFailure(fileError(http.StatusRequestEntityTooLarge, "file exceeds the %d MiB editor limit", maxProjectFileSize>>20))
	}
	if kind == "directory" {
		err = os.Mkdir(target, 0o755)
	} else {
		err = atomicCreateProjectFile(target, content)
	}
	if err != nil {
		return nil, connectFailure(projectPathIOError(relative, err))
	}
	return connect.NewResponse(&dieterv1.FileEntry{Name: path.Base(relative), Path: relative, Kind: kind, Size: int64(len(content))}), nil
}

func (api *connectAPI) MoveFile(_ context.Context, request *connect.Request[dieterv1.MoveFileRequest]) (*connect.Response[dieterv1.MoveFileResponse], error) {
	api.core.server.filesMu.Lock()
	defer api.core.server.filesMu.Unlock()
	project, err := api.core.server.store.ResolveProject(request.Msg.GetProjectId())
	if err != nil {
		return nil, connectFailure(err)
	}
	sourceRelative, err := cleanProjectPath(request.Msg.GetSource(), false)
	if err != nil {
		return nil, connectFailure(err)
	}
	destinationRelative, err := cleanProjectPath(request.Msg.GetDestination(), false)
	if err != nil {
		return nil, connectFailure(err)
	}
	_, source, err := existingProjectPathNoFollow(project, sourceRelative)
	if err != nil {
		return nil, connectFailure(err)
	}
	_, destination, err := newProjectPath(project, destinationRelative)
	if err != nil {
		return nil, connectFailure(err)
	}
	info, err := os.Lstat(source)
	if err != nil {
		return nil, connectFailure(projectPathIOError(sourceRelative, err))
	}
	if info.IsDir() && (destinationRelative == sourceRelative || strings.HasPrefix(destinationRelative, sourceRelative+"/")) {
		return nil, connectFailure(errors.New("a directory cannot be moved inside itself"))
	}
	if err := os.Rename(source, destination); err != nil {
		return nil, connectFailure(projectPathIOError(sourceRelative, err))
	}
	return connect.NewResponse(&dieterv1.MoveFileResponse{Source: sourceRelative, Destination: destinationRelative}), nil
}

func (api *connectAPI) DeleteFile(_ context.Context, request *connect.Request[dieterv1.DeleteFileRequest]) (*connect.Response[emptypb.Empty], error) {
	api.core.server.filesMu.Lock()
	defer api.core.server.filesMu.Unlock()
	project, err := api.core.server.store.ResolveProject(request.Msg.GetProjectId())
	if err != nil {
		return nil, connectFailure(err)
	}
	relative, err := cleanProjectPath(request.Msg.GetPath(), false)
	if err != nil {
		return nil, connectFailure(err)
	}
	_, target, err := existingProjectPathNoFollow(project, relative)
	if err != nil {
		return nil, connectFailure(err)
	}
	info, err := os.Lstat(target)
	if err != nil {
		return nil, connectFailure(projectPathIOError(relative, err))
	}
	if info.IsDir() {
		if !request.Msg.GetRecursive() {
			return nil, connectFailure(errors.New("deleting a directory requires recursive=true"))
		}
		err = os.RemoveAll(target)
	} else {
		err = os.Remove(target)
	}
	if err != nil {
		return nil, connectFailure(projectPathIOError(relative, err))
	}
	return connect.NewResponse(&emptypb.Empty{}), nil
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
