//go:build linux

package machine

import (
	"context"
	"errors"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

func operationCapabilities(ctx context.Context, root string) []OperationCapability {
	path, err := exec.LookPath("busctl")
	if err != nil {
		reason := "systemd-logind busctl client is unavailable"
		return []OperationCapability{
			{Operation: OperationRestart, UnavailableReason: reason},
			{Operation: OperationShutdown, UnavailableReason: reason},
			linuxUpdateCapability(root),
		}
	}
	return []OperationCapability{
		logindCapability(ctx, path, OperationRestart, "CanReboot"),
		logindCapability(ctx, path, OperationShutdown, "CanPowerOff"),
		linuxUpdateCapability(root),
	}
}

func logindCapability(ctx context.Context, path string, operation Operation, method string) OperationCapability {
	output, err := exec.CommandContext(ctx, path, "--system", "call", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", method).Output()
	if err != nil {
		return OperationCapability{Operation: operation, UnavailableReason: "could not query systemd-logind authorization"}
	}
	value, err := parseBusctlString(output)
	if err != nil {
		return OperationCapability{Operation: operation, UnavailableReason: "systemd-logind returned an invalid authorization response"}
	}
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

func parseBusctlString(output []byte) (string, error) {
	fields := strings.Fields(strings.TrimSpace(string(output)))
	if len(fields) != 2 || fields[0] != "s" {
		return "", fmt.Errorf("expected busctl string, got %q", strings.TrimSpace(string(output)))
	}
	value, err := strconv.Unquote(fields[1])
	if err != nil {
		return "", fmt.Errorf("decode busctl string: %w", err)
	}
	return value, nil
}

func executeOperation(ctx context.Context, root string, operation Operation) error {
	if operation == OperationUpdate {
		capability := linuxUpdateCapability(root)
		if !capability.Supported || !capability.Authorized {
			if capability.UnavailableReason != "" {
				return errors.New(capability.UnavailableReason)
			}
			return ErrOperationUnsupported
		}
		return startLinuxUpdateWorker(root)
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
