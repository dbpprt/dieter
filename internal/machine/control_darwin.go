//go:build darwin

package machine

import (
	"context"
	"os/exec"
)

func supportsOperations() bool { return true }

func executeOperation(ctx context.Context, operation Operation) error {
	verb := "restart"
	if operation == OperationShutdown {
		verb = "shut down"
	}
	// System Events uses the signed-in user's normal macOS authorization path;
	// Dieter never accepts or stores an administrator password.
	return exec.CommandContext(ctx, "/usr/bin/osascript", "-e", `tell application "System Events" to `+verb).Run()
}
