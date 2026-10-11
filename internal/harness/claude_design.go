package harness

import (
	"context"
	"os/exec"
	"path/filepath"
	"time"
)

// ClaudeDesignCommand prepares one daemon-host Claude Design operation (status,
// sign-in, consent or revoke) from the installed runtime. The helper drives the
// same pinned Claude Code CLI as Claude Code turns, with the worker environment
// allowlist, and never receives a conversation, workspace or credential.
// Canceling ctx interrupts the helper's whole process group.
func (r *SubprocessRunner) ClaudeDesignCommand(ctx context.Context, operation, stateRoot string) (*exec.Cmd, error) {
	dir, err := r.ensure(ctx)
	if err != nil {
		return nil, err
	}
	command := exec.CommandContext(ctx, "node", filepath.Join(dir, "claude-design-host.mjs"), operation, stateRoot)
	prepareHarnessCommand(command)
	command.WaitDelay = 5 * time.Second
	command.Dir = dir
	command.Env = harnessEnvironment()
	return command, nil
}
