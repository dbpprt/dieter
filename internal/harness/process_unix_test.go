//go:build unix

package harness

import (
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestCleanupTerminatesVerifiedDetachedProviderBridge(t *testing.T) {
	runtimeRoot := t.TempDir()
	sessionID := "card-provider-cleanup"
	stateDir := filepath.Join(runtimeRoot, ".agent-runs", sessionID, "bridge")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(t.TempDir(), "bridge.mjs")
	if err := os.WriteFile(script, []byte("process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	command := exec.Command("node", script, "--bridge-state-dir", stateDir)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		_, _ = command.Process.Wait()
	})
	waitForProviderBridge(t, command.Process.Pid, stateDir)
	writeProviderBridgeRecord(t, stateDir, command.Process.Pid)

	runner := NewSubprocessRunner(t.TempDir())
	if err := runner.Cleanup(sessionID, runtimeRoot); err != nil {
		t.Fatal(err)
	}
	if providerBridgeProcessMatches(command.Process.Pid, stateDir) {
		t.Fatal("verified provider bridge survived cleanup")
	}
	if _, err := os.Stat(filepath.Join(stateDir, "bridge-meta.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("bridge metadata still exists: %v", err)
	}
}

func TestCleanupTerminatesACPBridgeInSandboxHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	runtimeRoot := t.TempDir()
	sessionID := "card-acp-provider-cleanup"
	stateDirs, err := ProviderBridgeStateDirs(sessionID, runtimeRoot)
	if err != nil {
		t.Fatal(err)
	}
	stateDir := stateDirs[1]
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(t.TempDir(), "bridge.mjs")
	if err := os.WriteFile(script, []byte("process.on('SIGTERM', () => {}); setInterval(() => {}, 1000);\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	command := exec.Command("node", script, "--bridge-state-dir", stateDir)
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		_, _ = command.Process.Wait()
	})
	waitForProviderBridge(t, command.Process.Pid, stateDir)
	writeProviderBridgeRecord(t, stateDir, command.Process.Pid)

	runner := NewSubprocessRunner(t.TempDir())
	if err := runner.Cleanup(sessionID, runtimeRoot); err != nil {
		t.Fatal(err)
	}
	if providerBridgeProcessMatches(command.Process.Pid, stateDir) {
		t.Fatal("verified ACP provider bridge survived cleanup")
	}
	if _, err := os.Stat(filepath.Join(stateDir, "bridge-meta.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("ACP bridge metadata still exists: %v", err)
	}
}

func TestCleanupDoesNotSignalUnrelatedProcessFromStaleBridgeRecord(t *testing.T) {
	runtimeRoot := t.TempDir()
	sessionID := "card-stale-provider"
	stateDir := filepath.Join(runtimeRoot, ".agent-runs", sessionID, "bridge")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	command := exec.Command("sleep", "30")
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		_, _ = command.Process.Wait()
	})
	writeProviderBridgeRecord(t, stateDir, command.Process.Pid)

	runner := NewSubprocessRunner(t.TempDir())
	if err := runner.Cleanup(sessionID, runtimeRoot); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Kill(command.Process.Pid, 0); err != nil {
		t.Fatalf("cleanup signaled an unrelated process: %v", err)
	}
	if _, err := os.Stat(filepath.Join(stateDir, "bridge-meta.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale bridge metadata still exists: %v", err)
	}
}

func writeProviderBridgeRecord(t *testing.T, stateDir string, pid int) {
	t.Helper()
	raw, err := json.Marshal(providerBridgeRecord{PID: pid})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stateDir, "bridge-meta.json"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

func waitForProviderBridge(t *testing.T, pid int, stateDir string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if providerBridgeProcessMatches(pid, stateDir) {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("provider bridge did not become observable")
}
