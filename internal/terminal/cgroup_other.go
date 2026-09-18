//go:build !linux && !windows

package terminal

import "os/exec"

func persistentServerCommand(executable string, args ...string) *exec.Cmd {
	return exec.Command(executable, args...)
}
