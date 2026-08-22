package server

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"time"

	"connectrpc.com/connect"
	naucliov1 "github.com/dbpprt/nauclio/internal/gen/nauclio/v1"
	"github.com/dbpprt/nauclio/internal/model"
	"github.com/dbpprt/nauclio/internal/terminal"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

const (
	terminalTimeFormat    = time.RFC3339Nano
	terminalHeartbeat     = 15 * time.Second
	terminalFlushInterval = 16 * time.Millisecond
	minimumHeartbeat      = time.Second
	maximumHeartbeat      = 30 * time.Second
)

func (api *grpcAPI) ListTerminals(_ context.Context, request *naucliov1.ListTerminalsRequest) (*naucliov1.TerminalsResponse, error) {
	projectID := strings.TrimSpace(request.GetProjectId())
	if projectID != "" {
		if _, err := api.server.store.ResolveProject(projectID); err != nil {
			return nil, grpcFailure(err)
		}
	}
	result := &naucliov1.TerminalsResponse{}
	for _, value := range api.server.terminals.List(projectID) {
		result.Terminals = append(result.Terminals, protoTerminal(value))
	}
	return result, nil
}

func (api *grpcAPI) CreateTerminal(_ context.Context, request *naucliov1.CreateTerminalRequest) (*naucliov1.Terminal, error) {
	project, err := api.server.store.ResolveProject(strings.TrimSpace(request.GetProjectId()))
	if err != nil {
		return nil, grpcFailure(err)
	}
	workingDirectory, err := terminalWorkingDirectory(project, request.GetWorkingDirectory())
	if err != nil {
		return nil, grpcFailure(err)
	}
	value, err := api.server.terminals.Create(terminal.CreateInput{
		ProjectID: project.ID, Name: request.GetName(), Shell: request.GetShell(),
		WorkingDirectory: workingDirectory, Columns: int(request.GetColumns()), Rows: int(request.GetRows()),
	})
	if err != nil {
		return nil, terminalFailure(err)
	}
	return protoTerminal(value), nil
}

func (api *grpcAPI) WatchTerminal(request *naucliov1.WatchTerminalRequest, stream naucliov1.NauclioService_WatchTerminalServer) error {
	return api.watchTerminal(stream.Context(), request, stream.Send)
}

func (api *grpcAPI) watchTerminal(ctx context.Context, request *naucliov1.WatchTerminalRequest, send func(*naucliov1.TerminalFrame) error) error {
	id := strings.TrimSpace(request.GetTerminalId())
	if id == "" {
		return status.Error(codes.InvalidArgument, "terminal_id is required")
	}
	after := request.GetAfterSequence()
	heartbeat := time.Duration(request.GetHeartbeatMs()) * time.Millisecond
	if heartbeat <= 0 {
		heartbeat = terminalHeartbeat
	}
	if heartbeat < minimumHeartbeat {
		heartbeat = minimumHeartbeat
	}
	if heartbeat > maximumHeartbeat {
		heartbeat = maximumHeartbeat
	}
	for {
		frames, changed, err := api.server.terminals.Frames(id, after)
		if err != nil {
			return terminalFailure(err)
		}
		for _, frame := range frames {
			if err := send(protoTerminalFrame(frame)); err != nil {
				return err
			}
			if frame.Sequence > after {
				after = frame.Sequence
			}
		}
		timer := time.NewTimer(heartbeat)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-changed:
			timer.Stop()
			flush := time.NewTimer(terminalFlushInterval)
			select {
			case <-ctx.Done():
				flush.Stop()
				return ctx.Err()
			case <-flush.C:
			}
			continue
		case <-timer.C:
			value, err := api.server.terminals.Get(id)
			if err != nil {
				return terminalFailure(err)
			}
			if err := send(&naucliov1.TerminalFrame{Terminal: protoTerminal(value), Sequence: value.Sequence, Heartbeat: true}); err != nil {
				return err
			}
		}
	}
}

func (api *grpcAPI) WriteTerminal(_ context.Context, request *naucliov1.TerminalInputRequest) (*naucliov1.Terminal, error) {
	value, err := api.server.terminals.Write(request.GetTerminalId(), request.GetData())
	if err != nil {
		return nil, terminalFailure(err)
	}
	return protoTerminal(value), nil
}

func (api *grpcAPI) ResizeTerminal(_ context.Context, request *naucliov1.ResizeTerminalRequest) (*naucliov1.Terminal, error) {
	value, err := api.server.terminals.Resize(request.GetTerminalId(), int(request.GetColumns()), int(request.GetRows()))
	if err != nil {
		return nil, terminalFailure(err)
	}
	return protoTerminal(value), nil
}

func (api *grpcAPI) RenameTerminal(_ context.Context, request *naucliov1.RenameTerminalRequest) (*naucliov1.Terminal, error) {
	value, err := api.server.terminals.Rename(request.GetTerminalId(), request.GetName())
	if err != nil {
		return nil, terminalFailure(err)
	}
	return protoTerminal(value), nil
}

func (api *grpcAPI) CloseTerminal(_ context.Context, request *naucliov1.TerminalRef) (*emptypb.Empty, error) {
	if err := api.server.terminals.Close(request.GetTerminalId()); err != nil {
		return nil, terminalFailure(err)
	}
	return &emptypb.Empty{}, nil
}

func (api *connectAPI) ListTerminals(ctx context.Context, request *connect.Request[naucliov1.ListTerminalsRequest]) (*connect.Response[naucliov1.TerminalsResponse], error) {
	return connectUnary(ctx, request, api.core.ListTerminals)
}

func (api *connectAPI) CreateTerminal(ctx context.Context, request *connect.Request[naucliov1.CreateTerminalRequest]) (*connect.Response[naucliov1.Terminal], error) {
	return connectUnary(ctx, request, api.core.CreateTerminal)
}

func (api *connectAPI) WatchTerminal(ctx context.Context, request *connect.Request[naucliov1.WatchTerminalRequest], stream *connect.ServerStream[naucliov1.TerminalFrame]) error {
	return connectFailure(api.core.watchTerminal(ctx, request.Msg, stream.Send))
}

func (api *connectAPI) WriteTerminal(ctx context.Context, request *connect.Request[naucliov1.TerminalInputRequest]) (*connect.Response[naucliov1.Terminal], error) {
	return connectUnary(ctx, request, api.core.WriteTerminal)
}

func (api *connectAPI) ResizeTerminal(ctx context.Context, request *connect.Request[naucliov1.ResizeTerminalRequest]) (*connect.Response[naucliov1.Terminal], error) {
	return connectUnary(ctx, request, api.core.ResizeTerminal)
}

func (api *connectAPI) RenameTerminal(ctx context.Context, request *connect.Request[naucliov1.RenameTerminalRequest]) (*connect.Response[naucliov1.Terminal], error) {
	return connectUnary(ctx, request, api.core.RenameTerminal)
}

func (api *connectAPI) CloseTerminal(ctx context.Context, request *connect.Request[naucliov1.TerminalRef]) (*connect.Response[emptypb.Empty], error) {
	return connectUnary(ctx, request, api.core.CloseTerminal)
}

func protoTerminal(value terminal.Session) *naucliov1.Terminal {
	result := &naucliov1.Terminal{
		Id: value.ID, ProjectId: value.ProjectID, Name: value.Name, Shell: value.Shell,
		WorkingDirectory: value.WorkingDirectory, Status: value.Status, Pid: value.PID,
		Columns: int32(value.Columns), Rows: int32(value.Rows), Sequence: value.Sequence,
		CreatedAt: value.CreatedAt.Format(terminalTimeFormat), UpdatedAt: value.UpdatedAt.Format(terminalTimeFormat),
	}
	if value.ExitCode != nil {
		exitCode := int32(*value.ExitCode)
		result.ExitCode = &exitCode
	}
	return result
}

func protoTerminalFrame(value terminal.Frame) *naucliov1.TerminalFrame {
	return &naucliov1.TerminalFrame{
		Terminal: protoTerminal(value.Session), Sequence: value.Sequence,
		Data: append([]byte(nil), value.Data...), ScreenReset: value.Reset, Heartbeat: value.Heartbeat,
	}
}

func terminalWorkingDirectory(project model.Project, requested string) (string, error) {
	root, err := filepath.EvalSymlinks(project.Path)
	if err != nil {
		return "", err
	}
	target := strings.TrimSpace(requested)
	if target == "" {
		target = root
	} else if !filepath.IsAbs(target) {
		target = filepath.Join(root, target)
	}
	target, err = filepath.EvalSymlinks(filepath.Clean(target))
	if err != nil {
		return "", err
	}
	relative, err := filepath.Rel(root, target)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", errors.New("terminal working directory must stay inside the registered project")
	}
	info, err := os.Stat(target)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", errors.New("terminal working directory is not a directory")
	}
	return target, nil
}

func terminalFailure(err error) error {
	switch {
	case errors.Is(err, terminal.ErrNotFound):
		return status.Error(codes.NotFound, err.Error())
	case errors.Is(err, terminal.ErrNotRunning):
		return status.Error(codes.FailedPrecondition, err.Error())
	case errors.Is(err, terminal.ErrLimitReached):
		return status.Error(codes.ResourceExhausted, err.Error())
	case errors.Is(err, terminal.ErrUnsupported):
		return status.Error(codes.Unimplemented, err.Error())
	default:
		return grpcFailure(err)
	}
}
