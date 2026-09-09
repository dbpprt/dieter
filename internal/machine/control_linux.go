//go:build linux

package machine

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

func operationCapabilities(ctx context.Context, _ string) []OperationCapability {
	path, err := exec.LookPath("busctl")
	if err != nil {
		reason := "systemd-logind busctl client is unavailable"
		return []OperationCapability{
			{Operation: OperationRestart, UnavailableReason: reason},
			{Operation: OperationShutdown, UnavailableReason: reason},
			{Operation: OperationUpdate, UnavailableReason: "automatic daemon updates currently require a Homebrew-managed macOS installation"},
		}
	}
	return []OperationCapability{
		logindCapability(ctx, path, OperationRestart, "CanReboot"),
		logindCapability(ctx, path, OperationShutdown, "CanPowerOff"),
		{Operation: OperationUpdate, UnavailableReason: "automatic daemon updates currently require a Homebrew-managed macOS installation"},
	}
}

func logindCapability(ctx context.Context, path string, operation Operation, method string) OperationCapability {
	output, err := exec.CommandContext(ctx, path, "--system", "call", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", method).Output()
	if err != nil {
		return OperationCapability{Operation: operation, UnavailableReason: "could not query systemd-logind authorization"}
	}
	value := strings.Trim(strings.TrimSpace(string(output)), `s "`)
	switch value {
	case "yes":
		return OperationCapability{Operation: operation, Supported: true, Authorized: true}
	case "challenge":
		return OperationCapability{Operation: operation, Supported: true, UnavailableReason: "interactive PolicyKit authorization is required"}
	case "no":
		return OperationCapability{Operation: operation, Supported: true, UnavailableReason: "systemd-logind denied this daemon user"}
	default:
		return OperationCapability{Operation: operation, UnavailableReason: "systemd-logind does not support this operation"}
	}
}

func executeOperation(ctx context.Context, _ string, operation Operation) error {
	if operation == OperationUpdate {
		return ErrOperationUnsupported
	}
	path, err := exec.LookPath("busctl")
	if err != nil {
		return ErrOperationUnsupported
	}
	method := "Reboot"
	if operation == OperationShutdown {
		method = "PowerOff"
	}
	output, err := exec.CommandContext(ctx, path, "--system", "call", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", method, "b", "false").CombinedOutput()
	if err != nil {
		return fmt.Errorf("systemd-logind %s: %s: %w", strings.ToLower(method), strings.TrimSpace(string(output)), err)
	}
	return nil
}
