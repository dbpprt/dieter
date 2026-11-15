//go:build unix

package agentexec

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writePackage(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "package.json"), []byte(`{"version":"1.0.0"}`), 0o644); err != nil {
		t.Fatal(err)
	}
}

func writeExecutable(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestPackageNamesMirrorRuntimePackages(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		host           Host
		claude, codex  string
		triple         string
		tripleRejected bool
	}{
		{Host{Platform: "darwin", Arch: "arm64"}, "@anthropic-ai/claude-agent-sdk-darwin-arm64", "@openai/codex-darwin-arm64", "aarch64-apple-darwin", false},
		{Host{Platform: "darwin", Arch: "x64"}, "@anthropic-ai/claude-agent-sdk-darwin-x64", "@openai/codex-darwin-x64", "x86_64-apple-darwin", false},
		{Host{Platform: "linux", Arch: "x64"}, "@anthropic-ai/claude-agent-sdk-linux-x64", "@openai/codex-linux-x64", "x86_64-unknown-linux-musl", false},
		{Host{Platform: "linux", Arch: "arm64", Musl: true}, "@anthropic-ai/claude-agent-sdk-linux-arm64-musl", "@openai/codex-linux-arm64", "aarch64-unknown-linux-musl", false},
		{Host{Platform: "freebsd", Arch: "x64"}, "@anthropic-ai/claude-agent-sdk-freebsd-x64", "@openai/codex-freebsd-x64", "", true},
	} {
		if got := ClaudePackage(tc.host); got != tc.claude {
			t.Errorf("%+v claude = %s", tc.host, got)
		}
		if got := CodexPackage(tc.host); got != tc.codex {
			t.Errorf("%+v codex = %s", tc.host, got)
		}
		triple, err := CodexTriple(tc.host)
		if (err != nil) != tc.tripleRejected || triple != tc.triple {
			t.Errorf("%+v triple = %s, %v", tc.host, triple, err)
		}
	}
}

func TestResolvesExecutablesInARuntimeLayout(t *testing.T) {
	t.Parallel()
	host := Host{Platform: "linux", Arch: "arm64", Musl: true}
	runtimeDir := t.TempDir()
	modules := filepath.Join(runtimeDir, "node_modules")
	writePackage(t, filepath.Join(modules, "@anthropic-ai", "claude-agent-sdk"))
	// npm may nest the platform package under the agent package.
	nested := filepath.Join(modules, "@anthropic-ai", "claude-agent-sdk", "node_modules", "@anthropic-ai", "claude-agent-sdk-linux-arm64-musl")
	writePackage(t, nested)
	writeExecutable(t, filepath.Join(nested, "claude"))
	writePackage(t, filepath.Join(modules, "@openai", "codex"))
	codexPackage := filepath.Join(modules, "@openai", "codex-linux-arm64")
	writePackage(t, codexPackage)
	writeExecutable(t, filepath.Join(codexPackage, "vendor", "aarch64-unknown-linux-musl", "bin", "codex"))

	claude, err := ClaudeFor(runtimeDir, host)
	if err != nil || !strings.HasSuffix(claude, "claude-agent-sdk-linux-arm64-musl/claude") {
		t.Fatalf("claude = %q, %v", claude, err)
	}
	codex, err := CodexFor(runtimeDir, host)
	if err != nil || !strings.HasSuffix(codex, "vendor/aarch64-unknown-linux-musl/bin/codex") {
		t.Fatalf("codex = %q, %v", codex, err)
	}
	// The glibc package is a different one and is missing here.
	if _, err := ClaudeFor(runtimeDir, Host{Platform: "linux", Arch: "arm64"}); err == nil || !strings.Contains(err.Error(), "claude-agent-sdk-linux-arm64") {
		t.Fatalf("missing glibc package = %v", err)
	}
}

func TestCodexFallsBackToTheMainPackageVendorDirectory(t *testing.T) {
	t.Parallel()
	host := Host{Platform: "darwin", Arch: "arm64"}
	runtimeDir := t.TempDir()
	main := filepath.Join(runtimeDir, "node_modules", "@openai", "codex")
	writePackage(t, main)
	writeExecutable(t, filepath.Join(main, "vendor", "aarch64-apple-darwin", "bin", "codex"))
	if codex, err := CodexFor(runtimeDir, host); err != nil || !strings.HasPrefix(codex, mustEval(t, main)) {
		t.Fatalf("codex = %q, %v", codex, err)
	}
}

func TestRejectsNonExecutablesAndMissingRuntimes(t *testing.T) {
	t.Parallel()
	host := Host{Platform: "darwin", Arch: "arm64"}
	runtimeDir := t.TempDir()
	modules := filepath.Join(runtimeDir, "node_modules")
	writePackage(t, filepath.Join(modules, "@anthropic-ai", "claude-agent-sdk"))
	native := filepath.Join(modules, "@anthropic-ai", "claude-agent-sdk-darwin-arm64")
	writePackage(t, native)
	if err := os.WriteFile(filepath.Join(native, "claude"), []byte("data"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := ClaudeFor(runtimeDir, host); err == nil || !strings.Contains(err.Error(), "not executable") {
		t.Fatalf("non-executable = %v", err)
	}
	if _, err := ClaudeFor(filepath.Join(runtimeDir, "missing"), host); err == nil {
		t.Fatal("missing runtime resolved")
	}
}

func TestNodeSearchesTheGivenPath(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	writeExecutable(t, filepath.Join(dir, "node"))
	if got, err := Node("relative:" + dir); err != nil || got != filepath.Join(dir, "node") {
		t.Fatalf("node = %q, %v", got, err)
	}
}

func TestTerminateStopsTheProcessGroup(t *testing.T) {
	t.Parallel()
	command := exec.Command("/bin/sh", "-c", "trap '' TERM; sleep 30 & wait")
	PrepareCommand(command, false)
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan struct{})
	go func() {
		_ = command.Wait()
		close(exited)
	}()
	started := time.Now()
	Terminate(command, exited, 200*time.Millisecond)
	select {
	case <-exited:
	case <-time.After(5 * time.Second):
		t.Fatal("process group survived Terminate")
	}
	if time.Since(started) > 4*time.Second {
		t.Fatal("Terminate did not escalate")
	}
}

func mustEval(t *testing.T, path string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	return resolved
}
