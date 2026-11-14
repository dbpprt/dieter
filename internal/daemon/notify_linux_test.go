//go:build linux

package daemon

import (
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestNotifySystemdReady(t *testing.T) {
	t.Parallel()
	path := filepath.Join(t.TempDir(), "notify.sock")
	address := &net.UnixAddr{Name: path, Net: "unixgram"}
	listener, err := net.ListenUnixgram("unixgram", address)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err := notifyServiceReady("systemd-user", path); err != nil {
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
