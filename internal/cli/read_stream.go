package cli

import (
	"context"
	"errors"
	"io"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

const readRecoveryHelp = "\nRead subscriptions renew credentials and resume from their last delivered checkpoint\nafter transient failures (up to five retries between frames). Revocation stops\nrecovery. Mutations, process starts, and stdin writes are never replayed.\n"

// Only these read subscriptions may be replayed. In particular StartExecution,
// StartRemoteDesktop and every unary mutation use the original connection.
type readResumingConn struct{ grpc.ClientConnInterface }

func (c readResumingConn) NewStream(ctx context.Context, desc *grpc.StreamDesc, method string, opts ...grpc.CallOption) (grpc.ClientStream, error) {
	switch method {
	case dieterv1.DieterService_WatchKV_FullMethodName, dieterv1.DieterService_WatchState_FullMethodName,
		dieterv1.DieterService_WatchSync_FullMethodName,
		dieterv1.DieterService_WatchConversation_FullMethodName,
		dieterv1.DieterService_WatchTerminal_FullMethodName,
		dieterv1.DieterService_WatchExecution_FullMethodName,
		dieterv1.DieterService_WatchGitOperation_FullMethodName:
		return &resumingReadStream{ctx: ctx, open: func(ctx context.Context) (grpc.ClientStream, error) {
			return c.ClientConnInterface.NewStream(ctx, desc, method, opts...)
		}}, nil
	default:
		return c.ClientConnInterface.NewStream(ctx, desc, method, opts...)
	}
}

type resumingReadStream struct {
	ctx     context.Context
	open    func(context.Context) (grpc.ClientStream, error)
	stream  grpc.ClientStream
	cancel  context.CancelFunc
	request proto.Message
	closed  bool
}

func (s *resumingReadStream) Context() context.Context { return s.ctx }
func (s *resumingReadStream) Trailer() metadata.MD {
	if s.stream == nil {
		return nil
	}
	return s.stream.Trailer()
}
func (s *resumingReadStream) Header() (metadata.MD, error) {
	if err := s.connect(); err != nil {
		return nil, err
	}
	return s.stream.Header()
}
func (s *resumingReadStream) SendMsg(value any) error {
	message, ok := value.(proto.Message)
	if !ok || s.request != nil || s.closed {
		return status.Error(codes.Internal, "read subscription requires one protobuf request")
	}
	s.request = proto.Clone(message)
	return nil
}
func (s *resumingReadStream) CloseSend() error { s.closed = true; return nil }

func (s *resumingReadStream) connect() error {
	if s.stream != nil {
		return nil
	}
	if s.request == nil || !s.closed {
		return status.Error(codes.Internal, "read subscription request is incomplete")
	}
	ctx, cancel := context.WithCancel(s.ctx)
	s.cancel = cancel
	stream, err := s.open(ctx)
	if err != nil {
		cancel()
		return err
	}
	s.stream = stream
	if err = stream.SendMsg(s.request); err != nil && !errors.Is(err, io.EOF) {
		return err
	}
	// SendMsg can return EOF before the server's status is available. RecvMsg
	// must read that status so revoked credentials never turn into a clean EOF.
	return stream.CloseSend()
}

func (s *resumingReadStream) RecvMsg(value any) error {
	for failures := 0; ; failures++ {
		err := s.connect()
		if err == nil {
			err = s.stream.RecvMsg(value)
		}
		if err == nil {
			s.checkpoint(value)
			return nil
		}
		if s.cancel != nil {
			s.cancel()
		}
		if s.ctx.Err() != nil {
			return status.FromContextError(s.ctx.Err()).Err()
		}
		if failures >= 5 || !retryReadStream(err) {
			return err
		}
		s.stream = nil
		timer := time.NewTimer(min(100*time.Millisecond<<failures, 2*time.Second))
		select {
		case <-s.ctx.Done():
			timer.Stop()
			return status.FromContextError(s.ctx.Err()).Err()
		case <-timer.C:
		}
	}
}

func retryReadStream(err error) bool {
	switch status.Code(err) {
	case codes.Unavailable, codes.DeadlineExceeded, codes.Canceled:
		return true
	default:
		return false
	}
}

func (s *resumingReadStream) checkpoint(value any) {
	switch request := s.request.(type) {
	case *dieterv1.KVWatchRequest:
		frame := value.(*dieterv1.KVFrame)
		if frame.GetCursor() != nil {
			request.After = proto.Clone(frame.GetCursor()).(*dieterv1.KVCursor)
			request.Account = frame.GetAccount()
		}
	case *dieterv1.WatchConversationRequest:
		update := value.(*dieterv1.ConversationUpdate)
		request.AfterSeq = update.GetLastSeq()
		if update.GetSnapshot() != nil {
			request.AfterSeq = update.GetSnapshot().GetConversation().GetLastSeq()
		}
	case *dieterv1.WatchTerminalRequest:
		frame := value.(*dieterv1.TerminalFrame)
		if !frame.GetHeartbeat() {
			request.AfterSequence = frame.GetSequence()
		}
	case *dieterv1.WatchExecutionRequest:
		frame := value.(*dieterv1.ExecutionEvent)
		if !frame.GetHeartbeat() {
			request.AfterSequence = frame.GetSequence()
		}
	case *dieterv1.WatchGitOperationRequest:
		for _, log := range value.(*dieterv1.GitOperationFrame).GetLogs() {
			request.AfterSequence = max(request.AfterSequence, log.GetSequence())
		}
	case *dieterv1.SyncRequest:
		frame := value.(*dieterv1.SyncFrame)
		if !frame.GetHeartbeat() && !frame.GetTransportOnly() && !frame.GetProjectionPending() && frame.GetCursor() != nil {
			request.After = proto.Clone(frame.GetCursor()).(*dieterv1.SyncCursor)
		}
	}
}
