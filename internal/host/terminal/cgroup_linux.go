//go:build linux

package terminal

import (
	"os/exec"
)

// A tmux server is intentionally durable across daemon restarts. When Dieter
// itself is a systemd user service, starting tmux in a transient scope moves
// the server out of dieter.service's cgroup so KillMode cannot reap it.
func persistentServerCommand(systemdScope bool, executable string, args ...string) *exec.Cmd {
	if systemdScope {
		if systemdRun, err := exec.LookPath("systemd-run"); err == nil {
			wrapped := []string{"--user", "--scope", "--quiet", "--collect", "--", executable}
			return exec.Command(systemdRun, append(wrapped, args...)...)
		}
	}
	return exec.Command(executable, args...)
}
