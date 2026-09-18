//go:build linux

package machine

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/dbpprt/dieter/internal/serviceruntime"
)

const linuxReleaseBaseURL = "https://github.com/dbpprt/dieter/releases/latest/download"
const linuxReleaseSigner = "https://github.com/dbpprt/dieter/.github/workflows/release.yml@refs/heads/main"
const githubOIDCIssuer = "https://token.actions.githubusercontent.com"

func linuxUpdateCapability(root string) OperationCapability {
	result := OperationCapability{Operation: OperationUpdate, UnavailableReason: "automatic updates require a Dieter-managed systemd user service"}
	raw, err := os.ReadFile(filepath.Join(root, "runtime", "daemon.json"))
	if err != nil {
		return result
	}
	var status struct {
		ServiceManaged bool   `json:"serviceManaged"`
		ServiceManager string `json:"serviceManager"`
	}
	if json.Unmarshal(raw, &status) != nil || !status.ServiceManaged || status.ServiceManager != "systemd-user" {
		return result
	}
	executable, err := os.Executable()
	if err != nil {
		return result
	}
	executable, err = filepath.EvalSymlinks(executable)
	if err != nil || executable != filepath.Join(root, "service", "bin", "dieter") {
		result.UnavailableReason = "the running daemon is not using Dieter's managed Linux runtime"
		return result
	}
	for _, command := range []string{"systemctl", "systemd-run", "cosign"} {
		if _, err := exec.LookPath(command); err != nil {
			result.UnavailableReason = command + " is required for managed Linux updates"
			return result
		}
	}
	if runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64" {
		result.UnavailableReason = "automatic Linux updates support amd64 and arm64"
		return result
	}
	result.Supported, result.Authorized, result.UnavailableReason = true, true, ""
	return result
}

func startLinuxUpdateWorker(root string) error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	systemdRun, err := exec.LookPath("systemd-run")
	if err != nil {
		return err
	}
	logDirectory := filepath.Join(root, "logs")
	if err := os.MkdirAll(logDirectory, 0o700); err != nil {
		return err
	}
	logPath := filepath.Join(logDirectory, "update.log")
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer logFile.Close()
	command := exec.Command(systemdRun,
		"--user", "--unit=dieter-update", "--collect", "--quiet", "--property=Type=exec",
		"--setenv=PATH="+os.Getenv("PATH"),
		"--property=StandardOutput=append:"+logPath,
		"--property=StandardError=append:"+logPath,
		"--",
		executable, "__linux-update-worker", "--root", root,
	)
	command.Stdin = nil
	command.Stdout, command.Stderr = logFile, logFile
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := command.Run(); err != nil {
		return fmt.Errorf("start systemd Linux update worker: %w", err)
	}
	return nil
}

func RunLinuxDaemonUpdateWorker(args []string, output io.Writer) error {
	set := flag.NewFlagSet("Linux daemon update worker", flag.ContinueOnError)
	set.SetOutput(output)
	root := set.String("root", "", "absolute DIETER_HOME")
	baseURL := set.String("base-url", linuxReleaseBaseURL, "release asset base URL")
	if err := set.Parse(args); err != nil {
		return err
	}
	if set.NArg() != 0 || !filepath.IsAbs(*root) || filepath.Clean(*root) != *root {
		return errors.New("Linux update worker requires a clean absolute --root")
	}
	if err := validateLinuxReleaseBaseURL(*baseURL); err != nil {
		return err
	}
	asset := "dieter-linux-" + runtime.GOARCH
	if runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64" {
		return fmt.Errorf("unsupported Linux update architecture %s", runtime.GOARCH)
	}
	fmt.Fprintf(output, "%s: download %s\n", time.Now().UTC().Format(time.RFC3339), asset)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	temporary, err := os.MkdirTemp(*root, ".linux-update-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(temporary)
	checksums, err := downloadLinuxUpdate(ctx, strings.TrimRight(*baseURL, "/")+"/SHA256SUMS", 4<<20)
	if err != nil {
		return fmt.Errorf("download release checksums: %w", err)
	}
	bundle, err := downloadLinuxUpdate(ctx, strings.TrimRight(*baseURL, "/")+"/SHA256SUMS.sigstore.json", 4<<20)
	if err != nil {
		return fmt.Errorf("download release signature bundle: %w", err)
	}
	checksumsPath := filepath.Join(temporary, "SHA256SUMS")
	bundlePath := filepath.Join(temporary, "SHA256SUMS.sigstore.json")
	if err := os.WriteFile(checksumsPath, checksums, 0o600); err != nil {
		return err
	}
	if err := os.WriteFile(bundlePath, bundle, 0o600); err != nil {
		return err
	}
	if err := verifyLinuxReleaseManifest(ctx, checksumsPath, bundlePath); err != nil {
		return err
	}
	expected, err := releaseChecksum(checksums, asset+".tar.gz")
	if err != nil {
		return err
	}
	archive, err := downloadLinuxUpdate(ctx, strings.TrimRight(*baseURL, "/")+"/"+asset+".tar.gz", 300<<20)
	if err != nil {
		return fmt.Errorf("download Linux release: %w", err)
	}
	digest := sha256.Sum256(archive)
	if !strings.EqualFold(hex.EncodeToString(digest[:]), expected) {
		return errors.New("Linux release checksum does not match SHA256SUMS")
	}
	stage := filepath.Join(temporary, "stage")
	if err := os.Mkdir(stage, 0o700); err != nil {
		return err
	}
	if err := extractLinuxDaemon(archive, asset+"/dieter", filepath.Join(stage, "dieter")); err != nil {
		return err
	}
	fmt.Fprintf(output, "%s: stage verified release\n", time.Now().UTC().Format(time.RFC3339))
	if err := serviceruntime.PlatformRuntime(filepath.Join(*root, "service")).Stage(ctx, stage); err != nil {
		return fmt.Errorf("stage Linux service runtime: %w", err)
	}
	systemctl, err := exec.LookPath("systemctl")
	if err != nil {
		return err
	}
	fmt.Fprintf(output, "%s: restart Dieter service\n", time.Now().UTC().Format(time.RFC3339))
	restartCtx, restartCancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer restartCancel()
	command := exec.CommandContext(restartCtx, systemctl, "--user", "restart", "dieter.service")
	command.Stdout, command.Stderr = output, output
	if err := command.Run(); err != nil {
		return fmt.Errorf("restart Dieter systemd user service: %w", err)
	}
	fmt.Fprintf(output, "%s: update staged and restart completed\n", time.Now().UTC().Format(time.RFC3339))
	return nil
}

func verifyLinuxReleaseManifest(ctx context.Context, checksumsPath, bundlePath string) error {
	cosign, err := exec.LookPath("cosign")
	if err != nil {
		return errors.New("cosign is required to verify Linux release provenance")
	}
	verifyCtx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	output, err := exec.CommandContext(verifyCtx, cosign, "verify-blob",
		"--bundle", bundlePath,
		"--certificate-identity", linuxReleaseSigner,
		"--certificate-oidc-issuer", githubOIDCIssuer,
		checksumsPath,
	).CombinedOutput()
	if err != nil {
		return fmt.Errorf("verify signed Linux release manifest: %w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

func validateLinuxReleaseBaseURL(raw string) error {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return errors.New("invalid Linux release base URL")
	}
	if parsed.Scheme == "https" && parsed.Hostname() == "github.com" && strings.HasPrefix(parsed.Path, "/dbpprt/dieter/releases/") {
		return nil
	}
	if parsed.Scheme == "http" && net.ParseIP(parsed.Hostname()) != nil && net.ParseIP(parsed.Hostname()).IsLoopback() {
		return nil
	}
	return errors.New("Linux release base URL must be the Dieter GitHub release or a loopback test server")
}

func downloadLinuxUpdate(ctx context.Context, rawURL string, limit int64) ([]byte, error) {
	client := &http.Client{Timeout: 5 * time.Minute, CheckRedirect: func(request *http.Request, via []*http.Request) error {
		if len(via) > 5 {
			return errors.New("too many release redirects")
		}
		host := request.URL.Hostname()
		if request.URL.Scheme == "https" && (host == "github.com" || strings.HasSuffix(host, ".githubusercontent.com")) {
			return nil
		}
		if request.URL.Scheme == "http" {
			ip := net.ParseIP(host)
			if ip != nil && ip.IsLoopback() {
				return nil
			}
		}
		return errors.New("release redirect left trusted hosts")
	}}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %s", response.Status)
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(raw)) > limit {
		return nil, errors.New("release asset exceeds size limit")
	}
	return raw, nil
}

func releaseChecksum(raw []byte, name string) (string, error) {
	match := ""
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 || strings.TrimPrefix(fields[1], "*") != name {
			continue
		}
		if len(fields[0]) != sha256.Size*2 {
			break
		}
		if _, err := hex.DecodeString(fields[0]); err != nil {
			break
		}
		if match != "" {
			return "", fmt.Errorf("SHA256SUMS contains duplicate entries for %s", name)
		}
		match = strings.ToLower(fields[0])
	}
	if match != "" {
		return match, nil
	}
	return "", fmt.Errorf("SHA256SUMS does not contain %s", name)
}

func extractLinuxDaemon(archive []byte, expectedName, target string) error {
	gzipReader, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return fmt.Errorf("open Linux release archive: %w", err)
	}
	defer gzipReader.Close()
	tarReader := tar.NewReader(gzipReader)
	found := false
	for {
		header, err := tarReader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		name := filepath.ToSlash(filepath.Clean(header.Name))
		if strings.HasPrefix(name, "../") || strings.HasPrefix(name, "/") {
			return errors.New("Linux release archive contains an unsafe path")
		}
		if name != expectedName {
			continue
		}
		if found || header.Typeflag != tar.TypeReg || header.Size < 1 || header.Size > 256<<20 {
			return errors.New("Linux release contains an invalid daemon executable")
		}
		file, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o755)
		if err != nil {
			return err
		}
		_, copyErr := io.CopyN(file, tarReader, header.Size)
		syncErr := file.Sync()
		closeErr := file.Close()
		if err := errors.Join(copyErr, syncErr, closeErr); err != nil {
			return err
		}
		found = true
	}
	if !found {
		return fmt.Errorf("Linux release archive does not contain %s", expectedName)
	}
	return nil
}
