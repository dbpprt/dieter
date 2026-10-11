package api

import (
	"context"
	"strings"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/git/operations"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store"
)

func (api *gitAPI) GetWorkspace(ctx context.Context, request *dieterv1.ConversationRef) (*dieterv1.Workspace, error) {
	value, err := api.server.workspaces.Ensure(ctx, request.GetCardId())
	if err != nil {
		return nil, err
	}
	return protoWorkspace(value), nil
}

func (api *gitAPI) ListProjectWorkspaces(_ context.Context, request *dieterv1.ProjectRef) (*dieterv1.WorkspacesResponse, error) {
	values, err := api.server.store.ListWorkspaces(request.GetProjectId())
	if err != nil {
		return nil, err
	}
	result := &dieterv1.WorkspacesResponse{}
	for _, value := range values {
		if request.GetCheckoutId() != "" && value.CheckoutID != request.GetCheckoutId() {
			continue
		}
		result.Workspaces = append(result.Workspaces, protoWorkspace(value))
	}
	return result, nil
}

func (api *gitAPI) GetChangeset(ctx context.Context, request *dieterv1.GetChangesetRequest) (*dieterv1.Changeset, error) {
	ctx = store.WithCheckout(ctx, request.GetCheckoutId())
	value, err := api.server.changesets.GetTarget(ctx, request.GetCardId(), request.GetProjectId())
	if err != nil {
		return nil, err
	}
	if request.GetProjectId() != "" {
		if active, leaseErr := api.server.store.ProjectCheckoutHasRuntimeLease(value.ProjectID, ""); leaseErr == nil {
			value.Volatile = active
		}
		if operation, operationErr := api.server.store.ActiveProjectGitOperation(value.ProjectID); operationErr == nil {
			value.CurrentOperationID = operation.ID
		}
	} else if active, leaseErr := api.server.store.CardHasRuntimeLease(request.GetCardId()); leaseErr == nil {
		value.Volatile = active
	}
	return protoChangeset(value), nil
}

func (api *gitAPI) GetFileDiff(ctx context.Context, request *dieterv1.GetDiffRequest) (*dieterv1.FileDiff, error) {
	ctx = store.WithCheckout(ctx, request.GetCheckoutId())
	value, err := api.server.changesets.FileDiffTarget(
		ctx, request.GetCardId(), request.GetProjectId(), request.GetExpectedRevision(), request.GetPath(), "", request.GetSection(), int(request.GetOffset()), int(request.GetLimit()),
	)
	if err != nil {
		return nil, err
	}
	return protoFileDiff(value), nil
}

func (api *gitAPI) GetCommitDiff(ctx context.Context, request *dieterv1.GetDiffRequest) (*dieterv1.FileDiff, error) {
	ctx = store.WithCheckout(ctx, request.GetCheckoutId())
	if strings.TrimSpace(request.GetCommitSha()) == "" {
		return nil, fault.New(fault.Invalid, "commit SHA is required")
	}
	value, err := api.server.changesets.FileDiffTarget(
		ctx, request.GetCardId(), request.GetProjectId(), request.GetExpectedRevision(), request.GetPath(), request.GetCommitSha(), "combined", int(request.GetOffset()), int(request.GetLimit()),
	)
	if err != nil {
		return nil, err
	}
	result := protoFileDiff(value)
	result.CommitSha = request.GetCommitSha()
	return result, nil
}

func (api *gitAPI) AddChangeComment(_ context.Context, request *dieterv1.AddChangeCommentRequest) (*dieterv1.ChangeComment, error) {
	if request.GetRevision() == "" {
		return nil, fault.New(fault.Invalid, "revision is required")
	}
	value, err := api.server.store.AddChangeComment(model.ChangeComment{
		CardID: request.GetCardId(), ChangesetRevision: request.GetRevision(), Path: request.GetPath(),
		Side: request.GetSide(), Line: int(request.GetLine()), Body: request.GetBody(),
		Author: model.Author{Kind: "human", Name: request.GetAuthor()},
	})
	if err != nil {
		return nil, err
	}
	return protoChangeComment(value), nil
}

func (api *gitAPI) ListChangeComments(_ context.Context, request *dieterv1.ListChangeCommentsRequest) (*dieterv1.ChangeCommentsResponse, error) {
	values, err := api.server.store.ListChangeComments(request.GetCardId())
	if err != nil {
		return nil, err
	}
	result := &dieterv1.ChangeCommentsResponse{}
	for _, value := range values {
		if request.GetRevision() == "" || request.GetRevision() == value.ChangesetRevision {
			result.Comments = append(result.Comments, protoChangeComment(value))
		}
	}
	return result, nil
}

func (api *gitAPI) GetSCMCapabilities(ctx context.Context, request *dieterv1.ConversationRef) (*dieterv1.SCMCapabilities, error) {
	value, err := api.server.workspaces.Ensure(ctx, request.GetCardId())
	if err != nil {
		return nil, err
	}
	capabilities := api.server.gitOperations.SCM.Capabilities(ctx, value.Path, value.BaseRemote)
	return protoSCMCapabilities(capabilities), nil
}

func (api *gitAPI) StartGitOperation(ctx context.Context, request *dieterv1.StartGitOperationRequest) (*dieterv1.GitOperation, error) {
	ctx = store.WithCheckout(ctx, request.GetCheckoutId())
	value, err := api.server.gitOperations.Start(ctx, operations.Request{
		CardID: request.GetCardId(), ProjectID: request.GetProjectId(), Kind: request.GetKind(), ExpectedRevision: request.GetExpectedRevision(),
		Parameters: cloneProtoStringMap(request.GetParameters()),
	})
	if err != nil {
		return nil, err
	}
	return protoGitOperation(value), nil
}

func (api *gitAPI) GetGitOperation(_ context.Context, request *dieterv1.GitOperationRef) (*dieterv1.GitOperation, error) {
	value, err := api.server.gitOperations.Get(request.GetOperationId())
	if err != nil {
		return nil, err
	}
	return protoGitOperation(value), nil
}

func (api *gitAPI) CancelGitOperation(_ context.Context, request *dieterv1.GitOperationRef) (*dieterv1.GitOperation, error) {
	if err := api.server.gitOperations.Cancel(request.GetOperationId()); err != nil {
		return nil, err
	}
	value, err := api.server.gitOperations.Get(request.GetOperationId())
	if err != nil {
		return nil, err
	}
	return protoGitOperation(value), nil
}

func (api *gitAPI) WatchGitOperation(ctx context.Context, request *dieterv1.WatchGitOperationRequest, stream *connect.ServerStream[dieterv1.GitOperationFrame]) error {
	return api.server.watchGitOperation(ctx, request, stream.Send)
}

func terminalGitOperation(value string) bool {
	switch value {
	case model.GitOperationSucceeded, model.GitOperationFailed, model.GitOperationCanceled, model.GitOperationInterrupted:
		return true
	default:
		return false
	}
}

func (s *Server) watchGitOperation(ctx context.Context, request *dieterv1.WatchGitOperationRequest, send func(*dieterv1.GitOperationFrame) error) error {
	id := strings.TrimSpace(request.GetOperationId())
	if id == "" {
		return fault.New(fault.Invalid, "operation_id is required")
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
		operation, err := s.gitOperations.Get(id)
		if err != nil {
			return err
		}
		logs, err := s.gitOperations.Logs(id, after)
		if err != nil {
			return err
		}
		// Logs and status are read separately. A newer log may advance after
		// before its terminal status is observed; EOF must still carry that status.
		if first || len(logs) > 0 || operation.Sequence > after || terminalGitOperation(operation.Status) {
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
		changed := s.gitOperations.Changed(id)
		timer := time.NewTimer(heartbeat)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-changed:
			timer.Stop()
		case <-timer.C:
			latest, latestErr := s.gitOperations.Get(id)
			if latestErr != nil {
				return latestErr
			}
			if err := send(&dieterv1.GitOperationFrame{Operation: protoGitOperation(latest), Heartbeat: true}); err != nil {
				return err
			}
		}
	}
}
