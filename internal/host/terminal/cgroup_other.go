//go:build !linux

package terminal

import "os/exec"

func persistentServerCommand(_ bool, executable string, args ...string) *exec.Cmd {
	return exec.Command(executable, args...)
}
