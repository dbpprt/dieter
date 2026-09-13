package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
)

func TestEnrollmentRPCBoundsAndReleasesOnlyItsRequestContext(t *testing.T) {
	var output bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&output, nil))
	parent, cancel := context.WithCancel(context.Background())
	defer cancel()
	var requestContext context.Context
	value, err := enrollmentRPC(parent, logger, "primary", "begin", func(ctx context.Context) (string, error) {
		requestContext = ctx
		deadline, ok := ctx.Deadline()
		remaining := time.Until(deadline)
		if !ok || remaining <= 0 || remaining > 30*time.Second {
			t.Fatalf("enrollment request has no bounded 30-second deadline: %v, %s", ok, remaining)
		}
		return "private-enrollment-secret", nil
	})
	if err != nil || value != "private-enrollment-secret" {
		t.Fatalf("enrollment response changed: %q, %v", value, err)
	}
	if !errors.Is(requestContext.Err(), context.Canceled) {
		t.Fatal("completed enrollment did not release its request context")
	}
	if parent.Err() != nil {
		t.Fatal("enrollment canceled the long-lived fixture context")
	}
	log := output.String()
	for _, expected := range []string{"isolated enrollment starting", "isolated enrollment completed", "role=primary", "operation=begin", "elapsed="} {
		if !strings.Contains(log, expected) {
			t.Fatalf("missing %q in progress log: %s", expected, log)
		}
	}
	if strings.Contains(log, value) {
		t.Fatal("enrollment progress exposed the response secret")
	}
}

func TestEnrollmentRPCIdentifiesRoleAndOperationOnFailure(t *testing.T) {
	for _, role := range []string{"primary", "legacy", "second"} {
		for _, operation := range []string{"begin", "complete"} {
			t.Run(role+"/"+operation, func(t *testing.T) {
				var output bytes.Buffer
				logger := slog.New(slog.NewTextHandler(&output, nil))
				cause := errors.New("transport unavailable")
				_, err := enrollmentRPC(context.Background(), logger, role, operation, func(context.Context) (int, error) {
					return 0, cause
				})
				if !errors.Is(err, cause) || !strings.Contains(err.Error(), "isolated "+role+" enrollment "+operation+" failed after ") {
					t.Fatalf("enrollment failure lost context or cause: %v", err)
				}
				if strings.Contains(output.String(), "enrollment completed") {
					t.Fatal("failed enrollment logged completion")
				}
			})
		}
	}
}

func TestEnrollmentRPCPreservesCancellationAndEarlierDeadline(t *testing.T) {
	for _, canceled := range []bool{false, true} {
		name := "deadline"
		if canceled {
			name = "canceled"
		}
		t.Run(name, func(t *testing.T) {
			parent, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
			defer cancel()
			if canceled {
				cancel()
			}
			var output bytes.Buffer
			logger := slog.New(slog.NewTextHandler(&output, nil))
			_, err := enrollmentRPC(parent, logger, "legacy", "complete", func(ctx context.Context) (int, error) {
				parentDeadline, _ := parent.Deadline()
				requestDeadline, _ := ctx.Deadline()
				if !requestDeadline.Equal(parentDeadline) {
					t.Fatal("enrollment extended its parent's earlier deadline")
				}
				<-ctx.Done()
				return 0, ctx.Err()
			})
			if !errors.Is(err, parent.Err()) {
				t.Fatalf("enrollment lost parent cancellation/deadline: %v", err)
			}
		})
	}
}

type fixtureHarness struct {
	run     func(context.Context) error
	cancel  func() error
	suspend func() error
}

type diagnosticHarness struct {
	fixtureHarness
	runOutput func(context.Context, harness.Request, func(harness.Output) error) error
}

func (runner diagnosticHarness) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	return runner.runOutput(ctx, request, emit)
}

func diagnosticRecords(t *testing.T, output string) []map[string]any {
	t.Helper()
	var records []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		var record map[string]any
		if err := json.Unmarshal([]byte(line), &record); err != nil {
			t.Fatal(err)
		}
		for key := range record {
			switch key {
			case "time", "level", "msg", "sequence", "harness", "phase", "elapsed_ms", "error_class":
			default:
				t.Fatalf("unexpected diagnostic field %q", key)
			}
		}
		if elapsed, ok := record["elapsed_ms"].(float64); !ok || elapsed < 0 {
			t.Fatal("missing or invalid elapsed time")
		}
		records = append(records, record)
	}
	return records
}

func TestIsolatedRunnerDiagnosticsBoundAndPreserveOutput(t *testing.T) {
	secret := strings.Repeat("private-token-prompt-account-path-output-error\n", 100)
	cause := errors.New(secret)
	for _, provider := range []string{"mock", "codex", secret} {
		name := provider
		if provider == secret {
			name = "unknown"
		}
		t.Run(name, func(t *testing.T) {
			var output bytes.Buffer
			var received atomic.Int32
			runner := newIsolatedRunner(diagnosticHarness{runOutput: func(_ context.Context, request harness.Request, emit func(harness.Output) error) error {
				if request.Prompt != secret || request.ProjectPath != secret || request.SessionID != secret {
					t.Error("diagnostics changed the request")
				}
				var emits sync.WaitGroup
				for range 2 {
					emits.Add(1)
					go func() {
						defer emits.Done()
						if err := emit(harness.Output{Type: secret, Chunk: json.RawMessage(secret)}); err != nil {
							t.Error(err)
						}
					}()
				}
				emits.Wait()
				return cause
			}})
			runner.logger = slog.New(slog.NewJSONHandler(&output, nil))
			for range 2 {
				err := runner.Run(context.Background(), harness.Request{Harness: provider, Prompt: secret, ProjectPath: secret, SessionID: secret}, func(value harness.Output) error {
					if value.Type != secret || string(value.Chunk) != secret {
						t.Error("diagnostics changed harness output")
					}
					received.Add(1)
					return nil
				})
				if err != cause {
					t.Fatal("diagnostics replaced the original error")
				}
			}
			if received.Load() != 4 || output.Len() > 2048 || strings.Contains(output.String(), "private-") {
				t.Fatal("diagnostics lost output, exceeded bounds, or exposed sensitive data")
			}
			records := diagnosticRecords(t, output.String())
			if len(records) != 6 {
				t.Fatalf("expected three diagnostic records per turn, got %d", len(records))
			}
			expectedProvider := provider
			if provider == secret {
				expectedProvider = "other"
			}
			for index, record := range records {
				if record["sequence"] != float64(index/3+1) || record["harness"] != expectedProvider || record["phase"] != []string{"start", "first_output", "finish"}[index%3] {
					t.Fatalf("unexpected lifecycle record: %#v", record)
				}
				if index%3 == 2 && record["error_class"] != "error" {
					t.Fatal("raw failure did not use fixed error category")
				}
			}
		})
	}
}

func TestIsolatedRunnerDiagnosticsCompletionAndCancellation(t *testing.T) {
	for _, classification := range []string{"ok", "canceled", "deadline_exceeded"} {
		t.Run(classification, func(t *testing.T) {
			var output bytes.Buffer
			entered := make(chan struct{})
			runner := newIsolatedRunner(fixtureHarness{run: func(ctx context.Context) error {
				close(entered)
				if classification == "canceled" {
					<-ctx.Done()
					return fmt.Errorf("private-error: %w", ctx.Err())
				}
				if classification == "deadline_exceeded" {
					return fmt.Errorf("private-error: %w", context.DeadlineExceeded)
				}
				return nil
			}})
			runner.logger = slog.New(slog.NewJSONHandler(&output, nil))
			finished := make(chan error, 1)
			go func() { finished <- runner.Run(context.Background(), harness.Request{Harness: "mock"}, nil) }()
			<-entered
			if classification == "canceled" {
				runner.Shutdown()
			}
			err := <-finished
			if classification == "canceled" && !errors.Is(err, context.Canceled) || classification == "deadline_exceeded" && !errors.Is(err, context.DeadlineExceeded) || classification == "ok" && err != nil {
				t.Fatal("diagnostics changed completion behavior")
			}
			records := diagnosticRecords(t, output.String())
			if len(records) != 2 || records[0]["phase"] != "start" || records[1]["phase"] != "finish" || records[1]["error_class"] != classification || strings.Contains(output.String(), "private-") {
				t.Fatalf("invalid completion diagnostics: %s", output.String())
			}
		})
	}
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
