//go:build !windows

package server

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func TestExecutionGRPCResumesAfterDisconnectAndPreservesStreams(t *testing.T) {
	repository := filepath.Join(t.TempDir(), "repository")
	if err := os.MkdirAll(filepath.Join(repository, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Execution fixture", Path: repository})
	if err != nil {
		t.Fatal(err)
	}
	application := New(data, slog.New(slog.NewTextHandler(io.Discard, nil)))
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	httpServer := &http.Server{Handler: application.Handler()}
	go func() { _ = httpServer.Serve(listener) }()
	t.Cleanup(func() {
		_ = httpServer.Close()
		_ = listener.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		application.executions.Shutdown(ctx)
	})
	connection, err := grpc.NewClient(listener.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	client := dieterv1.NewDieterServiceClient(connection)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	created, err := client.StartExecution(ctx, &dieterv1.StartExecutionRequest{
		ProjectId: project.ID, Argv: []string{"/bin/sh", "-c", "printf first; printf error >&2; read value; printf second"},
		WorkingDirectory: repository, IdempotencyKey: "grpc-resume",
	})
	if err != nil || created.GetStatus() != "running" || created.GetPid() == 0 {
		t.Fatalf("created execution = %#v, %v", created, err)
	}
	firstCtx, stopFirst := context.WithCancel(ctx)
	watch, err := client.WatchExecution(firstCtx, &dieterv1.WatchExecutionRequest{ExecutionId: created.GetId(), HeartbeatMs: 1_000})
	if err != nil {
		t.Fatal(err)
	}
	var firstOut, firstErr bytes.Buffer
	var firstSequence uint64
	for firstOut.String() != "first" || firstErr.String() != "error" {
		event, err := watch.Recv()
		if err != nil {
			t.Fatal(err)
		}
		firstSequence = event.GetSequence()
		switch event.GetStream() {
		case dieterv1.ExecutionStream_EXECUTION_STREAM_STDOUT:
			firstOut.Write(event.GetData())
		case dieterv1.ExecutionStream_EXECUTION_STREAM_STDERR:
			firstErr.Write(event.GetData())
		}
	}
	stopFirst()
	if _, err := client.WriteExecutionInput(ctx, &dieterv1.ExecutionInputRequest{ExecutionId: created.GetId(), Data: []byte("continue\n"), Eof: true}); err != nil {
		t.Fatal(err)
	}
	resumed, err := client.WatchExecution(ctx, &dieterv1.WatchExecutionRequest{ExecutionId: created.GetId(), AfterSequence: firstSequence, HeartbeatMs: 1_000})
	if err != nil {
		t.Fatal(err)
	}
	var resumedOut bytes.Buffer
	var final *dieterv1.Execution
	for {
		event, err := resumed.Recv()
		if err != nil {
			t.Fatal(err)
		}
		if event.GetSequence() <= firstSequence {
			t.Fatalf("resumed sequence %d <= %d", event.GetSequence(), firstSequence)
		}
		if event.GetStream() == dieterv1.ExecutionStream_EXECUTION_STREAM_STDOUT {
			resumedOut.Write(event.GetData())
		}
		if event.GetEof() {
			final = event.GetExecution()
			break
		}
	}
	if resumedOut.String() != "second" || final.GetStatus() != "exited" || final.ExitCode == nil || final.GetExitCode() != 0 {
		t.Fatalf("resumed output=%q final=%#v", resumedOut.String(), final)
	}
	repeated, err := client.StartExecution(ctx, &dieterv1.StartExecutionRequest{
		ProjectId: project.ID, Argv: []string{"/bin/sh", "-c", "printf first; printf error >&2; read value; printf second"},
		WorkingDirectory: repository, IdempotencyKey: "grpc-resume",
	})
	if err != nil || repeated.GetId() != created.GetId() {
		t.Fatalf("repeated execution = %#v, %v", repeated, err)
	}
	listed, err := client.ListExecutions(ctx, &dieterv1.ListExecutionsRequest{ProjectId: project.ID})
	if err != nil || len(listed.GetExecutions()) != 1 {
		t.Fatalf("listed executions = %#v, %v", listed, err)
	}
	if _, err := client.CloseExecution(ctx, &dieterv1.ExecutionRef{ExecutionId: created.GetId()}); err != nil {
		t.Fatal(err)
	}
}
