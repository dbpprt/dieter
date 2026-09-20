package cli

import (
	"context"
	"errors"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func readStreamTestConnection(t *testing.T, handler grpc.StreamHandler) *grpc.ClientConn {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer(grpc.UnknownServiceHandler(handler))
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(server.Stop)
	connection, err := grpc.NewClient(listener.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	return connection
}

func TestReadStreamsResumeOnlyDeliveredCheckpoints(t *testing.T) {
	for _, test := range []struct {
		method           string
		request, resumed proto.Message
		responses        []proto.Message
	}{
		{"WatchConversation", &dieterv1.WatchConversationRequest{CardId: "card"}, &dieterv1.WatchConversationRequest{CardId: "card", AfterSeq: 7}, []proto.Message{&dieterv1.ConversationUpdate{LastSeq: 7}}},
		{"WatchConversation", &dieterv1.WatchConversationRequest{CardId: "card"}, &dieterv1.WatchConversationRequest{CardId: "card", AfterSeq: 7}, []proto.Message{&dieterv1.ConversationUpdate{Snapshot: &dieterv1.ConversationSnapshot{Conversation: &dieterv1.Conversation{LastSeq: 7}}}}},
		{"WatchTerminal", &dieterv1.WatchTerminalRequest{TerminalId: "terminal"}, &dieterv1.WatchTerminalRequest{TerminalId: "terminal", AfterSequence: 7}, []proto.Message{&dieterv1.TerminalFrame{Sequence: 7, Data: []byte("data")}, &dieterv1.TerminalFrame{Sequence: 99, Heartbeat: true}}},
		{"WatchExecution", &dieterv1.WatchExecutionRequest{ExecutionId: "exec"}, &dieterv1.WatchExecutionRequest{ExecutionId: "exec", AfterSequence: 7}, []proto.Message{&dieterv1.ExecutionEvent{Sequence: 7, Data: []byte("data")}, &dieterv1.ExecutionEvent{Sequence: 99, Heartbeat: true}}},
		{"WatchExecution", &dieterv1.WatchExecutionRequest{ExecutionId: "exec", AfterSequence: 100}, &dieterv1.WatchExecutionRequest{ExecutionId: "exec", AfterSequence: 7}, []proto.Message{&dieterv1.ExecutionEvent{Sequence: 7, Reset_: true}}},
		{"WatchGitOperation", &dieterv1.WatchGitOperationRequest{OperationId: "op"}, &dieterv1.WatchGitOperationRequest{OperationId: "op", AfterSequence: 7}, []proto.Message{&dieterv1.GitOperationFrame{Logs: []*dieterv1.GitOperationLogEntry{{Sequence: 6}, {Sequence: 7}}}}},
		{"WatchSync", &dieterv1.SyncRequest{ProtocolVersion: 1}, &dieterv1.SyncRequest{ProtocolVersion: 1, After: &dieterv1.SyncCursor{Sequence: 7}}, []proto.Message{
			&dieterv1.SyncFrame{Cursor: &dieterv1.SyncCursor{Sequence: 7}},
			&dieterv1.SyncFrame{Cursor: &dieterv1.SyncCursor{Sequence: 8}, ProjectionPending: true},
			&dieterv1.SyncFrame{Cursor: &dieterv1.SyncCursor{Sequence: 9}, Heartbeat: true},
			&dieterv1.SyncFrame{ObservedCursor: &dieterv1.SyncCursor{Sequence: 99}, TransportOnly: true},
		}},
		{"WatchState", &dieterv1.WatchStateRequest{IntervalMs: 1000}, &dieterv1.WatchStateRequest{IntervalMs: 1000}, []proto.Message{&dieterv1.State{}}},
	} {
		t.Run(test.method, func(t *testing.T) {
			requests := make(chan proto.Message, 2)
			var calls atomic.Int32
			connection := readStreamTestConnection(t, func(_ any, stream grpc.ServerStream) error {
				request := test.request.ProtoReflect().New().Interface()
				if err := stream.RecvMsg(request); err != nil {
					return err
				}
				requests <- request
				if calls.Add(1) == 1 {
					for _, response := range test.responses {
						if err := stream.SendMsg(response); err != nil {
							return err
						}
					}
					return status.Error(codes.DeadlineExceeded, "credential expired")
				}
				return nil
			})
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			stream, err := (readResumingConn{connection}).NewStream(ctx, &grpc.StreamDesc{ServerStreams: true}, "/dieter.v1.DieterService/"+test.method)
			if err != nil {
				t.Fatal(err)
			}
			original := proto.Clone(test.request)
			if err := stream.SendMsg(test.request); err != nil {
				t.Fatal(err)
			}
			if err := stream.CloseSend(); err != nil {
				t.Fatal(err)
			}
			for _, response := range test.responses {
				got := response.ProtoReflect().New().Interface()
				if err := stream.RecvMsg(got); err != nil || !proto.Equal(got, response) {
					t.Fatalf("response=%v err=%v", got, err)
				}
			}
			if err := stream.RecvMsg(test.responses[0].ProtoReflect().New().Interface()); !errors.Is(err, io.EOF) {
				t.Fatal(err)
			}
			if got := <-requests; !proto.Equal(got, original) {
				t.Fatalf("initial=%v", got)
			}
			if got := <-requests; !proto.Equal(got, test.resumed) {
				t.Fatalf("resumed=%v want=%v", got, test.resumed)
			}
			if !proto.Equal(test.request, original) {
				t.Fatal("mutated caller request")
			}
		})
	}
}

func TestReadRecoveryStopsOnRevocationAndCallerCancellation(t *testing.T) {
	for _, code := range []codes.Code{codes.Unauthenticated, codes.PermissionDenied, codes.NotFound, codes.Unavailable} {
		t.Run(code.String(), func(t *testing.T) {
			var calls atomic.Int32
			entered := make(chan struct{}, 1)
			connection := readStreamTestConnection(t, func(_ any, stream grpc.ServerStream) error {
				calls.Add(1)
				select {
				case entered <- struct{}{}:
				default:
				}
				return status.Error(code, "test failure")
			})
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			client := dieterv1.NewDieterServiceClient(readResumingConn{connection})
			stream, err := client.WatchState(ctx, &dieterv1.WatchStateRequest{})
			if err != nil {
				t.Fatal(err)
			}
			if code == codes.Unavailable {
				go func() { <-entered; cancel() }()
			}
			_, err = stream.Recv()
			want := code
			if code == codes.Unavailable {
				want = codes.Canceled
			}
			if status.Code(err) != want || calls.Load() != 1 {
				t.Fatalf("calls=%d err=%v", calls.Load(), err)
			}
		})
	}
}

func TestRecoveryNeverReplaysMutationsOrScreenAdmission(t *testing.T) {
	var calls atomic.Int32
	connection := readStreamTestConnection(t, func(_ any, stream grpc.ServerStream) error {
		calls.Add(1)
		return status.Error(codes.Unavailable, "response lost after dispatch")
	})
	client := dieterv1.NewDieterServiceClient(readResumingConn{connection})
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	_, _ = client.StartExecution(ctx, &dieterv1.StartExecutionRequest{})
	if calls.Load() != 1 {
		t.Fatalf("mutation dispatched %d times", calls.Load())
	}
	stream, err := client.StartRemoteDesktop(ctx, &dieterv1.StartRemoteDesktopRequest{InputProtocolVersion: 1})
	if err == nil {
		_, _ = stream.Recv()
	}
	if calls.Load() != 2 {
		t.Fatalf("screen admission dispatched %d times", calls.Load()-1)
	}
}

func TestReadRecoveryHasFiniteFailureBudget(t *testing.T) {
	var calls atomic.Int32
	connection := readStreamTestConnection(t, func(_ any, stream grpc.ServerStream) error {
		calls.Add(1)
		return status.Error(codes.Unavailable, "offline")
	})
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	stream, err := dieterv1.NewDieterServiceClient(readResumingConn{connection}).WatchState(ctx, &dieterv1.WatchStateRequest{})
	if err != nil {
		t.Fatal(err)
	}
	_, err = stream.Recv()
	if status.Code(err) != codes.Unavailable || calls.Load() != 6 || ctx.Err() != nil {
		t.Fatalf("attempts=%d err=%v caller=%v", calls.Load(), err, ctx.Err())
	}
}
