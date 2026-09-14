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

	"github.com/dbpprt/dieter/internal/serviceruntime"
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
	executable, err := os.Executable()
	if err != nil {
		return result
	}
	return homebrewInstallationCapability(ctx, brew, executable)
}

func homebrewInstallationCapability(ctx context.Context, brew, executable string) OperationCapability {
	result := OperationCapability{Operation: OperationUpdate}
	// A qualified formula lookup loads Homebrew's Ruby runtime on every probe.
	// Query only the global prefix (Homebrew's fast shell path), then verify the
	// installed keg and its tap from the receipt, without evaluating a formula.
	prefixCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	command := exec.CommandContext(prefixCtx, brew, "--prefix")
	command.Env = homebrewUpdateEnvironment(true)
	command.WaitDelay = 100 * time.Millisecond
	rawPrefix, err := command.Output()
	if err != nil {
		result.retryable = true
		switch {
		case errors.Is(prefixCtx.Err(), context.DeadlineExceeded):
			result.UnavailableReason = "Homebrew installation check timed out; try again"
		case errors.Is(prefixCtx.Err(), context.Canceled):
			result.UnavailableReason = "Homebrew installation check was canceled; try again"
		default:
			result.UnavailableReason = "Homebrew installation could not be checked; try again"
		}
		return result
	}
	prefix := strings.TrimSpace(string(rawPrefix))
	if !filepath.IsAbs(prefix) || strings.ContainsAny(prefix, "\r\n\x00") {
		result.UnavailableReason = "Homebrew returned an invalid installation path"
		result.retryable = true
		return result
	}
	prefix, err = filepath.EvalSymlinks(prefix)
	if err != nil {
		result.UnavailableReason = "Homebrew installation path is unavailable"
		result.retryable = true
		return result
	}
	keg, err := filepath.EvalSymlinks(filepath.Join(prefix, "opt", "dieter"))
	if err != nil {
		result.UnavailableReason = "the dbpprt/tap/dieter Homebrew formula is not installed"
		if !errors.Is(err, os.ErrNotExist) {
			result.UnavailableReason = "the installed Dieter formula could not be checked; try again"
			result.retryable = true
		}
		return result
	}
	var receipt struct {
		Source struct {
			Tap string `json:"tap"`
		} `json:"source"`
	}
	rawReceipt, err := os.ReadFile(filepath.Join(keg, "INSTALL_RECEIPT.json"))
	if err != nil || json.Unmarshal(rawReceipt, &receipt) != nil {
		result.UnavailableReason = "the installed Dieter Homebrew receipt could not be verified"
		result.retryable = true
		return result
	}
	if receipt.Source.Tap != "dbpprt/tap" {
		result.UnavailableReason = "the installed Dieter formula is not from dbpprt/tap"
		return result
	}
	installedExecutable, err := filepath.EvalSymlinks(filepath.Join(keg, "bin", "dieter"))
	if err != nil {
		result.UnavailableReason = "the installed Dieter Homebrew binary is unavailable"
		return result
	}
	installedInfo, err := os.Stat(installedExecutable)
	if err != nil || !installedInfo.Mode().IsRegular() || installedInfo.Mode().Perm()&0o111 == 0 {
		result.UnavailableReason = "the installed Dieter Homebrew binary is unavailable"
		return result
	}
	executable, err = filepath.EvalSymlinks(executable)
	if err != nil {
		result.UnavailableReason = "the running Dieter executable could not be resolved"
		return result
	}
	if executable != installedExecutable && executable != filepath.Join(serviceruntime.HomebrewRoot(prefix), "bin", "dieter") {
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
