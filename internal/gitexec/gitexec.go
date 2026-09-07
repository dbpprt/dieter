package gitexec

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

const maxOutputBytes = 8 << 20

var credentialURL = regexp.MustCompile(`(?i)(https?://)[^/@\s]+@`)

type Result struct {
	Output   []byte
	ExitCode int
	Duration time.Duration
}

type Runner interface {
	Run(context.Context, string, ...string) (Result, error)
}

type CommandError struct {
	Args     []string
	Output   string
	ExitCode int
}

func (e *CommandError) Error() string {
	message := strings.TrimSpace(e.Output)
	if message == "" {
		message = fmt.Sprintf("git exited with status %d", e.ExitCode)
	}
	return message
}

type ExecRunner struct{}

func (ExecRunner) Run(ctx context.Context, directory string, args ...string) (Result, error) {
	started := time.Now()
	// `git diff` can refresh the index even with GIT_OPTIONAL_LOCKS=0.
	// Presentation reads must leave index writes to explicit Git operations.
	commandArgs := append([]string{"-c", "diff.autoRefreshIndex=false"}, args...)
	command := exec.CommandContext(ctx, "git", commandArgs...)
	command.Dir = directory
	command.Env = gitEnvironment()
	var output limitedBuffer
	command.Stdout, command.Stderr = &output, &output
	err := command.Run()
	result := Result{Output: append([]byte(nil), output.Bytes()...), Duration: time.Since(started)}
	if err == nil {
		return result, nil
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) || errors.Is(ctx.Err(), context.Canceled) {
		return result, ctx.Err()
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		result.ExitCode = exit.ExitCode()
		return result, &CommandError{Args: append([]string(nil), args...), Output: Redact(string(result.Output)), ExitCode: result.ExitCode}
	}
	return result, err
}

func gitEnvironment() []string {
	values := os.Environ()
	result := values[:0]
	for _, value := range values {
		if strings.HasPrefix(value, "GIT_TERMINAL_PROMPT=") || strings.HasPrefix(value, "GIT_EDITOR=") ||
			strings.HasPrefix(value, "GIT_SEQUENCE_EDITOR=") || strings.HasPrefix(value, "LC_ALL=") ||
			strings.HasPrefix(value, "GIT_OPTIONAL_LOCKS=") {
			continue
		}
		result = append(result, value)
	}
	// Background status/diff reads must not refresh the index on disk and race
	// an explicit stage or commit. Required mutation locks still apply.
	return append(result, "GIT_TERMINAL_PROMPT=0", "GIT_EDITOR=true", "GIT_SEQUENCE_EDITOR=true", "LC_ALL=C", "GIT_OPTIONAL_LOCKS=0")
}

func Redact(value string) string {
	return credentialURL.ReplaceAllString(value, `${1}[redacted]@`)
}

type limitedBuffer struct {
	bytes.Buffer
	truncated bool
}

func (b *limitedBuffer) Write(value []byte) (int, error) {
	original := len(value)
	remaining := maxOutputBytes - b.Len()
	if remaining <= 0 {
		b.truncated = true
		return original, nil
	}
	if len(value) > remaining {
		value = value[:remaining]
		b.truncated = true
	}
	_, err := b.Buffer.Write(value)
	return original, err
}

func Output(result Result) string { return strings.TrimSpace(string(result.Output)) }
