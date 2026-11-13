package harness

import (
	"archive/tar"
	"bufio"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/platform/fsx"
)

// Strix (github.com/usestrix/strix) publishes one PyInstaller executable per
// platform as a GitHub release asset, without checksums. Dieter pins the
// SHA-256 of every archive it supports; bumping the version means downloading
// each archive and updating its digest here.
const managedStrixVersion = "1.7.1"

type strixAsset struct {
	Name   string
	SHA256 string
}

var strixAssets = map[string]strixAsset{
	"darwin/arm64": {Name: "strix-1.7.1-macos-arm64", SHA256: "147814905c41a7d5f511faa326472bddc31f21602486190a5bfb76e7b20aa692"},
	"linux/amd64":  {Name: "strix-1.7.1-linux-x86_64", SHA256: "c8e836251578baa228afe9e65f4a901ef6ae1116c444f8f0a67f7ae7898c480f"},
	"linux/arm64":  {Name: "strix-1.7.1-linux-arm64", SHA256: "e2206de811920a7e0f07933afd931c71204212e0a5f736f0164911365baa6fd2"},
}

// Variables so tests can serve their own archives.
var (
	strixReleaseBaseURL      = "https://github.com/usestrix/strix/releases/download/v" + managedStrixVersion
	strixReleaseClient       *http.Client
	maxStrixArchiveBytes     = int64(256 << 20)
	maxStrixExecutableBytes  = int64(512 << 20)
	strixVersionProbeTimeout = 60 * time.Second
)

const strixDownloadTimeout = 15 * time.Minute

// strixHarnessEnvironment adds the Docker client settings Strix needs to
// reach its sandbox, and the pinned executable the runtime launches.
func (e Environment) strixHarnessEnvironment(executable string) []string {
	environment := e.harnessEnvironment()
	for _, item := range e.environ() {
		name, _, _ := strings.Cut(item, "=")
		switch name {
		case "DOCKER_HOST", "DOCKER_CONFIG", "DOCKER_CONTEXT", "DOCKER_TLS_VERIFY", "DOCKER_CERT_PATH":
			environment = append(environment, item)
		}
	}
	return append(environment, "DIETER_STRIX_BIN="+executable)
}

// ensureManagedStrix installs the pinned Strix executable once per Dieter
// home under runtime/tools/strix/<version> and returns its path. env is the
// worker environment the install-time version probe runs with.
func ensureManagedStrix(ctx context.Context, dieterHome string, env []string) (string, error) {
	asset, ok := strixAssets[runtime.GOOS+"/"+runtime.GOARCH]
	if !ok {
		return "", fault.Invalidf("Strix does not support %s/%s", runtime.GOOS, runtime.GOARCH)
	}
	root := filepath.Join(dieterHome, "runtime", "tools", "strix")
	finalDir := filepath.Join(root, managedStrixVersion)
	executable := filepath.Join(finalDir, "strix")
	if validateManagedStrixFile(executable) == nil {
		return executable, nil
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return "", err
	}
	lock, err := fsx.LockContext(ctx, filepath.Join(root, ".install-"+managedStrixVersion+".lock"), 50*time.Millisecond)
	if err != nil {
		return "", fmt.Errorf("lock Strix %s installation: %w", managedStrixVersion, err)
	}
	defer lock.Close()
	if validateManagedStrixFile(executable) == nil {
		return executable, nil
	}
	if _, err := os.Lstat(finalDir); err == nil {
		quarantined := filepath.Join(root, fmt.Sprintf(".corrupt-%s-%d-%d", managedStrixVersion, os.Getpid(), time.Now().UnixNano()))
		if err := os.Rename(finalDir, quarantined); err != nil {
			return "", fmt.Errorf("quarantine corrupt Strix installation: %w", err)
		}
		defer os.RemoveAll(quarantined)
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	stageDir, err := os.MkdirTemp(root, ".stage-"+managedStrixVersion+"-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(stageDir)
	archive, err := downloadPinned(ctx, pinnedDownload{
		Label:   "Strix " + managedStrixVersion,
		Source:  strings.TrimRight(strixReleaseBaseURL, "/") + "/" + asset.Name + ".tar.gz",
		SHA256:  asset.SHA256,
		Limit:   maxStrixArchiveBytes,
		Timeout: strixDownloadTimeout,
		Client:  strixReleaseClient,
	}, root)
	if err != nil {
		return "", err
	}
	defer os.Remove(archive)
	staged := filepath.Join(stageDir, "strix")
	if err := extractStrixExecutable(archive, asset.Name, staged); err != nil {
		return "", fmt.Errorf("extract Strix %s: %w", managedStrixVersion, err)
	}
	if err := probeStrixVersion(ctx, staged, root, env); err != nil {
		return "", err
	}
	if err := fsx.SyncDir(stageDir); err != nil {
		return "", err
	}
	if err := os.Rename(stageDir, finalDir); err != nil {
		return "", fmt.Errorf("publish Strix %s installation: %w", managedStrixVersion, err)
	}
	if err := fsx.SyncDir(root); err != nil {
		return "", err
	}
	return executable, nil
}

// extractStrixExecutable copies the archive's single executable entry, and
// nothing else, to destination.
func extractStrixExecutable(archive, entry, destination string) error {
	file, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer file.Close()
	compressed, err := gzip.NewReader(bufio.NewReaderSize(file, 1<<20))
	if err != nil {
		return err
	}
	defer compressed.Close()
	reader := tar.NewReader(compressed)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			return fmt.Errorf("archive has no %s", entry)
		}
		if err != nil {
			return err
		}
		if strings.TrimPrefix(header.Name, "./") != entry {
			continue
		}
		if header.Typeflag != tar.TypeReg {
			return fmt.Errorf("%s is not a regular file", entry)
		}
		if header.Size > maxStrixExecutableBytes {
			return fmt.Errorf("%s is %d bytes, the limit is %d", entry, header.Size, maxStrixExecutableBytes)
		}
		output, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o700)
		if err != nil {
			return err
		}
		if _, err := io.Copy(output, io.LimitReader(reader, header.Size)); err != nil {
			_ = output.Close()
			return err
		}
		if err := output.Sync(); err != nil {
			_ = output.Close()
			return err
		}
		return output.Close()
	}
}

func validateManagedStrixFile(executable string) error {
	info, err := os.Lstat(executable)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode()&0o100 == 0 {
		return errors.New("managed Strix executable is not an executable regular file")
	}
	return nil
}

// probeStrixVersion runs the staged executable once, with a throwaway HOME
// under root. The PyInstaller bootloader unpacks itself on every launch, so
// this takes seconds.
func probeStrixVersion(ctx context.Context, executable, root string, env []string) error {
	home, err := os.MkdirTemp(root, ".probe-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(home)
	probeCtx, cancel := context.WithTimeout(ctx, strixVersionProbeTimeout)
	defer cancel()
	command := exec.CommandContext(probeCtx, executable, "--version")
	command.Env = append(append([]string(nil), env...), "HOME="+home, "STRIX_TELEMETRY=0", "STRIX_NO_UPDATE_CHECK=1")
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("run Strix %s: %s: %w", managedStrixVersion, strings.TrimSpace(string(output)), err)
	}
	if version := strings.TrimSpace(string(output)); version != "strix "+managedStrixVersion {
		return fmt.Errorf("Strix reports %q, want %q", version, "strix "+managedStrixVersion)
	}
	return nil
}
