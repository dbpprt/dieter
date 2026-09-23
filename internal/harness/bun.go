package harness

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"golang.org/x/sys/cpu"
)

const managedBunVersion = "1.3.14"

func ompHarnessEnvironment(runtimePaths ...string) []string {
	environment := harnessEnvironment(runtimePaths...)
	if runtime.GOARCH != "amd64" {
		return environment
	}
	variant := "baseline"
	if cpu.X86.HasAVX2 {
		variant = "modern"
	}
	for index, item := range environment {
		if strings.HasPrefix(item, "PI_NATIVE_VARIANT=") {
			environment[index] = "PI_NATIVE_VARIANT=" + variant
			return environment
		}
	}
	return append(environment, "PI_NATIVE_VARIANT="+variant)
}

// ensureManagedBun installs the exact Bun runtime required by OMP once per
// Dieter home. It stays outside content-addressed harness runtimes so releases
// can share the comparatively large native executable.
func ensureManagedBun(ctx context.Context, dieterHome string) (string, error) {
	root := filepath.Join(dieterHome, "runtime", "tools", "bun")
	finalDir := filepath.Join(root, managedBunVersion)
	if binDir, err := validateManagedBun(ctx, finalDir); err == nil {
		return binDir, nil
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return "", err
	}
	if err := os.Chmod(root, 0o700); err != nil {
		return "", err
	}
	lock, err := acquireRuntimeInstallLock(ctx, filepath.Join(root, ".install-"+managedBunVersion+".lock"))
	if err != nil {
		return "", fmt.Errorf("lock managed Bun %s installation: %w", managedBunVersion, err)
	}
	defer lock.Close()
	if binDir, err := validateManagedBun(ctx, finalDir); err == nil {
		return binDir, nil
	}

	var quarantined string
	if _, err := os.Lstat(finalDir); err == nil {
		quarantined = filepath.Join(root, fmt.Sprintf(".corrupt-%s-%d-%d", managedBunVersion, os.Getpid(), time.Now().UnixNano()))
		if err := os.Rename(finalDir, quarantined); err != nil {
			return "", fmt.Errorf("quarantine corrupt managed Bun installation: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if quarantined != "" {
		defer os.RemoveAll(quarantined)
	}

	stageDir, err := os.MkdirTemp(root, ".stage-"+managedBunVersion+"-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(stageDir)
	if err := os.Chmod(stageDir, 0o700); err != nil {
		return "", err
	}
	packageJSON := []byte("{\n  \"private\": true,\n  \"dependencies\": {\n    \"bun\": \"" + managedBunVersion + "\"\n  }\n}\n")
	if err := os.WriteFile(filepath.Join(stageDir, "package.json"), packageJSON, 0o600); err != nil {
		return "", err
	}
	install := exec.CommandContext(ctx, "npm", "install", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund", "--package-lock=false")
	install.Dir = stageDir
	if output, installErr := install.CombinedOutput(); installErr != nil {
		return "", fmt.Errorf("install managed Bun %s package: %s: %w", managedBunVersion, strings.TrimSpace(string(output)), installErr)
	}
	postinstall := exec.CommandContext(ctx, "node", filepath.Join("node_modules", "bun", "install.js"))
	postinstall.Dir = stageDir
	if output, installErr := postinstall.CombinedOutput(); installErr != nil {
		return "", fmt.Errorf("prepare managed Bun %s executable: %s: %w", managedBunVersion, strings.TrimSpace(string(output)), installErr)
	}
	binDir, err := validateManagedBun(ctx, stageDir)
	if err != nil {
		return "", fmt.Errorf("validate managed Bun %s installation: %w", managedBunVersion, err)
	}
	if err := syncRuntimeDirectory(stageDir); err != nil {
		return "", err
	}
	if err := os.Rename(stageDir, finalDir); err != nil {
		return "", fmt.Errorf("publish managed Bun %s installation: %w", managedBunVersion, err)
	}
	if err := syncRuntimeDirectory(root); err != nil {
		return "", err
	}
	relativeBin, err := filepath.Rel(stageDir, binDir)
	if err != nil {
		return "", err
	}
	return filepath.Join(finalDir, relativeBin), nil
}

func validateManagedBun(ctx context.Context, dir string) (string, error) {
	executable := filepath.Join(dir, "node_modules", ".bin", "bun")
	resolved, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return "", err
	}
	relative, err := filepath.Rel(dir, resolved)
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(os.PathSeparator)) || filepath.IsAbs(relative) {
		return "", errors.New("managed Bun executable escapes its installation")
	}
	info, err := os.Stat(resolved)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() || info.Mode()&0o111 == 0 {
		return "", errors.New("managed Bun executable is not an executable regular file")
	}
	probeCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	output, err := exec.CommandContext(probeCtx, executable, "--version").Output()
	if err != nil {
		return "", err
	}
	if version := strings.TrimSpace(string(output)); version != managedBunVersion {
		return "", fmt.Errorf("managed Bun version is %q, want %q", version, managedBunVersion)
	}
	return filepath.Dir(executable), nil
}
