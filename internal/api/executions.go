package api

import (
	"context"
	"strings"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/host/remoteexec"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/types/known/emptypb"
)

func (api *executionsAPI) ListExecutions(ctx context.Context, request *dieterv1.ListExecutionsRequest) (*dieterv1.ExecutionsResponse, error) {
	ctx = store.WithCheckout(ctx, request.GetCheckoutId())
	projectID := strings.TrimSpace(request.GetProjectId())
	cardID := strings.TrimSpace(request.GetCardId())
	if projectID != "" || cardID != "" {
		project, err := api.server.scopedProject(ctx, projectID, cardID)
		if err != nil {
			return nil, err
		}
		projectID = project.ID
	}
	result := &dieterv1.ExecutionsResponse{}
	for _, value := range api.server.executions.List(projectID, cardID, strings.TrimSpace(request.GetStatus())) {
		result.Executions = append(result.Executions, protoExecution(value))
	}
	return result, nil
}

func (api *executionsAPI) StartExecution(ctx context.Context, request *dieterv1.StartExecutionRequest) (*dieterv1.Execution, error) {
	ctx = store.WithCheckout(ctx, request.GetCheckoutId())
	timeoutMilliseconds := request.GetTimeoutMs()
	if timeoutMilliseconds < 0 || timeoutMilliseconds > (7*24*time.Hour).Milliseconds() {
		return nil, fault.New(fault.Invalid, "execution timeout must be between zero and seven days")
	}
	project, err := api.server.scopedProject(ctx, request.GetProjectId(), request.GetCardId())
	if err != nil {
		return nil, err
	}
	workingDirectory, err := terminalWorkingDirectory(project, request.GetWorkingDirectory())
	if err != nil {
		return nil, err
	}
	value, err := api.server.executions.Start(remoteexec.StartInput{
		ProjectID: project.ID, CardID: strings.TrimSpace(request.GetCardId()), Name: request.GetName(),
		Argv: append([]string(nil), request.GetArgv()...), WorkingDirectory: workingDirectory,
		Environment: cloneStringMap(request.GetEnvironment()), Stdin: append([]byte(nil), request.GetStdin()...),
		StdinEOF: request.GetStdinEof(), Timeout: time.Duration(timeoutMilliseconds) * time.Millisecond,
		IdempotencyKey: strings.TrimSpace(request.GetIdempotencyKey()), PTY: request.GetPty(),
		Columns: int(request.GetColumns()), Rows: int(request.GetRows()), MaxOutputBytes: request.GetMaxOutputBytes(),
	})
	if err != nil {
		return nil, err
	}
	return protoExecution(value), nil
}

func (api *executionsAPI) GetExecution(_ context.Context, request *dieterv1.ExecutionRef) (*dieterv1.Execution, error) {
	value, err := api.server.executions.Get(request.GetExecutionId())
	if err != nil {
		return nil, err
	}
	return protoExecution(value), nil
}

func (api *executionsAPI) WatchExecution(ctx context.Context, request *dieterv1.WatchExecutionRequest, stream *connect.ServerStream[dieterv1.ExecutionEvent]) error {
	return api.server.watchExecution(ctx, request, stream.Send)
}

func (api *executionsAPI) WriteExecutionInput(_ context.Context, request *dieterv1.ExecutionInputRequest) (*dieterv1.Execution, error) {
	value, err := api.server.executions.Write(request.GetExecutionId(), request.GetData(), request.GetEof())
	if err != nil {
		return nil, err
	}
	return protoExecution(value), nil
}

func (api *executionsAPI) SignalExecution(_ context.Context, request *dieterv1.SignalExecutionRequest) (*dieterv1.Execution, error) {
	signal, err := executionSignal(request.GetSignal())
	if err != nil {
		return nil, err
	}
	value, err := api.server.executions.Signal(request.GetExecutionId(), signal)
	if err != nil {
		return nil, err
	}
	return protoExecution(value), nil
}

func (api *executionsAPI) ResizeExecution(_ context.Context, request *dieterv1.ResizeExecutionRequest) (*dieterv1.Execution, error) {
	value, err := api.server.executions.Resize(request.GetExecutionId(), int(request.GetColumns()), int(request.GetRows()))
	if err != nil {
		return nil, err
	}
	return protoExecution(value), nil
}

func (api *executionsAPI) CancelExecution(_ context.Context, request *dieterv1.ExecutionRef) (*dieterv1.Execution, error) {
	value, err := api.server.executions.Cancel(request.GetExecutionId())
	if err != nil {
		return nil, err
	}
	return protoExecution(value), nil
}

func (api *executionsAPI) CloseExecution(_ context.Context, request *dieterv1.ExecutionRef) (*emptypb.Empty, error) {
	if err := api.server.executions.Close(request.GetExecutionId()); err != nil {
		return nil, err
	}
	return &emptypb.Empty{}, nil
}

const (
	executionHeartbeat     = 15 * time.Second
	executionFlushInterval = 8 * time.Millisecond
)

func protoExecution(value remoteexec.Execution) *dieterv1.Execution {
	result := &dieterv1.Execution{
		Id: value.ID, ProjectId: value.ProjectID, CardId: value.CardID, Name: value.Name,
		Argv: append([]string(nil), value.Argv...), WorkingDirectory: value.WorkingDirectory,
		Status: value.Status, Pid: value.PID, Pty: value.PTY, Columns: int32(value.Columns), Rows: int32(value.Rows),
		Sequence: value.Sequence, CreatedAt: formatExecutionTime(value.CreatedAt), StartedAt: formatExecutionTime(value.StartedAt),
		UpdatedAt: formatExecutionTime(value.UpdatedAt), CompletedAt: formatExecutionTime(value.CompletedAt),
		ExitSignal: value.ExitSignal, Error: value.Error, IdempotencyKey: value.IdempotencyKey,
		StdoutBytes: value.StdoutBytes, StderrBytes: value.StderrBytes, OutputTruncated: value.OutputTruncated,
		TruncatedBeforeSequence: value.TruncatedBeforeSequence, TimeoutMs: value.Timeout.Milliseconds(),
	}
	if value.ExitCode != nil {
		exitCode := int32(*value.ExitCode)
		result.ExitCode = &exitCode
	}
	return result
}

func protoExecutionEvent(value remoteexec.Event) *dieterv1.ExecutionEvent {
	return &dieterv1.ExecutionEvent{
		Execution: protoExecution(value.Execution), Sequence: value.Sequence, Stream: protoExecutionStream(value.Stream),
		Data: append([]byte(nil), value.Data...), Reset_: value.Reset, Heartbeat: value.Heartbeat, Eof: value.EOF,
	}
}

func protoExecutionStream(value remoteexec.Stream) dieterv1.ExecutionStream {
	switch value {
	case remoteexec.StreamStdout:
		return dieterv1.ExecutionStream_EXECUTION_STREAM_STDOUT
	case remoteexec.StreamStderr:
		return dieterv1.ExecutionStream_EXECUTION_STREAM_STDERR
	case remoteexec.StreamPTY:
		return dieterv1.ExecutionStream_EXECUTION_STREAM_PTY
	default:
		return dieterv1.ExecutionStream_EXECUTION_STREAM_STATE
	}
}

func executionSignal(value dieterv1.ExecutionSignal) (remoteexec.Signal, error) {
	switch value {
	case dieterv1.ExecutionSignal_EXECUTION_SIGNAL_INTERRUPT:
		return remoteexec.SignalInterrupt, nil
	case dieterv1.ExecutionSignal_EXECUTION_SIGNAL_TERMINATE:
		return remoteexec.SignalTerminate, nil
	case dieterv1.ExecutionSignal_EXECUTION_SIGNAL_KILL:
		return remoteexec.SignalKill, nil
	case dieterv1.ExecutionSignal_EXECUTION_SIGNAL_HANGUP:
		return remoteexec.SignalHangup, nil
	default:
		return 0, fault.New(fault.Invalid, "signal is required")
	}
}

func formatExecutionTime(value time.Time) string {
	if value.IsZero() {
		return ""
	}
	return value.Format(time.RFC3339Nano)
}

func cloneStringMap(value map[string]string) map[string]string {
	result := make(map[string]string, len(value))
	for key, item := range value {
		result[key] = item
	}
	return result
}

func (s *Server) watchExecution(ctx context.Context, request *dieterv1.WatchExecutionRequest, send func(*dieterv1.ExecutionEvent) error) error {
	id := strings.TrimSpace(request.GetExecutionId())
	if id == "" {
		return fault.New(fault.Invalid, "execution_id is required")
	}
	after := request.GetAfterSequence()
	heartbeat := time.Duration(request.GetHeartbeatMs()) * time.Millisecond
	if heartbeat <= 0 {
		heartbeat = executionHeartbeat
	}
	if heartbeat < minimumHeartbeat {
		heartbeat = minimumHeartbeat
	}
	if heartbeat > maximumHeartbeat {
		heartbeat = maximumHeartbeat
	}
	for {
		events, changed, err := s.executions.Events(id, after)
		if err != nil {
			return err
		}
		complete := false
		for _, event := range events {
			if err := send(protoExecutionEvent(event)); err != nil {
				return err
			}
			if event.Sequence > after {
				after = event.Sequence
			}
			complete = complete || event.EOF
		}
		if complete {
			return nil
		}
		timer := time.NewTimer(heartbeat)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-changed:
			timer.Stop()
			flush := time.NewTimer(executionFlushInterval)
			select {
			case <-ctx.Done():
				flush.Stop()
				return ctx.Err()
			case <-flush.C:
			}
		case <-timer.C:
			value, err := s.executions.Get(id)
			if err != nil {
				return err
			}
			if err := send(&dieterv1.ExecutionEvent{Execution: protoExecution(value), Sequence: value.Sequence, Heartbeat: true}); err != nil {
				return err
			}
		}
	}
}
