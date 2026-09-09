//go:build darwin

package machine

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func operationCapabilities(ctx context.Context, root string) []OperationCapability {
	return []OperationCapability{
		{Operation: OperationRestart, Supported: true, Authorized: true},
		{Operation: OperationShutdown, Supported: true, Authorized: true},
		homebrewUpdateCapability(ctx, root),
	}
}

func executeOperation(ctx context.Context, root string, operation Operation) error {
	if operation == OperationUpdate {
		capability := homebrewUpdateCapability(ctx, root)
		if !capability.Supported || !capability.Authorized {
			if capability.UnavailableReason != "" {
				return errors.New(capability.UnavailableReason)
			}
			return ErrOperationUnsupported
		}
		brew, _ := homebrewExecutable()
		return startHomebrewUpdateWorker(root, brew)
	}
	verb := "restart"
	if operation == OperationShutdown {
		verb = "shut down"
	}
	// System Events uses the signed-in user's normal macOS authorization path;
	// Dieter never accepts or stores an administrator password.
	return exec.CommandContext(ctx, "/usr/bin/osascript", "-e", `tell application "System Events" to `+verb).Run()
}

func homebrewUpdateCapability(ctx context.Context, root string) OperationCapability {
	result := OperationCapability{Operation: OperationUpdate, UnavailableReason: "automatic daemon updates require a Homebrew-managed Dieter service"}
	raw, err := os.ReadFile(filepath.Join(root, "runtime", "daemon.json"))
	if err != nil {
		return result
	}
	var runtimeStatus struct {
		ServiceManaged bool `json:"serviceManaged"`
	}
	if json.Unmarshal(raw, &runtimeStatus) != nil || !runtimeStatus.ServiceManaged {
		return result
	}
	brew, err := homebrewExecutable()
	if err != nil {
		result.UnavailableReason = "Homebrew executable is unavailable"
		return result
	}
	prefixCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	rawPrefix, err := exec.CommandContext(prefixCtx, brew, "--prefix", "dbpprt/tap/dieter").Output()
	if err != nil {
		result.UnavailableReason = "the dbpprt/tap/dieter Homebrew formula is not installed"
		return result
	}
	prefix, err := filepath.EvalSymlinks(strings.TrimSpace(string(rawPrefix)))
	if err != nil {
		return result
	}
	executable, err := os.Executable()
	if err != nil {
		return result
	}
	executable, err = filepath.EvalSymlinks(executable)
	if err != nil {
		return result
	}
	relative, err := filepath.Rel(prefix, executable)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		result.UnavailableReason = "the running daemon is not the Homebrew-installed Dieter binary"
		return result
	}
	result.Supported, result.Authorized, result.UnavailableReason = true, true, ""
	return result
}

func homebrewExecutable() (string, error) {
	for _, candidate := range []string{"/opt/homebrew/bin/brew", "/usr/local/bin/brew"} {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	path, err := exec.LookPath("brew")
	if err != nil {
		return "", err
	}
	return filepath.Abs(path)
}

func startHomebrewUpdateWorker(root, brew string) error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	logDirectory := filepath.Join(root, "logs")
	if err := os.MkdirAll(logDirectory, 0o755); err != nil {
		return err
	}
	logPath := filepath.Join(logDirectory, "update.log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer logFile.Close()
	command := exec.Command(executable, "__daemon-update-worker", "--brew", brew)
	command.Stdin = nil
	command.Stdout = logFile
	command.Stderr = logFile
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	command.Env = homebrewUpdateEnvironment(false)
	if err := command.Start(); err != nil {
		return fmt.Errorf("start detached Homebrew updater: %w", err)
	}
	return command.Process.Release()
}
