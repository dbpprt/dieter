//go:build linux

package cli

import (
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestInstallSystemdUserService(t *testing.T) {
	testExecutable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(t.TempDir(), "data with spaces")
	config := filepath.Join(t.TempDir(), "config")
	bin := t.TempDir()
	logPath := filepath.Join(t.TempDir(), "systemctl.log")
	systemctl := filepath.Join(bin, "systemctl")
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$DIETER_TEST_SYSTEMCTL_LOG\"\n"
	if err := os.WriteFile(systemctl, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XDG_CONFIG_HOME", config)
	t.Setenv("DIETER_TEST_SYSTEMCTL_LOG", logPath)
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	var output strings.Builder
	if err := installSystemdUserService(root, linuxServiceInstallOptions{
		start: true, address: "127.0.0.1:4242", directAddress: "0.0.0.0:4243",
		directHost: "host.example.test", directNetwork: "tailscale", captureExecutable: testExecutable,
	}, &output); err != nil {
		t.Fatal(err)
	}
	unitPath := filepath.Join(config, "systemd", "user", "dieter.service")
	raw, err := os.ReadFile(unitPath)
	if err != nil {
		t.Fatal(err)
	}
	unit := string(raw)
	for _, expected := range []string{
		managedSystemdUnitHeader, "Type=notify", "NotifyAccess=main",
		"Restart=always", "TimeoutStopSec=30s", "KillMode=mixed", "UMask=0077",
		"DIETER_SERVICE_MANAGER=systemd-user", "EnvironmentFile=-" + strings.ReplaceAll(root, " ", `\x20`) + "/service.env",
		"\"--store\" \"" + root + "\" \"daemon\" \"start\" \"--service\"",
		"\"--direct-addr\" \"0.0.0.0:4243\" \"--direct-host\" \"host.example.test\" \"--direct-network\" \"tailscale\"",
	} {
		if !strings.Contains(unit, expected) {
			t.Errorf("unit missing %q:\n%s", expected, unit)
		}
	}
	info, err := os.Stat(unitPath)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("unit mode = %v, %v", info, err)
	}
	commands, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	if got := string(commands); !strings.Contains(got, "--user daemon-reload") || !strings.Contains(got, "--user enable dieter.service") || !strings.Contains(got, "--user restart dieter.service") {
		t.Fatalf("systemctl calls = %q", got)
	}
	if err := installSystemdUserService(root, linuxServiceInstallOptions{
		start: true, address: "127.0.0.1:4242", directNetwork: "lan", preserveRoute: true, captureExecutable: testExecutable,
	}, &output); err != nil {
		t.Fatal(err)
	}
	refreshed, err := os.ReadFile(unitPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(refreshed), "\"--direct-host\" \"host.example.test\"") {
		t.Fatalf("service refresh lost its explicit direct route:\n%s", refreshed)
	}
}

func TestInstallSystemdUserServiceRefusesForeignUnit(t *testing.T) {
	config := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", config)
	unitPath := filepath.Join(config, "systemd", "user", "dieter.service")
	if err := os.MkdirAll(filepath.Dir(unitPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(unitPath, []byte("[Service]\nExecStart=/bin/false\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := installSystemdUserService(t.TempDir(), linuxServiceInstallOptions{address: "127.0.0.1:4242", directNetwork: "lan"}, &strings.Builder{}); err == nil || !strings.Contains(err.Error(), "not managed by Dieter") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestNotifySystemdReady(t *testing.T) {
	path := filepath.Join(t.TempDir(), "notify.sock")
	address := &net.UnixAddr{Name: path, Net: "unixgram"}
	listener, err := net.ListenUnixgram("unixgram", address)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	t.Setenv("NOTIFY_SOCKET", path)
	if err := notifyServiceReady("systemd-user"); err != nil {
		t.Fatal(err)
	}
	if err := listener.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, 256)
	count, _, err := listener.ReadFromUnix(buffer)
	if err != nil {
		t.Fatal(err)
	}
	message := string(buffer[:count])
	if !strings.Contains(message, "READY=1") || !strings.Contains(message, "MAINPID=") {
		t.Fatalf("notification = %q", message)
	}
}
