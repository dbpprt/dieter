//go:build linux

package terminal

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPersistentServerUsesSeparateSystemdScope(t *testing.T) {
	bin := t.TempDir()
	path := filepath.Join(bin, "systemd-run")
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	t.Setenv("DIETER_SERVICE_MANAGER", "systemd-user")
	command := persistentServerCommand("/usr/bin/tmux", "new-session", "-d")
	joined := strings.Join(command.Args, " ")
	if command.Path != path || !strings.Contains(joined, "--user --scope --quiet --collect -- /usr/bin/tmux new-session -d") {
		t.Fatalf("persistent command = %q %q", command.Path, command.Args)
	}
}
