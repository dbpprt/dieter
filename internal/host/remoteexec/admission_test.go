package remoteexec

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

func TestStartRejectsInvalidRequestsAsInvalidArgument(t *testing.T) {
	t.Parallel()
	manager := New()
	t.Cleanup(func() { manager.Shutdown(context.Background()) })
	directory := t.TempDir()
	valid := StartInput{Argv: []string{"/usr/bin/true"}, WorkingDirectory: directory}
	for name, mutate := range map[string]func(*StartInput){
		"empty argv":          func(input *StartInput) { input.Argv = nil },
		"blank command":       func(input *StartInput) { input.Argv = []string{"  "} },
		"too many arguments":  func(input *StartInput) { input.Argv = make([]string, 257); input.Argv[0] = "/usr/bin/true" },
		"NUL in argument":     func(input *StartInput) { input.Argv = []string{"/usr/bin/true", "a\x00b"} },
		"missing directory":   func(input *StartInput) { input.WorkingDirectory = directory + "/missing" },
		"long name":           func(input *StartInput) { input.Name = strings.Repeat("n", 81) },
		"large initial input": func(input *StartInput) { input.Stdin = make([]byte, maxInputBytes+1) },
		"negative timeout":    func(input *StartInput) { input.Timeout = -time.Second },
		"week-long timeout":   func(input *StartInput) { input.Timeout = 7*24*time.Hour + time.Second },
		"tiny output budget":  func(input *StartInput) { input.MaxOutputBytes = maxFrameBytes - 1 },
		"huge output budget":  func(input *StartInput) { input.MaxOutputBytes = maximumMaxOutputBytes + 1 },
		"invalid env name":    func(input *StartInput) { input.Environment = map[string]string{"1BAD": "x"} },
		"NUL in env value":    func(input *StartInput) { input.Environment = map[string]string{"GOOD": "a\x00"} },
		"too many env values": func(input *StartInput) {
			input.Environment = map[string]string{}
			for index := range 129 {
				input.Environment["VALUE_"+strings.Repeat("X", index)] = "x"
			}
		},
		"tiny PTY": func(input *StartInput) { input.PTY, input.Columns, input.Rows = true, 1, 24 },
		"huge PTY": func(input *StartInput) { input.PTY, input.Columns, input.Rows = true, 80, maximumDimension+1 },
	} {
		input := valid
		mutate(&input)
		_, err := manager.Start(input)
		if kind, ok := fault.KindOf(err); !ok || kind != fault.Invalid {
			t.Errorf("%s: %v", name, err)
		}
	}
	if executions := manager.List("", "", ""); len(executions) != 0 {
		t.Fatalf("rejected requests started processes: %#v", executions)
	}
}

func TestRunningExecutionsAreBoundedAndCancelable(t *testing.T) {
	t.Parallel()
	manager := New()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		manager.Shutdown(ctx)
	})
	directory := t.TempDir()
	var running []Execution
	for index := range maxRunningExecutions {
		value, err := manager.Start(StartInput{
			ProjectID: "p_bounded", CardID: []string{"c_even", "c_odd"}[index%2],
			Argv: []string{"/bin/sh", "-c", "read line"}, WorkingDirectory: directory,
		})
		if err != nil {
			t.Fatalf("start %d: %v", index, err)
		}
		running = append(running, value)
	}
	if _, err := manager.Start(StartInput{Argv: []string{"/usr/bin/true"}, WorkingDirectory: directory}); !errors.Is(err, ErrLimitReached) {
		t.Fatalf("execution above the running limit: %v", err)
	}
	if got := manager.List("p_bounded", "c_odd", StatusRunning); len(got) != maxRunningExecutions/2 {
		t.Fatalf("filtered list = %d executions", len(got))
	}
	canceled, err := manager.Cancel(running[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, final := waitExecution(t, manager, canceled.ID); final.Status != StatusCanceled {
		t.Fatalf("canceled execution = %#v", final)
	}
	if again, err := manager.Cancel(running[0].ID); err != nil || again.Status != StatusCanceled {
		t.Fatalf("repeated cancel = %#v, %v", again, err)
	}
	if _, err := manager.Signal(running[0].ID, SignalInterrupt); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("signal after exit: %v", err)
	}
	replacement, err := manager.Start(StartInput{Argv: []string{"/usr/bin/true"}, WorkingDirectory: directory, StdinEOF: true})
	if err != nil {
		t.Fatalf("slot was not released: %v", err)
	}
	if _, final := waitExecution(t, manager, replacement.ID); final.Status != StatusExited {
		t.Fatalf("replacement = %#v", final)
	}
	for _, value := range running[1:] {
		if _, err := manager.Write(value.ID, []byte("done\n"), true); err != nil {
			t.Fatal(err)
		}
	}
}

func TestSignalsReachTheProcessGroupAndReportTheSignal(t *testing.T) {
	t.Parallel()
	manager := New()
	t.Cleanup(func() { manager.Shutdown(context.Background()) })
	trapped, err := manager.Start(StartInput{
		Argv:             []string{"/bin/sh", "-c", "trap 'exit 42' INT; printf ready; while :; do sleep 0.05; done"},
		WorkingDirectory: t.TempDir(),
	})
	if err != nil {
		t.Fatal(err)
	}
	waitOutput(t, manager, trapped.ID, "ready")
	if _, err := manager.Signal(trapped.ID, SignalInterrupt); err != nil {
		t.Fatal(err)
	}
	if _, final := waitExecution(t, manager, trapped.ID); final.Status != StatusExited || final.ExitCode == nil || *final.ExitCode != 42 {
		t.Fatalf("trapped interrupt = %#v", final)
	}
	killed, err := manager.Start(StartInput{Argv: []string{"/bin/sh", "-c", "printf ready; exec sleep 30"}, WorkingDirectory: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	waitOutput(t, manager, killed.ID, "ready")
	if _, err := manager.Signal(killed.ID, SignalKill); err != nil {
		t.Fatal(err)
	}
	if _, final := waitExecution(t, manager, killed.ID); final.ExitSignal != "killed" {
		t.Fatalf("killed execution = %#v", final)
	}
	if _, err := manager.Get("exec_missing"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown execution: %v", err)
	}
	if err := manager.Close("exec_missing"); err != nil {
		t.Fatalf("closing an unknown execution must be idempotent: %v", err)
	}
}

func TestExecutionEnvironmentOverridesAndPTYDefaults(t *testing.T) {
	t.Parallel()
	base := []string{"PATH=/bin", "TERM=dumb", "HOME=/home/test"}
	plain := executionEnvironment(base, map[string]string{"HOME": "/override", "EXTRA": "1"}, false)
	if !slices.Equal(plain, []string{"EXTRA=1", "HOME=/override", "PATH=/bin", "TERM=dumb"}) {
		t.Fatalf("plain environment = %q", plain)
	}
	pty := executionEnvironment([]string{"PATH=/bin"}, nil, true)
	if !slices.Equal(pty, []string{"COLORTERM=truecolor", "PATH=/bin", "TERM=xterm-256color", "TERM_PROGRAM=Dieter"}) {
		t.Fatalf("PTY environment = %q", pty)
	}
	if kept := executionEnvironment(base, nil, true); !slices.Contains(kept, "TERM=dumb") {
		t.Fatalf("PTY replaced an explicit TERM: %q", kept)
	}
	for key, want := range map[string]bool{"PATH": true, "_PRIVATE": true, "Ünïcode": true, "A1": true, "": false, "1A": false, "A-B": false, "A=B": false} {
		if got := validEnvironmentKey(key); got != want {
			t.Errorf("validEnvironmentKey(%q)=%v", key, got)
		}
	}
}

// waitOutput waits until the execution's output contains marker.
func waitOutput(t *testing.T, manager *Manager, id, marker string) {
	t.Helper()
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	after := uint64(0)
	var output strings.Builder
	for !strings.Contains(output.String(), marker) {
		events, changed, err := manager.Events(id, after)
		if err != nil {
			t.Fatal(err)
		}
		for _, event := range events {
			output.Write(event.Data)
			after = max(after, event.Sequence)
		}
		if strings.Contains(output.String(), marker) {
			return
		}
		select {
		case <-changed:
		case <-deadline.C:
			t.Fatalf("execution %s did not print %q: %q", id, marker, output.String())
		}
	}
}
