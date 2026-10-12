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

	"github.com/dbpprt/dieter/internal/platform/fsx"
	"golang.org/x/sys/cpu"
)

const managedBunVersion = "1.3.14"

func (e Environment) ompHarnessEnvironment(runtimePaths ...string) []string {
	environment := e.harnessEnvironment(runtimePaths...)
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
// can share the comparatively large native executable. Release builds take its
// package from their prebuilt runtime archive; source builds use npm.
func ensureManagedBun(ctx context.Context, dieterHome string, archive RuntimeArchive) (string, error) {
	return installManagedBun(ctx, dieterHome, func(ctx context.Context, stage string) error {
		if !archive.pinned() {
			return npmInstallManagedBun(ctx, stage)
		}
		path, err := downloadRuntimeArchive(ctx, archive, filepath.Dir(stage))
		if err != nil {
			return err
		}
		defer os.Remove(path)
		return extractRuntimeArchive(path, archiveBunTree, stage)
	})
}

// installManagedBun publishes the managed Bun under its install lock unless a
// valid installation exists: populate stages the npm package (Bun's
// postinstall not yet run), then Bun's own postinstall selects this host's
// executable, which is validated before the stage is renamed into place.
func installManagedBun(ctx context.Context, dieterHome string, populate func(context.Context, string) error) (string, error) {
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
	lock, err := fsx.LockContext(ctx, filepath.Join(root, ".install-"+managedBunVersion+".lock"), 50*time.Millisecond)
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
	if err := populate(ctx, stageDir); err != nil {
		return "", err
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
	if err := fsx.SyncDir(stageDir); err != nil {
		return "", err
	}
	if err := os.Rename(stageDir, finalDir); err != nil {
		return "", fmt.Errorf("publish managed Bun %s installation: %w", managedBunVersion, err)
	}
	if err := fsx.SyncDir(root); err != nil {
		return "", err
	}
	relativeBin, err := filepath.Rel(stageDir, binDir)
	if err != nil {
		return "", err
	}
	return filepath.Join(finalDir, relativeBin), nil
}

// npmInstallManagedBun installs the managed Bun package without running its
// postinstall, as both source-built daemons and release builders do.
func npmInstallManagedBun(ctx context.Context, dir string) error {
	packageJSON := []byte("{\n  \"private\": true,\n  \"dependencies\": {\n    \"bun\": \"" + managedBunVersion + "\"\n  }\n}\n")
	if err := os.WriteFile(filepath.Join(dir, "package.json"), packageJSON, 0o600); err != nil {
		return err
	}
	install := exec.CommandContext(ctx, "npm", "install", "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund", "--package-lock=false")
	install.Dir = dir
	if output, err := install.CombinedOutput(); err != nil {
		return fmt.Errorf("install managed Bun %s package: %s: %w", managedBunVersion, strings.TrimSpace(string(output)), err)
	}
	return nil
}

func validateManagedBun(ctx context.Context, dir string) (string, error) {
	executable := filepath.Join(dir, "node_modules", ".bin", "bun")
	resolved, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return "", err
	}
	// Resolve both sides: macOS temporary roots commonly traverse /var -> /private/var.
	installation, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return "", err
	}
	relative, err := filepath.Rel(installation, resolved)
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
