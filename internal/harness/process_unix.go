//go:build unix

package harness

import (
	"errors"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

func prepareHarnessCommand(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Cancel = func() error {
		if command.Process == nil {
			return os.ErrProcessDone
		}
		return interruptHarnessProcess(command.Process.Pid)
	}
}

func interruptHarnessProcess(pid int) error {
	if pid <= 0 {
		return errors.New("invalid harness worker PID")
	}
	if err := syscall.Kill(-pid, syscall.SIGINT); err != nil {
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	return nil
}

func suspendHarnessProcess(pid int) error {
	if pid <= 0 {
		return errors.New("invalid harness worker PID")
	}
	// Signal only Board's protocol worker. Its provider bridge is in the same
	// process group and must remain alive for the next binary to reattach.
	if err := syscall.Kill(pid, syscall.SIGUSR1); err != nil {
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	return nil
}

func killHarnessProcess(pid int) error {
	if pid <= 0 {
		return errors.New("invalid harness worker PID")
	}
	if err := syscall.Kill(-pid, syscall.SIGKILL); err != nil {
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
	return nil
}

func workerProcessMatches(pid int, token string) bool {
	if pid <= 0 || token == "" {
		return false
	}
	output, err := exec.Command("ps", "-ww", "-p", strconv.Itoa(pid), "-o", "command=").Output()
	return err == nil && strings.Contains(string(output), "--board-worker-token="+token)
}
