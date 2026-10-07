package serviceruntime

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Also usable locally with an existing signed release: verifies production
// requirements without requiring access to the Developer ID private key.
func TestVerifySignedReference(t *testing.T) {
	source := os.Getenv("DIETER_SIGNED_REFERENCE")
	if source == "" {
		t.Skip("no signed reference supplied")
	}
	fixture := fixtureRuntime(t)
	r := PlatformRuntime(fixture.Root)
	if err := r.Stage(context.Background(), source); err != nil {
		t.Fatal(err)
	}
	file, err := os.OpenFile(r.DaemonExecutable(), os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, err = file.WriteAt([]byte("corrupt"), 8192)
	file.Close()
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifySignedPair(context.Background(), r.path("bin")); err == nil {
		t.Fatal("accepted corrupted signed code")
	}
}

// Release CI runs the actual Developer ID-signed executable in a disposable
// runtime with synthetic pixels. This catches packaging/exec/CLI integration
// failures without claiming to prove OS privacy consent on a CI runner.
func TestSignedServiceRuntimeSmoke(t *testing.T) {
	source := os.Getenv("DIETER_SIGNED_SERVICE_SOURCE")
	if source == "" {
		t.Skip("requires release-signed daemon/helper artifacts")
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	r := PlatformRuntime(filepath.Join(root, "service"))
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if err := r.Stage(ctx, source); err != nil {
		t.Fatal(err)
	}
	// Exercise the real Homebrew post-install command with release signatures.
	brewPrefix := filepath.Join(root, "brew")
	bin, libexec := filepath.Join(brewPrefix, "bin"), filepath.Join(brewPrefix, "libexec")
	for _, directory := range []string{bin, libexec} {
		if err := os.MkdirAll(directory, 0755); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range executables {
		if err := copyExecutable(filepath.Join(source, name), filepath.Join(bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	if err := copyBundle(filepath.Join(source, "DieterPrivacyHelper.app"), filepath.Join(libexec, "DieterPrivacyHelper.app")); err != nil {
		t.Fatal(err)
	}
	if output, err := exec.CommandContext(ctx, filepath.Join(bin, "dieter"), "__service-stage", "--root", r.Root, "--bundle-prefix", "../libexec").CombinedOutput(); err != nil {
		t.Fatalf("Homebrew post-install: %s %v", output, err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	listener.Close()
	home := filepath.Join(root, "data")
	log, err := os.Create(filepath.Join(root, "service.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	command := exec.Command(r.DaemonExecutable(), "--store", home, "daemon", "start", "--service", "--runtime", r.Root, "--addr", address)
	for _, entry := range os.Environ() {
		if !strings.HasPrefix(entry, "DIETER_") {
			command.Env = append(command.Env, entry)
		}
	}
	command.Env = append(command.Env, "DIETER_HOME="+home, "DIETER_REMOTE_DESKTOP_SOURCE=synthetic")
	command.Stdout, command.Stderr = log, log
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait() }()
	defer func() {
		_ = command.Process.Signal(syscall.SIGTERM)
		select {
		case <-done:
		case <-time.After(15 * time.Second):
			t.Error("owned signed daemon did not stop")
		}
		if t.Failed() {
			raw, _ := os.ReadFile(log.Name())
			t.Log(string(raw))
		}
	}()
	for {
		probe := exec.CommandContext(ctx, r.DaemonExecutable(), "--store", home, "screen", "permissions")
		raw, err := probe.Output()
		if err == nil {
			var value struct {
				DaemonExecutable                 string
				CaptureVerified, ControlVerified bool
			}
			if err := json.Unmarshal(raw, &value); err != nil {
				t.Fatal(err)
			}
			if value.DaemonExecutable != r.DaemonExecutable() || !value.CaptureVerified || !value.ControlVerified {
				t.Fatalf("signed service probe: %s", raw)
			}
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("signed service did not become ready")
		case <-time.After(200 * time.Millisecond):
		}
	}
	before, err := r.releaseHash(r.path("bin"))
	if err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(ctx, source); err != nil {
		t.Fatal(err)
	}
	after, err := r.releaseHash(r.path("bin"))
	if err != nil || before != after {
		t.Fatal("repeat signed installation changed the running pair")
	}
}
