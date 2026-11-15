// Package agentexec locates the agent executables Dieter's harness runtime
// ships (Claude Code, Codex) and Node.js, so daemon code can run the official
// provider tools directly: logins, status checks and usage probes. It mirrors
// the platform-package layout of runtime/runtime-packages.mjs, which npm
// installs only for the host it runs on.
package agentexec

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// Host is a Node.js platform: process.platform, process.arch and, on Linux,
// whether the C library is musl.
type Host struct {
	Platform, Arch string
	Musl           bool
}

// CurrentHost is the platform this daemon runs on.
func CurrentHost() Host {
	host := Host{Platform: runtime.GOOS, Arch: runtime.GOARCH}
	switch host.Platform {
	case "windows":
		host.Platform = "win32"
	}
	switch host.Arch {
	case "amd64":
		host.Arch = "x64"
	case "386":
		host.Arch = "ia32"
	}
	if host.Platform == "linux" {
		// Node reports glibc through process.report; musl systems ship the
		// musl dynamic loader instead.
		if matches, _ := filepath.Glob("/lib/ld-musl-*.so.1"); len(matches) > 0 {
			host.Musl = true
		}
	}
	return host
}

// ClaudePackage is the platform package holding the Claude Code executable.
func ClaudePackage(host Host) string {
	name := "@anthropic-ai/claude-agent-sdk-" + host.Platform + "-" + host.Arch
	if host.Musl {
		name += "-musl"
	}
	return name
}

// CodexPackage is the platform package holding the Codex executable. Codex's
// Linux executables are static musl builds serving both C libraries.
func CodexPackage(host Host) string { return "@openai/codex-" + host.Platform + "-" + host.Arch }

// CodexTriple is the Rust target directory inside the Codex platform package.
func CodexTriple(host Host) (string, error) {
	switch host.Platform + "/" + host.Arch {
	case "linux/x64":
		return "x86_64-unknown-linux-musl", nil
	case "linux/arm64":
		return "aarch64-unknown-linux-musl", nil
	case "darwin/x64":
		return "x86_64-apple-darwin", nil
	case "darwin/arm64":
		return "aarch64-apple-darwin", nil
	}
	return "", fmt.Errorf("Codex publishes no executable for %s-%s", host.Platform, host.Arch)
}

// Claude is the Claude Code executable of the runtime in runtimeDir.
func Claude(runtimeDir string) (string, error) { return ClaudeFor(runtimeDir, CurrentHost()) }

// ClaudeFor is Claude for another host's package layout.
func ClaudeFor(runtimeDir string, host Host) (string, error) {
	native, err := nativePackage(runtimeDir, "@anthropic-ai/claude-agent-sdk", ClaudePackage(host))
	if err != nil {
		return "", fmt.Errorf("Claude Code: %w", err)
	}
	return executable(filepath.Join(native, "claude"))
}

// Codex is the Codex executable of the runtime in runtimeDir.
func Codex(runtimeDir string) (string, error) { return CodexFor(runtimeDir, CurrentHost()) }

// CodexFor is Codex for another host's package layout.
func CodexFor(runtimeDir string, host Host) (string, error) {
	triple, err := CodexTriple(host)
	if err != nil {
		return "", err
	}
	name := "codex"
	if host.Platform == "win32" {
		name = "codex.exe"
	}
	native, err := nativePackage(runtimeDir, "@openai/codex", CodexPackage(host))
	if err != nil {
		// codex.js falls back to a vendor directory inside the main package.
		main, mainErr := findPackage(runtimeDir, runtimeDir, "@openai/codex")
		if mainErr != nil {
			return "", fmt.Errorf("Codex: %w", err)
		}
		if path, fallbackErr := executable(filepath.Join(main, "vendor", triple, "bin", name)); fallbackErr == nil {
			return path, nil
		}
		return "", fmt.Errorf("Codex: %w", err)
	}
	return executable(filepath.Join(native, "vendor", triple, "bin", name))
}

// Node is the node executable on path (a PATH list), or on this process's
// PATH when path is empty or has none. Harness workers run "node" the same way.
func Node(path string) (string, error) {
	for _, dir := range filepath.SplitList(path) {
		if dir == "" || !filepath.IsAbs(dir) {
			continue
		}
		if found, err := executable(filepath.Join(dir, "node")); err == nil {
			return found, nil
		}
	}
	found, err := exec.LookPath("node")
	if err != nil {
		return "", errors.New("Node.js is not on PATH; AI SDK harnesses require Node.js 22.19 or newer")
	}
	return found, nil
}

// nativePackage finds a platform package the way Node resolves it from the
// agent package: nested under the agent package first, then up to the runtime.
func nativePackage(runtimeDir, agentPackage, native string) (string, error) {
	agent, err := findPackage(runtimeDir, runtimeDir, agentPackage)
	if err != nil {
		return "", err
	}
	found, err := findPackage(runtimeDir, agent, native)
	if err != nil {
		return "", fmt.Errorf("this harness runtime does not include %s; reinstall the runtime on this platform", native)
	}
	return found, nil
}

// findPackage walks node_modules directories from `from` up to the runtime
// root and never leaves it, like runtime-packages.mjs findRuntimePackage.
func findPackage(runtimeDir, from, name string) (string, error) {
	top, err := filepath.EvalSymlinks(runtimeDir)
	if err != nil {
		return "", fmt.Errorf("harness runtime %s: %w", runtimeDir, err)
	}
	directory, err := filepath.EvalSymlinks(from)
	if err != nil {
		return "", err
	}
	if !inside(directory, top) {
		return "", fmt.Errorf("%s is outside the harness runtime %s", directory, top)
	}
	for {
		candidate := filepath.Join(append([]string{directory, "node_modules"}, strings.Split(name, "/")...)...)
		if _, err := os.Stat(filepath.Join(candidate, "package.json")); err == nil {
			return filepath.EvalSymlinks(candidate)
		}
		if directory == top {
			return "", fmt.Errorf("Dieter's harness runtime does not include %s", name)
		}
		directory = filepath.Dir(directory)
	}
}

func inside(path, root string) bool {
	relative, err := filepath.Rel(root, path)
	return err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) && !filepath.IsAbs(relative)
}

func executable(path string) (string, error) {
	info, err := os.Stat(path)
	if err != nil {
		return "", fmt.Errorf("%s is missing", path)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 {
		return "", fmt.Errorf("%s is not executable", path)
	}
	return path, nil
}
