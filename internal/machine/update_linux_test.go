//go:build linux

package machine

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestLinuxUpdateWorkerDownloadsVerifiesStagesAndRestarts(t *testing.T) {
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	binary, err := os.ReadFile(executable)
	if err != nil {
		t.Fatal(err)
	}
	asset := "dieter-linux-" + runtime.GOARCH
	archive := linuxUpdateArchive(t, asset+"/dieter", binary)
	digest := sha256.Sum256(archive)
	checksums := fmt.Sprintf("%s  %s.tar.gz\n", hex.EncodeToString(digest[:]), asset)
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/SHA256SUMS":
			_, _ = writer.Write([]byte(checksums))
		case "/SHA256SUMS.sigstore.json":
			_, _ = writer.Write([]byte(`{"verified":"fixture"}`))
		case "/" + asset + ".tar.gz":
			_, _ = writer.Write(archive)
		default:
			http.NotFound(writer, request)
		}
	}))
	defer server.Close()
	bin := t.TempDir()
	systemctlLog := filepath.Join(t.TempDir(), "systemctl.log")
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$DIETER_TEST_SYSTEMCTL_LOG\"\n"
	if err := os.WriteFile(filepath.Join(bin, "systemctl"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "cosign"), []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	t.Setenv("DIETER_TEST_SYSTEMCTL_LOG", systemctlLog)
	root := t.TempDir()
	var output strings.Builder
	if err := RunLinuxDaemonUpdateWorker([]string{"--root", root, "--base-url", server.URL}, &output); err != nil {
		t.Fatal(err)
	}
	installed, err := os.ReadFile(filepath.Join(root, "service", "bin", "dieter"))
	if err != nil {
		t.Fatal(err)
	}
	if got := sha256.Sum256(installed); got != sha256.Sum256(binary) {
		t.Fatal("staged Linux runtime differs from verified release")
	}
	commands, err := os.ReadFile(systemctlLog)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(commands), "--user restart dieter.service") {
		t.Fatalf("systemctl calls = %q", commands)
	}
}

func TestLinuxUpdateWorkerRejectsChecksumMismatch(t *testing.T) {
	asset := "dieter-linux-" + runtime.GOARCH
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/SHA256SUMS" {
			fmt.Fprintf(writer, "%064d  %s.tar.gz\n", 0, asset)
			return
		}
		if request.URL.Path == "/SHA256SUMS.sigstore.json" {
			_, _ = writer.Write([]byte(`{"verified":"fixture"}`))
			return
		}
		_, _ = writer.Write(linuxUpdateArchive(t, asset+"/dieter", []byte("not trusted")))
	}))
	defer server.Close()
	bin := t.TempDir()
	if err := os.WriteFile(filepath.Join(bin, "cosign"), []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	err := RunLinuxDaemonUpdateWorker([]string{"--root", t.TempDir(), "--base-url", server.URL}, &strings.Builder{})
	if err == nil || !strings.Contains(err.Error(), "checksum") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestReleaseChecksumRejectsDuplicateEntries(t *testing.T) {
	line := strings.Repeat("a", 64) + "  dieter-linux-amd64.tar.gz\n"
	if _, err := releaseChecksum([]byte(line+line), "dieter-linux-amd64.tar.gz"); err == nil || !strings.Contains(err.Error(), "duplicate") {
		t.Fatalf("duplicate checksum error = %v", err)
	}
}

func linuxUpdateArchive(t *testing.T, name string, body []byte) []byte {
	t.Helper()
	var raw bytes.Buffer
	gzipWriter := gzip.NewWriter(&raw)
	tarWriter := tar.NewWriter(gzipWriter)
	if err := tarWriter.WriteHeader(&tar.Header{Name: name, Typeflag: tar.TypeReg, Mode: 0o755, Size: int64(len(body))}); err != nil {
		t.Fatal(err)
	}
	if _, err := tarWriter.Write(body); err != nil {
		t.Fatal(err)
	}
	if err := tarWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if err := gzipWriter.Close(); err != nil {
		t.Fatal(err)
	}
	return raw.Bytes()
}
