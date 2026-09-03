//go:build !windows

package remoteexec

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestExecutionPreservesArgvStreamsAndExitStatus(t *testing.T) {
	manager := New()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		manager.Shutdown(ctx)
	})
	value, err := manager.Start(StartInput{
		Argv:             []string{"/bin/sh", "-c", `printf '%s' "$1"; printf '%s' "$2" >&2; exit 7`, "test", "$(not-a-shell)", "stderr"},
		WorkingDirectory: t.TempDir(), StdinEOF: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	events, final := waitExecution(t, manager, value.ID)
	var stdout, stderr bytes.Buffer
	for _, event := range events {
		switch event.Stream {
		case StreamStdout:
			stdout.Write(event.Data)
		case StreamStderr:
			stderr.Write(event.Data)
		}
	}
	if got := stdout.String(); got != "$(not-a-shell)" {
		t.Fatalf("stdout = %q", got)
	}
	if got := stderr.String(); got != "stderr" {
		t.Fatalf("stderr = %q", got)
	}
	if final.Status != StatusExited || final.ExitCode == nil || *final.ExitCode != 7 {
		t.Fatalf("final execution = %#v", final)
	}
}

func TestImmediateExitDoesNotRaceInitialStdinEOF(t *testing.T) {
	manager := New()
	t.Cleanup(func() { manager.Shutdown(context.Background()) })
	workingDirectory := t.TempDir()
	for iteration := 0; iteration < 100; iteration++ {
		value, err := manager.Start(StartInput{
			Argv: []string{"/usr/bin/true"}, WorkingDirectory: workingDirectory, StdinEOF: true,
		})
		if err != nil {
			t.Fatalf("start iteration %d: %v", iteration, err)
		}
		_, final := waitExecution(t, manager, value.ID)
		if final.Status != StatusExited || final.ExitCode == nil || *final.ExitCode != 0 {
			t.Fatalf("final execution at iteration %d = %#v", iteration, final)
		}
	}
}

func TestExecutionInputIdempotencyAndResume(t *testing.T) {
	manager := New()
	t.Cleanup(func() { manager.Shutdown(context.Background()) })
	input := StartInput{
		Argv:             []string{"/bin/sh", "-c", "read value; printf 'got:%s' \"$value\""},
		WorkingDirectory: t.TempDir(), IdempotencyKey: "stable-key",
	}
	first, err := manager.Start(input)
	if err != nil {
		t.Fatal(err)
	}
	second, err := manager.Start(input)
	if err != nil || second.ID != first.ID {
		t.Fatalf("idempotent start = %#v, %v", second, err)
	}
	conflict := input
	conflict.Argv = []string{"/usr/bin/true"}
	if _, err := manager.Start(conflict); !errors.Is(err, ErrIdempotencyConflict) {
		t.Fatalf("idempotency conflict = %v", err)
	}
	if _, err := manager.Write(first.ID, []byte("hello\n"), true); err != nil {
		t.Fatal(err)
	}
	events, final := waitExecution(t, manager, first.ID)
	if final.ExitCode == nil || *final.ExitCode != 0 {
		t.Fatalf("final execution = %#v", final)
	}
	var output strings.Builder
	for _, event := range events {
		output.Write(event.Data)
	}
	if output.String() != "got:hello" {
		t.Fatalf("output = %q", output.String())
	}
	resumed, _, err := manager.Events(first.ID, events[len(events)-2].Sequence)
	if err != nil || len(resumed) == 0 || !resumed[len(resumed)-1].EOF {
		t.Fatalf("resumed events = %#v, %v", resumed, err)
	}
	finished, _, err := manager.Events(first.ID, final.Sequence)
	if err != nil || len(finished) != 1 || !finished[0].EOF || finished[0].Sequence != final.Sequence {
		t.Fatalf("finished resume = %#v, %v", finished, err)
	}
}

func TestExecutionTimeoutAndCloseAreBounded(t *testing.T) {
	manager := New()
	value, err := manager.Start(StartInput{
		Argv:             []string{"/bin/sh", "-c", "trap 'exit 0' TERM; while :; do sleep 1; done"},
		WorkingDirectory: t.TempDir(), Timeout: 30 * time.Millisecond, StdinEOF: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, final := waitExecution(t, manager, value.ID)
	if final.Status != StatusTimedOut {
		t.Fatalf("status = %q", final.Status)
	}
	other, err := manager.Start(StartInput{Argv: []string{"/bin/sh", "-c", "sleep 10"}, WorkingDirectory: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	if err := manager.Close(other.ID); err != nil {
		t.Fatal(err)
	}
	events, _, err := manager.Events(other.ID, 0)
	if err != nil || len(events) == 0 || !events[len(events)-1].EOF || events[len(events)-1].Execution.Status != StatusClosed {
		t.Fatalf("close events = %#v, %v", events, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	manager.Shutdown(ctx)
	if ctx.Err() != nil {
		t.Fatal("shutdown did not reap remote processes")
	}
}

func TestPTYExecutionSupportsNativeInputAndResize(t *testing.T) {
	manager := New()
	t.Cleanup(func() { manager.Shutdown(context.Background()) })
	value, err := manager.Start(StartInput{
		Argv: []string{"/bin/sh"}, WorkingDirectory: t.TempDir(), PTY: true, Columns: 80, Rows: 24,
	})
	if err != nil {
		t.Fatal(err)
	}
	resized, err := manager.Resize(value.ID, 101, 37)
	if err != nil || resized.Columns != 101 || resized.Rows != 37 {
		t.Fatalf("resized execution = %#v, %v", resized, err)
	}
	if _, err := manager.Write(value.ID, []byte("stty size; printf 'pty-marker'; exit\n"), false); err != nil {
		t.Fatal(err)
	}
	events, final := waitExecution(t, manager, value.ID)
	var output strings.Builder
	for _, event := range events {
		if event.Stream == StreamPTY {
			output.Write(event.Data)
		}
	}
	if final.Status != StatusExited || final.ExitCode == nil || *final.ExitCode != 0 || !strings.Contains(output.String(), "37 101") || !strings.Contains(output.String(), "pty-marker") {
		t.Fatalf("PTY output=%q final=%#v", output.String(), final)
	}
}

func TestExecutionOutputRetentionReportsReplayReset(t *testing.T) {
	manager := New()
	t.Cleanup(func() { manager.Shutdown(context.Background()) })
	value, err := manager.Start(StartInput{
		Argv: []string{"/bin/sh", "-c", "yes x | head -c 100000"}, WorkingDirectory: t.TempDir(),
		StdinEOF: true, MaxOutputBytes: 32 << 10,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, final := waitExecution(t, manager, value.ID)
	if !final.OutputTruncated || final.TruncatedBeforeSequence == 0 || final.StdoutBytes != 100000 {
		t.Fatalf("truncated execution = %#v", final)
	}
	replayed, _, err := manager.Events(value.ID, 1)
	if err != nil || len(replayed) == 0 || !replayed[0].Reset || !replayed[0].Execution.OutputTruncated {
		t.Fatalf("replayed events = %#v, %v", replayed, err)
	}
	retained := 0
	for _, event := range replayed {
		retained += len(event.Data)
	}
	if retained > 32<<10 {
		t.Fatalf("retained output = %d bytes", retained)
	}
}

func waitExecution(t *testing.T, manager *Manager, id string) ([]Event, Execution) {
	t.Helper()
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	after := uint64(0)
	var all []Event
	for {
		events, changed, err := manager.Events(id, after)
		if err != nil {
			t.Fatal(err)
		}
		for _, event := range events {
			all = append(all, event)
			if event.Sequence > after {
				after = event.Sequence
			}
			if event.EOF {
				return all, event.Execution
			}
		}
		select {
		case <-changed:
		case <-deadline.C:
			t.Fatalf("execution %s did not finish", id)
		}
	}
}
