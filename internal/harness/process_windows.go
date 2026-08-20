//go:build windows

package harness

import (
	"os"
	"os/exec"
)

func prepareHarnessCommand(command *exec.Cmd) {}

func interruptHarnessProcess(pid int) error {
	process, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return process.Kill()
}

func killHarnessProcess(pid int) error {
	return interruptHarnessProcess(pid)
}

func suspendHarnessProcess(pid int) error {
	return interruptHarnessProcess(pid)
}

// Windows cancellation of a live in-process worker is handled by Cmd.Cancel.
// An orphaned worker record is not trusted without a platform process-token
// check, so startup recovery closes the durable turn without signaling a PID
// that may have been reused.
func workerProcessMatches(_ int, _ string) bool { return false }
