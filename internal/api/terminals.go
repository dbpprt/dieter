package api

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/host/terminal"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"google.golang.org/protobuf/types/known/emptypb"
)

func (api *terminalsAPI) ListTerminals(ctx context.Context, request *dieterv1.ListTerminalsRequest) (*dieterv1.TerminalsResponse, error) {
	ctx = kanban.WithCheckout(ctx, request.GetCheckoutId())
	projectID := strings.TrimSpace(request.GetProjectId())
	cardID := strings.TrimSpace(request.GetCardId())
	if projectID != "" || cardID != "" {
		project, err := api.server.scopedProject(ctx, projectID, cardID)
		if err != nil {
			return nil, err
		}
		projectID = project.ID
	}
	result := &dieterv1.TerminalsResponse{}
	for _, value := range api.server.terminals.ListScoped(projectID, cardID) {
		result.Terminals = append(result.Terminals, protoTerminal(value))
	}
	return result, nil
}

func (api *terminalsAPI) CreateTerminal(ctx context.Context, request *dieterv1.CreateTerminalRequest) (*dieterv1.Terminal, error) {
	ctx = kanban.WithCheckout(ctx, request.GetCheckoutId())
	projectID, cardID := strings.TrimSpace(request.GetProjectId()), strings.TrimSpace(request.GetCardId())
	workingDirectory := ""
	if request.GetMachineHome() {
		if projectID != "" || cardID != "" {
			return nil, fault.New(fault.Invalid, "machine_home cannot be combined with project_id or card_id")
		}
		var err error
		workingDirectory, err = terminalMachineWorkingDirectory(request.GetWorkingDirectory())
		if err != nil {
			return nil, fault.New(fault.Invalid, err.Error())
		}
	} else {
		project, err := api.server.scopedProject(ctx, projectID, cardID)
		if err != nil {
			return nil, err
		}
		projectID = project.ID
		workingDirectory, err = terminalWorkingDirectory(project, request.GetWorkingDirectory())
		if err != nil {
			return nil, err
		}
	}
	value, err := api.server.terminals.Create(terminal.CreateInput{
		ProjectID: projectID, CardID: cardID, Name: request.GetName(), Shell: request.GetShell(),
		WorkingDirectory: workingDirectory, Columns: int(request.GetColumns()), Rows: int(request.GetRows()),
	})
	if err != nil {
		return nil, err
	}
	return protoTerminal(value), nil
}

func (api *terminalsAPI) WatchTerminal(ctx context.Context, request *dieterv1.WatchTerminalRequest, stream *connect.ServerStream[dieterv1.TerminalFrame]) error {
	return api.server.watchTerminal(ctx, request, stream.Send)
}

func (api *terminalsAPI) WriteTerminal(_ context.Context, request *dieterv1.TerminalInputRequest) (*dieterv1.Terminal, error) {
	value, err := api.server.terminals.Write(request.GetTerminalId(), request.GetData())
	if err != nil {
		return nil, err
	}
	return protoTerminal(value), nil
}

func (api *terminalsAPI) ResizeTerminal(_ context.Context, request *dieterv1.ResizeTerminalRequest) (*dieterv1.Terminal, error) {
	value, err := api.server.terminals.Resize(request.GetTerminalId(), int(request.GetColumns()), int(request.GetRows()))
	if err != nil {
		return nil, err
	}
	return protoTerminal(value), nil
}

func (api *terminalsAPI) RenameTerminal(_ context.Context, request *dieterv1.RenameTerminalRequest) (*dieterv1.Terminal, error) {
	value, err := api.server.terminals.Rename(request.GetTerminalId(), request.GetName())
	if err != nil {
		return nil, err
	}
	return protoTerminal(value), nil
}

func (api *terminalsAPI) CloseTerminal(_ context.Context, request *dieterv1.TerminalRef) (*emptypb.Empty, error) {
	if err := api.server.terminals.Close(request.GetTerminalId()); err != nil {
		return nil, err
	}
	return &emptypb.Empty{}, nil
}

const (
	terminalTimeFormat    = time.RFC3339Nano
	terminalHeartbeat     = 15 * time.Second
	terminalFlushInterval = 16 * time.Millisecond
	minimumHeartbeat      = time.Second
	maximumHeartbeat      = 30 * time.Second
)

func terminalMachineWorkingDirectory(requested string) (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	root, err := filepath.EvalSymlinks(home)
	if err != nil {
		return "", err
	}
	target := strings.TrimSpace(requested)
	if target == "" || target == "~" {
		target = root
	} else if strings.HasPrefix(target, "~"+string(filepath.Separator)) {
		target = filepath.Join(root, strings.TrimPrefix(target, "~"+string(filepath.Separator)))
	} else if !filepath.IsAbs(target) {
		target = filepath.Join(root, target)
	}
	target, err = filepath.EvalSymlinks(filepath.Clean(target))
	if err != nil {
		return "", err
	}
	relative, err := filepath.Rel(root, target)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", fault.New(fault.Invalid, "machine terminal working directory must stay inside the daemon user's home")
	}
	info, err := os.Stat(target)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", fault.New(fault.Invalid, "terminal working directory is not a directory")
	}
	return target, nil
}

func protoTerminal(value terminal.Session) *dieterv1.Terminal {
	result := &dieterv1.Terminal{
		Id: value.ID, ProjectId: value.ProjectID, CardId: value.CardID, Name: value.Name, Shell: value.Shell,
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

func protoTerminalFrame(value terminal.Frame) *dieterv1.TerminalFrame {
	return &dieterv1.TerminalFrame{
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
		return "", fault.New(fault.Invalid, "terminal working directory must stay inside the registered project")
	}
	info, err := os.Stat(target)
	if err != nil {
		return "", err
	}
	if !info.IsDir() {
		return "", fault.New(fault.Invalid, "terminal working directory is not a directory")
	}
	return target, nil
}

func (s *Server) watchTerminal(ctx context.Context, request *dieterv1.WatchTerminalRequest, send func(*dieterv1.TerminalFrame) error) error {
	id := strings.TrimSpace(request.GetTerminalId())
	if id == "" {
		return fault.New(fault.Invalid, "terminal_id is required")
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
		frames, changed, err := s.terminals.Frames(id, after)
		if err != nil {
			return err
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
			value, err := s.terminals.Get(id)
			if err != nil {
				return err
			}
			if err := send(&dieterv1.TerminalFrame{Terminal: protoTerminal(value), Sequence: value.Sequence, Heartbeat: true}); err != nil {
				return err
			}
		}
	}
}
