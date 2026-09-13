//go:build !windows

package server

import (
	"bytes"
	"context"
	"errors"
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
	terminalmanager "github.com/dbpprt/dieter/internal/terminal"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
)

func TestTerminalWorkingDirectoryStaysInsideProjectAfterSymlinkResolution(t *testing.T) {
	repository := filepath.Join(t.TempDir(), "repository")
	inside := filepath.Join(repository, "nested")
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.MkdirAll(filepath.Join(repository, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(inside, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(outside, 0o755); err != nil {
		t.Fatal(err)
	}
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Terminal fixture", Path: repository})
	if err != nil {
		t.Fatal(err)
	}

	resolved, err := terminalWorkingDirectory(project, "nested")
	wantInside, wantErr := filepath.EvalSymlinks(inside)
	if err != nil || wantErr != nil || resolved != wantInside {
		t.Fatalf("inside path = %q, %v", resolved, err)
	}
	if _, err := terminalWorkingDirectory(project, outside); err == nil {
		t.Fatal("outside path was accepted")
	}
	link := filepath.Join(repository, "outside-link")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	if _, err := terminalWorkingDirectory(project, link); err == nil {
		t.Fatal("symlink escape was accepted")
	}
	if _, err := terminalWorkingDirectory(project, filepath.Join(repository, "missing")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("missing path error = %v", err)
	}
}

func TestMachineTerminalWorkingDirectoryStaysInsideHome(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	want, err := filepath.EvalSymlinks(home)
	if err != nil {
		t.Fatal(err)
	}
	got, err := terminalMachineWorkingDirectory("~")
	if err != nil || got != want {
		t.Fatalf("machine home = %q, %v; want %q", got, err, want)
	}
	if want != string(filepath.Separator) {
		if _, err := terminalMachineWorkingDirectory(string(filepath.Separator)); err == nil {
			t.Fatal("directory outside the daemon user's home was accepted")
		}
	}
}

func TestTerminalGRPCPersistsAcrossWatchReconnect(t *testing.T) {
	repository := filepath.Join(t.TempDir(), "repository")
	if err := os.MkdirAll(filepath.Join(repository, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Terminal fixture", Path: repository})
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
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		application.terminals.Shutdown(ctx)
	})
	connection, err := grpc.NewClient(listener.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	client := dieterv1.NewDieterServiceClient(connection)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	created, err := client.CreateTerminal(ctx, &dieterv1.CreateTerminalRequest{
		ProjectId: project.ID, Shell: "sh", WorkingDirectory: repository, Columns: 100, Rows: 30,
	})
	if err != nil || created.GetStatus() != "running" || created.GetPid() == 0 {
		t.Fatalf("created terminal = %#v, %v", created, err)
	}
	firstCtx, stopFirst := context.WithCancel(ctx)
	watch, err := client.WatchTerminal(firstCtx, &dieterv1.WatchTerminalRequest{TerminalId: created.GetId(), HeartbeatMs: 1_000})
	if err != nil {
		t.Fatal(err)
	}
	baseline, err := watch.Recv()
	if err != nil || !baseline.GetScreenReset() {
		t.Fatalf("baseline = %#v, %v", baseline, err)
	}
	if _, err := client.WriteTerminal(ctx, &dieterv1.TerminalInputRequest{TerminalId: created.GetId(), Data: []byte("printf 'grpc-first-marker\\n'\n")}); err != nil {
		t.Fatal(err)
	}
	firstSequence := receiveTerminalMarker(t, watch, []byte("grpc-first-marker"))
	stopFirst()

	if _, err := client.WriteTerminal(ctx, &dieterv1.TerminalInputRequest{TerminalId: created.GetId(), Data: []byte("printf 'grpc-resume-marker\\n'\n")}); err != nil {
		t.Fatal(err)
	}
	resumed, err := client.WatchTerminal(ctx, &dieterv1.WatchTerminalRequest{
		TerminalId: created.GetId(), AfterSequence: firstSequence, HeartbeatMs: 1_000,
	})
	if err != nil {
		t.Fatal(err)
	}
	nextSequence := receiveTerminalMarker(t, resumed, []byte("grpc-resume-marker"))
	if nextSequence <= firstSequence {
		t.Fatalf("resume sequence did not advance: %d <= %d", nextSequence, firstSequence)
	}
	listed, err := client.ListTerminals(ctx, &dieterv1.ListTerminalsRequest{ProjectId: project.ID})
	if err != nil || len(listed.GetTerminals()) != 1 || listed.GetTerminals()[0].GetId() != created.GetId() {
		t.Fatalf("listed terminals = %#v, %v", listed, err)
	}
	if _, err := client.CloseTerminal(ctx, &dieterv1.TerminalRef{TerminalId: created.GetId()}); err != nil {
		t.Fatal(err)
	}
	homeTerminal, err := client.CreateTerminal(ctx, &dieterv1.CreateTerminalRequest{
		MachineHome: true, Name: "machine-home", Shell: "sh", WorkingDirectory: "~", Columns: 80, Rows: 24,
	})
	if err != nil || homeTerminal.GetProjectId() != "" || homeTerminal.GetCardId() != "" || homeTerminal.GetStatus() != "running" {
		t.Fatalf("machine-home terminal = %#v, %v", homeTerminal, err)
	}
	if _, err := client.CreateTerminal(ctx, &dieterv1.CreateTerminalRequest{
		MachineHome: true, ProjectId: project.ID, Shell: "sh",
	}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("combined machine/project scope error = %v", err)
	}
	if _, err := client.CloseTerminal(ctx, &dieterv1.TerminalRef{TerminalId: homeTerminal.GetId()}); err != nil {
		t.Fatal(err)
	}
}

func TestTerminalPersistsAcrossServerReconstruction(t *testing.T) {
	data := store.New(t.TempDir())
	first := New(data, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if !first.terminals.Durable() {
		t.Skip("tmux is unavailable")
	}
	created, err := first.terminals.Create(terminalmanager.CreateInput{
		Name: "server-restart", Shell: "sh", WorkingDirectory: t.TempDir(), Columns: 90, Rows: 28,
	})
	if err != nil {
		t.Fatal(err)
	}
	var replacement *Server
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		if replacement != nil {
			replacement.CloseTerminalSessionsForTesting(ctx)
		} else {
			first.CloseTerminalSessionsForTesting(ctx)
		}
	})
	if _, err := first.terminals.Write(created.ID, []byte("printf 'before-server-restart\\n'\n")); err != nil {
		t.Fatal(err)
	}
	before, cursor := receiveManagerMarker(t, first.terminals, created.ID, 0, []byte("before-server-restart"))
	if !bytes.Contains(before, []byte("before-server-restart")) {
		t.Fatalf("initial output = %q", before)
	}

	shutdownContext, shutdownCancel := context.WithTimeout(context.Background(), time.Second)
	first.ShutdownTerminalSessions(shutdownContext)
	shutdownCancel()
	replacement = New(data, slog.New(slog.NewTextHandler(io.Discard, nil)))
	listed := replacement.terminals.List("")
	if len(listed) != 1 || listed[0].ID != created.ID || listed[0].Status != terminalmanager.StatusRunning {
		t.Fatalf("restored server terminals = %#v", listed)
	}
	if _, err := replacement.terminals.Write(created.ID, []byte("printf 'after-server-restart\\n'\n")); err != nil {
		t.Fatal(err)
	}
	after, _ := receiveManagerMarker(
		t, replacement.terminals, created.ID, cursor, []byte("after-server-restart"))
	if !bytes.Contains(after, []byte("after-server-restart")) {
		t.Fatalf("restored output = %q", after)
	}
}

type terminalFrameReceiver interface {
	Recv() (*dieterv1.TerminalFrame, error)
}

func receiveTerminalMarker(t *testing.T, stream terminalFrameReceiver, marker []byte) uint64 {
	t.Helper()
	var data []byte
	var sequence uint64
	for !bytes.Contains(data, marker) {
		frame, err := stream.Recv()
		if err != nil {
			t.Fatal(err)
		}
		data = append(data, frame.GetData()...)
		if frame.GetSequence() > sequence {
			sequence = frame.GetSequence()
		}
	}
	return sequence
}

func receiveManagerMarker(
	t *testing.T, manager *terminalmanager.Manager, id string, after uint64, marker []byte,
) ([]byte, uint64) {
	t.Helper()
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	var data []byte
	for {
		frames, changed, err := manager.Frames(id, after)
		if err != nil {
			t.Fatal(err)
		}
		for _, frame := range frames {
			data = append(data, frame.Data...)
			if frame.Sequence > after {
				after = frame.Sequence
			}
		}
		if bytes.Contains(data, marker) {
			return data, after
		}
		select {
		case <-changed:
		case <-deadline.C:
			t.Fatalf("timed out waiting for %q in %q", marker, data)
		}
	}
}
