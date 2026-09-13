package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
)

type fixtureHarness struct {
	run     func(context.Context) error
	cancel  func() error
	suspend func() error
}

func (runner fixtureHarness) Run(ctx context.Context, _ harness.Request, _ func(harness.Output) error) error {
	return runner.run(ctx)
}

func (runner fixtureHarness) Cancel(string, string) error {
	if runner.cancel != nil {
		return runner.cancel()
	}
	return nil
}

func (runner fixtureHarness) Suspend(string, string) error {
	if runner.suspend != nil {
		return runner.suspend()
	}
	return nil
}

func waitFixtureSignal(t *testing.T, signal <-chan struct{}, message string) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(5 * time.Second):
		t.Fatal(message)
	}
}

func TestIsolatedRunnerShutdownDrainsPreparationAndRejectsAdmissions(t *testing.T) {
	started := make(chan struct{})
	canceled := make(chan struct{})
	finishPreparation := make(chan struct{})
	var finishOnce sync.Once
	finish := func() { finishOnce.Do(func() { close(finishPreparation) }) }
	t.Cleanup(finish)
	var calls atomic.Int32
	runner := newIsolatedRunner(fixtureHarness{run: func(ctx context.Context) error {
		calls.Add(1)
		close(started)
		<-ctx.Done()
		close(canceled)
		// A canceled preparation may still be waiting for its child to exit.
		<-finishPreparation
		return ctx.Err()
	}})
	returned := make(chan error, 1)
	go func() { returned <- runner.Run(context.Background(), harness.Request{}, nil) }()
	waitFixtureSignal(t, started, "preparation did not start")
	drained := make(chan struct{})
	go func() {
		runner.Shutdown()
		close(drained)
	}()
	waitFixtureSignal(t, canceled, "shutdown did not cancel preparation")
	select {
	case <-drained:
		t.Fatal("shutdown returned while preparation could still write files")
	default:
	}
	if err := runner.Run(context.Background(), harness.Request{}, nil); !errors.Is(err, context.Canceled) {
		t.Fatalf("admission during shutdown: %v", err)
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("delegate received %d admissions, want 1", got)
	}
	finish()
	waitFixtureSignal(t, drained, "shutdown did not drain completed preparation")
	if err := <-returned; !errors.Is(err, context.Canceled) {
		t.Fatalf("active run returned %v", err)
	}
	// Repeated shutdown remains safe once all writers have exited.
	runner.Shutdown()
}

func TestIsolatedRunnerShutdownWaitsForRuntimeWriterProcess(t *testing.T) {
	root := t.TempDir()
	runtime := filepath.Join(root, "runtime")
	if err := os.Mkdir(runtime, 0o700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(runtime, "still-writing")
	started := make(chan struct{})
	var command *exec.Cmd
	runner := newIsolatedRunner(fixtureHarness{run: func(ctx context.Context) error {
		command = exec.CommandContext(ctx, os.Args[0], "-test.run=^TestRuntimeWriterChildProcess$")
		command.Env = append(os.Environ(), "DIETER_FIXTURE_WRITER_PATH="+marker)
		if err := command.Start(); err != nil {
			return err
		}
		close(started)
		return command.Wait()
	}})
	t.Cleanup(runner.Shutdown)
	returned := make(chan error, 1)
	go func() { returned <- runner.Run(context.Background(), harness.Request{}, nil) }()
	waitFixtureSignal(t, started, "runtime writer did not start")
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(marker); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("child process did not write its runtime marker")
		}
		time.Sleep(10 * time.Millisecond)
	}
	drained := make(chan struct{})
	go func() {
		runner.Shutdown()
		close(drained)
	}()
	waitFixtureSignal(t, drained, "shutdown did not wait for runtime writer exit")
	if err := <-returned; err == nil {
		t.Fatal("runtime writer exited without cancellation")
	}
	if command.ProcessState == nil {
		t.Fatal("shutdown returned without reaping its runtime writer")
	}
	if err := os.RemoveAll(runtime); err != nil {
		t.Fatalf("remove drained runtime: %v", err)
	}
}

func TestRuntimeWriterChildProcess(t *testing.T) {
	marker := os.Getenv("DIETER_FIXTURE_WRITER_PATH")
	if marker == "" {
		return
	}
	for {
		if err := os.WriteFile(marker, []byte("writing"), 0o600); err != nil {
			os.Exit(2)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestIsolatedRunnerPreservesLifecycleInterfaces(t *testing.T) {
	cancelError, suspendError := errors.New("cancel forwarded"), errors.New("suspend forwarded")
	runner := newIsolatedRunner(fixtureHarness{
		cancel: func() error { return cancelError }, suspend: func() error { return suspendError },
	})
	var canceller harness.Canceller = runner
	var suspender harness.Suspender = runner
	if !errors.Is(canceller.Cancel("session", "runtime"), cancelError) {
		t.Fatal("Cancel was not forwarded")
	}
	if !errors.Is(suspender.Suspend("session", "runtime"), suspendError) {
		t.Fatal("Suspend was not forwarded")
	}
}
