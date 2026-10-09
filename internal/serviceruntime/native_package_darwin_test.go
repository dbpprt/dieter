package serviceruntime

import (
	"bytes"
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

// The native package gate supplies real ad-hoc signed products. Only this test's
// injected verifier accepts them; production still requires Developer ID.
func TestNativePrivacyPackageSmoke(t *testing.T) {
	source := os.Getenv("DIETER_TEST_PRIVACY_PACKAGE")
	if source == "" {
		t.Skip("requires privacy_native_test products")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 90*time.Second)
	defer cancel()
	bundle := filepath.Join(source, "DieterPrivacyHelper.app")
	entries, err := os.ReadDir(filepath.Join(bundle, "Contents/MacOS"))
	if err != nil || len(entries) != 1 || entries[0].Name() != "dieter-privacy" {
		t.Fatalf("privacy bundle must contain only its input helper: %v %v", entries, err)
	}
	helper := filepath.Join(bundle, "Contents/MacOS/dieter-privacy")
	linked, err := exec.CommandContext(ctx, "otool", "-L", helper).Output()
	if err != nil {
		t.Fatal(err)
	}
	for _, framework := range []string{"ScreenCaptureKit", "VideoToolbox", "AppKit"} {
		if bytes.Contains(linked, []byte(framework)) {
			t.Fatalf("privileged input helper links %s", framework)
		}
	}
	metadata, err := os.ReadFile(filepath.Join(bundle, "Contents/Info.plist"))
	if err != nil {
		t.Fatal(err)
	}
	rawHelper, err := os.ReadFile(helper)
	if err != nil {
		t.Fatal(err)
	}
	developmentMarker := []byte("DieterDevelopmentCaptureHash")
	release := os.Getenv("DIETER_TEST_PRIVACY_RELEASE") == "1"
	if bytes.Contains(metadata, developmentMarker) == release || bytes.Contains(rawHelper, developmentMarker) == release {
		t.Fatalf("development capture trust does not match release=%v", release)
	}
	// Query SMAppService through the actual bundle without registering anything.
	status, err := exec.CommandContext(ctx, helper, "--privacy-hid-status").Output()
	if err != nil || !json.Valid(status) {
		t.Fatalf("bundled service status: %s %v", status, err)
	}
	for _, arguments := range [][]string{{"--privacy-hid-service"}, {"--capabilities"}, {"--privacy-hid-register", "--privacy-directory", "/tmp/untrusted"}} {
		if output, err := exec.CommandContext(ctx, helper, arguments...).CombinedOutput(); err == nil {
			t.Fatalf("unprivileged helper accepted %v: %s", arguments, output)
		}
	}
	if output, err := exec.CommandContext(ctx, filepath.Join(source, "dieter-capture"), "--privacy-hid-service").CombinedOutput(); err == nil || !bytes.Contains(output, []byte("DieterPrivacyHelper.app")) {
		t.Fatalf("standalone capture admitted privileged mode: %s %v", output, err)
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	r := PlatformRuntime(filepath.Join(root, "service"))
	r.Verify = func(ctx context.Context, directory string) error {
		for path, identifier := range map[string]string{
			"dieter":                  "com.dbpprt.dieter.daemon",
			"dieter-capture":          "com.dbpprt.dieter.capture",
			"DieterPrivacyHelper.app": "com.dbpprt.dieter.privacy",
		} {
			output, err := exec.CommandContext(ctx, "codesign", "--verify", "--deep", "--strict", "-R", `=identifier "`+identifier+`"`, filepath.Join(directory, path)).CombinedOutput()
			if err != nil {
				t.Logf("native signature verification: %s", output)
				return err
			}
		}
		return nil
	}
	if err := r.Stage(ctx, source); err != nil {
		t.Fatal(err)
	}
	// Reproduce Homebrew's unchanged bin installation plus its internal resource.
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
	if err := copyBundle(bundle, filepath.Join(libexec, "DieterPrivacyHelper.app")); err != nil {
		t.Fatal(err)
	}
	r.SourceBundlePrefix = "../libexec"
	if err := r.Stage(ctx, bin); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(r.path("pending")); !os.IsNotExist(err) {
		t.Fatal("Homebrew layout changed the release identity")
	}
	r.SourceBundlePrefix = ""
	// Probe the real capture-side setup path with an isolated stand-in registrar.
	// It records the requested action; it cannot register a global service or
	// request Input Monitoring. The signed activated bundle is kept intact.
	setupLog := filepath.Join(root, "registrar.log")
	registrar := "#!/bin/sh\nset -eu\n[ \"$#\" -eq 1 ]\n[ \"$1\" = --privacy-hid-register ]\nprintf '%s\\n' \"$1\" >\"$DIETER_TEST_HELPER_SETUP_LOG\"\nprintf '%s\\n' '{\"available\":false,\"active\":false,\"deviceCount\":0,\"generation\":\"\",\"reason\":\"approval fixture\"}'\n"
	if err := os.WriteFile(filepath.Join(libexec, "DieterPrivacyHelper.app/Contents/MacOS/dieter-privacy"), []byte(registrar), 0755); err != nil {
		t.Fatal(err)
	}
	setup := exec.CommandContext(ctx, filepath.Join(bin, "dieter-capture"), "--privacy-setup")
	setup.Env = append(os.Environ(), "DIETER_TEST_HELPER_SETUP_LOG="+setupLog)
	setupRaw, err := setup.CombinedOutput()
	if err != nil || !json.Valid(setupRaw) {
		t.Fatalf("Homebrew foreground helper setup: %s %v", setupRaw, err)
	}
	var setupState struct {
		Supported           bool
		Requested           bool
		HelperSetupRequired bool `json:"helper_setup_required"`
		State               int
		Reason              string
	}
	if err := json.Unmarshal(setupRaw, &setupState); err != nil || setupState.Supported || setupState.Requested || !setupState.HelperSetupRequired || setupState.State != 0 || setupState.Reason != "approval fixture" {
		t.Fatalf("Homebrew setup must defer to approval and leave privacy off: %s %v", setupRaw, err)
	}
	if raw, err := os.ReadFile(setupLog); err != nil || string(raw) != "--privacy-hid-register\n" {
		t.Fatalf("helper registration action: %s %v", raw, err)
	}
	if err := VerifySignedPair(ctx, r.path("bin")); err == nil {
		t.Fatal("production verifier accepted development signatures")
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	listener.Close()
	home := filepath.Join(root, "data")
	log, err := os.Create(filepath.Join(root, "daemon.log"))
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	command := exec.Command(r.DaemonExecutable(), "--store", home, "daemon", "start", "--addr", address)
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
			t.Error("owned standalone daemon did not stop")
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
				t.Fatalf("standalone daemon/capture probe: %s", raw)
			}
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("standalone daemon did not become ready")
		case <-time.After(200 * time.Millisecond):
		}
	}
	// Read-only CLI privacy status must traverse the real packaged daemon route.
	raw, err := exec.CommandContext(ctx, r.DaemonExecutable(), "--store", home, "machine", "privacy", "status").Output()
	if err != nil || !json.Valid(raw) {
		t.Fatalf("standalone CLI privacy status: %s %v", raw, err)
	}
	if err := r.Stage(ctx, source); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(r.path("pending")); !os.IsNotExist(err) {
		t.Fatal("repeat installation staged a new activation")
	}
	t.Log("standalone daemon, synthetic capture, CLI privacy status, helper isolation, signature policy and idempotent staging passed")
}
