//go:build unix

package agentexec

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// PrepareCommand runs command in its own process group, so Terminate also
// stops the helpers a provider tool starts. A command made with
// exec.CommandContext also signals the whole group when its context ends.
func PrepareCommand(command *exec.Cmd, withContext bool) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if withContext {
		command.Cancel = func() error { return signalGroup(command, syscall.SIGKILL) }
	}
}

// Terminate asks command's process group to stop and kills it after grace.
// exited is closed when the caller's Wait returns.
func Terminate(command *exec.Cmd, exited <-chan struct{}, grace time.Duration) {
	if command.Process == nil {
		return
	}
	select {
	case <-exited:
		return
	default:
	}
	_ = signalGroup(command, syscall.SIGTERM)
	timer := time.NewTimer(grace)
	defer timer.Stop()
	select {
	case <-exited:
	case <-timer.C:
		_ = signalGroup(command, syscall.SIGKILL)
	}
}

func signalGroup(command *exec.Cmd, signal syscall.Signal) error {
	if command.Process == nil {
		return os.ErrProcessDone
	}
	pid := command.Process.Pid
	if pid <= 0 {
		return errors.New("invalid process ID")
	}
	if err := syscall.Kill(-pid, signal); err != nil {
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	return nil
}
