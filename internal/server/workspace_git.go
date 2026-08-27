package server

import (
	"context"
	"strings"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/gitops"
	"github.com/dbpprt/dieter/internal/model"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func (api *grpcAPI) UpdateConversationWorkspace(_ context.Context, request *dieterv1.UpdateConversationWorkspaceRequest) (*dieterv1.Card, error) {
	card, err := api.server.store.UpdateCardWorkspaceSelection(
		request.GetCardId(), request.GetMode(), request.GetBranch(), request.GetBaseBranch(), false,
	)
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoCard(card), nil
}

func (api *grpcAPI) GetWorkspace(ctx context.Context, request *dieterv1.ConversationRef) (*dieterv1.Workspace, error) {
	value, err := api.server.workspaces.Ensure(ctx, request.GetCardId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoWorkspace(value), nil
}

func (api *grpcAPI) ListProjectWorkspaces(_ context.Context, request *dieterv1.ProjectRef) (*dieterv1.WorkspacesResponse, error) {
	values, err := api.server.store.ListWorkspaces(request.GetProjectId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	result := &dieterv1.WorkspacesResponse{}
	for _, value := range values {
		result.Workspaces = append(result.Workspaces, protoWorkspace(value))
	}
	return result, nil
}

func (api *grpcAPI) GetChangeset(ctx context.Context, request *dieterv1.GetChangesetRequest) (*dieterv1.Changeset, error) {
	value, err := api.server.changesets.Get(ctx, request.GetCardId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	if active, leaseErr := api.server.store.CardHasRuntimeLease(request.GetCardId()); leaseErr == nil {
		value.Volatile = active
	}
	return protoChangeset(value), nil
}

func (api *grpcAPI) GetFileDiff(ctx context.Context, request *dieterv1.GetDiffRequest) (*dieterv1.FileDiff, error) {
	value, err := api.server.changesets.FileDiff(
		ctx, request.GetCardId(), request.GetExpectedRevision(), request.GetPath(), "", int(request.GetOffset()), int(request.GetLimit()),
	)
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoFileDiff(value), nil
}

func (api *grpcAPI) GetCommitDiff(ctx context.Context, request *dieterv1.GetDiffRequest) (*dieterv1.FileDiff, error) {
	value, err := api.server.changesets.CommitDiff(
		ctx, request.GetCardId(), request.GetExpectedRevision(), request.GetCommitSha(), request.GetPath(), int(request.GetOffset()), int(request.GetLimit()),
	)
	if err != nil {
		return nil, grpcFailure(err)
	}
	result := protoFileDiff(value)
	result.CommitSha = request.GetCommitSha()
	return result, nil
}

func (api *grpcAPI) AddChangeComment(_ context.Context, request *dieterv1.AddChangeCommentRequest) (*dieterv1.ChangeComment, error) {
	if request.GetRevision() == "" {
		return nil, status.Error(codes.InvalidArgument, "revision is required")
	}
	value, err := api.server.store.AddChangeComment(model.ChangeComment{
		CardID: request.GetCardId(), ChangesetRevision: request.GetRevision(), Path: request.GetPath(),
		Side: request.GetSide(), Line: int(request.GetLine()), Body: request.GetBody(),
		Author: model.Author{Kind: "human", Name: request.GetAuthor()},
	})
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoChangeComment(value), nil
}

func (api *grpcAPI) ListChangeComments(_ context.Context, request *dieterv1.ListChangeCommentsRequest) (*dieterv1.ChangeCommentsResponse, error) {
	values, err := api.server.store.ListChangeComments(request.GetCardId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	result := &dieterv1.ChangeCommentsResponse{}
	for _, value := range values {
		if request.GetRevision() == "" || request.GetRevision() == value.ChangesetRevision {
			result.Comments = append(result.Comments, protoChangeComment(value))
		}
	}
	return result, nil
}

func (api *grpcAPI) GetSCMCapabilities(ctx context.Context, request *dieterv1.ConversationRef) (*dieterv1.SCMCapabilities, error) {
	value, err := api.server.workspaces.Ensure(ctx, request.GetCardId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	capabilities := api.server.gitOperations.SCM.Capabilities(ctx, value.Path, value.BaseRemote)
	return protoSCMCapabilities(capabilities), nil
}

func (api *grpcAPI) StartGitOperation(ctx context.Context, request *dieterv1.StartGitOperationRequest) (*dieterv1.GitOperation, error) {
	value, err := api.server.gitOperations.Start(ctx, gitops.Request{
		CardID: request.GetCardId(), Kind: request.GetKind(), ExpectedRevision: request.GetExpectedRevision(),
		Parameters: cloneProtoStringMap(request.GetParameters()),
	})
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoGitOperation(value), nil
}

func (api *grpcAPI) GetGitOperation(_ context.Context, request *dieterv1.GitOperationRef) (*dieterv1.GitOperation, error) {
	value, err := api.server.gitOperations.Get(request.GetOperationId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoGitOperation(value), nil
}

func (api *grpcAPI) CancelGitOperation(_ context.Context, request *dieterv1.GitOperationRef) (*dieterv1.GitOperation, error) {
	if err := api.server.gitOperations.Cancel(request.GetOperationId()); err != nil {
		return nil, grpcFailure(err)
	}
	value, err := api.server.gitOperations.Get(request.GetOperationId())
	if err != nil {
		return nil, grpcFailure(err)
	}
	return protoGitOperation(value), nil
}

func (api *grpcAPI) watchGitOperation(ctx context.Context, request *dieterv1.WatchGitOperationRequest, send func(*dieterv1.GitOperationFrame) error) error {
	id := strings.TrimSpace(request.GetOperationId())
	if id == "" {
		return status.Error(codes.InvalidArgument, "operation_id is required")
	}
	after := request.GetAfterSequence()
	heartbeat := time.Duration(request.GetHeartbeatMs()) * time.Millisecond
	if heartbeat <= 0 {
		heartbeat = 15 * time.Second
	}
	if heartbeat < time.Second {
		heartbeat = time.Second
	}
	if heartbeat > 30*time.Second {
		heartbeat = 30 * time.Second
	}
	first := true
	for {
		operation, err := api.server.gitOperations.Get(id)
		if err != nil {
			return grpcFailure(err)
		}
		logs, err := api.server.gitOperations.Logs(id, after)
		if err != nil {
			return grpcFailure(err)
		}
		if first || len(logs) > 0 || operation.Sequence > after {
			frame := &dieterv1.GitOperationFrame{Operation: protoGitOperation(operation)}
			for _, entry := range logs {
				frame.Logs = append(frame.Logs, &dieterv1.GitOperationLogEntry{
					Sequence: entry.Sequence, CreatedAt: entry.CreatedAt, Message: entry.Message,
				})
				if entry.Sequence > after {
					after = entry.Sequence
				}
			}
			if operation.Sequence > after {
				after = operation.Sequence
			}
			if err := send(frame); err != nil {
				return err
			}
			first = false
		}
		if terminalGitOperation(operation.Status) {
			return nil
		}
		changed := api.server.gitOperations.Changed(id)
		timer := time.NewTimer(heartbeat)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-changed:
			timer.Stop()
		case <-timer.C:
			latest, latestErr := api.server.gitOperations.Get(id)
			if latestErr != nil {
				return grpcFailure(latestErr)
			}
			if err := send(&dieterv1.GitOperationFrame{Operation: protoGitOperation(latest), Heartbeat: true}); err != nil {
				return err
			}
		}
	}
}

func terminalGitOperation(value string) bool {
	switch value {
	case model.GitOperationSucceeded, model.GitOperationFailed, model.GitOperationCanceled, model.GitOperationInterrupted:
		return true
	default:
		return false
	}
}

func (api *grpcAPI) WatchGitOperation(request *dieterv1.WatchGitOperationRequest, stream dieterv1.DieterService_WatchGitOperationServer) error {
	return api.watchGitOperation(stream.Context(), request, stream.Send)
}

func (api *connectAPI) UpdateConversationWorkspace(ctx context.Context, request *connect.Request[dieterv1.UpdateConversationWorkspaceRequest]) (*connect.Response[dieterv1.Card], error) {
	return connectUnary(ctx, request, api.core.UpdateConversationWorkspace)
}

func (api *connectAPI) GetWorkspace(ctx context.Context, request *connect.Request[dieterv1.ConversationRef]) (*connect.Response[dieterv1.Workspace], error) {
	return connectUnary(ctx, request, api.core.GetWorkspace)
}

func (api *connectAPI) ListProjectWorkspaces(ctx context.Context, request *connect.Request[dieterv1.ProjectRef]) (*connect.Response[dieterv1.WorkspacesResponse], error) {
	return connectUnary(ctx, request, api.core.ListProjectWorkspaces)
}

func (api *connectAPI) GetChangeset(ctx context.Context, request *connect.Request[dieterv1.GetChangesetRequest]) (*connect.Response[dieterv1.Changeset], error) {
	return connectUnary(ctx, request, api.core.GetChangeset)
}

func (api *connectAPI) GetFileDiff(ctx context.Context, request *connect.Request[dieterv1.GetDiffRequest]) (*connect.Response[dieterv1.FileDiff], error) {
	return connectUnary(ctx, request, api.core.GetFileDiff)
}

func (api *connectAPI) GetCommitDiff(ctx context.Context, request *connect.Request[dieterv1.GetDiffRequest]) (*connect.Response[dieterv1.FileDiff], error) {
	return connectUnary(ctx, request, api.core.GetCommitDiff)
}

func (api *connectAPI) AddChangeComment(ctx context.Context, request *connect.Request[dieterv1.AddChangeCommentRequest]) (*connect.Response[dieterv1.ChangeComment], error) {
	return connectUnary(ctx, request, api.core.AddChangeComment)
}

func (api *connectAPI) ListChangeComments(ctx context.Context, request *connect.Request[dieterv1.ListChangeCommentsRequest]) (*connect.Response[dieterv1.ChangeCommentsResponse], error) {
	return connectUnary(ctx, request, api.core.ListChangeComments)
}

func (api *connectAPI) GetSCMCapabilities(ctx context.Context, request *connect.Request[dieterv1.ConversationRef]) (*connect.Response[dieterv1.SCMCapabilities], error) {
	return connectUnary(ctx, request, api.core.GetSCMCapabilities)
}

func (api *connectAPI) StartGitOperation(ctx context.Context, request *connect.Request[dieterv1.StartGitOperationRequest]) (*connect.Response[dieterv1.GitOperation], error) {
	return connectUnary(ctx, request, api.core.StartGitOperation)
}

func (api *connectAPI) GetGitOperation(ctx context.Context, request *connect.Request[dieterv1.GitOperationRef]) (*connect.Response[dieterv1.GitOperation], error) {
	return connectUnary(ctx, request, api.core.GetGitOperation)
}

func (api *connectAPI) WatchGitOperation(ctx context.Context, request *connect.Request[dieterv1.WatchGitOperationRequest], stream *connect.ServerStream[dieterv1.GitOperationFrame]) error {
	return connectFailure(api.core.watchGitOperation(ctx, request.Msg, stream.Send))
}

func (api *connectAPI) CancelGitOperation(ctx context.Context, request *connect.Request[dieterv1.GitOperationRef]) (*connect.Response[dieterv1.GitOperation], error) {
	return connectUnary(ctx, request, api.core.CancelGitOperation)
}
