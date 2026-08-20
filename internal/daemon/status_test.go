package daemon

import (
	"os"
	"testing"
	"time"
)

func TestStatusWriterLifecycle(t *testing.T) {
	root := t.TempDir()
	started := time.Now().UTC().Format(time.RFC3339Nano)
	writer, err := NewStatusWriter(root, RuntimeStatus{
		PID: 42, Version: "test", State: "running", StartedAt: started,
		ListenAddress: "127.0.0.1:4242", Enrolled: true, GatewayState: GatewayConnecting,
	})
	if err != nil {
		t.Fatal(err)
	}
	writer.Gateway(GatewayEvent{State: GatewayConnected})
	status, err := LoadRuntimeStatus(root)
	if err != nil {
		t.Fatal(err)
	}
	if status.PID != 42 || status.GatewayState != GatewayConnected || status.GatewayConnectedAt == "" {
		t.Fatalf("status=%#v", status)
	}
	if !RuntimeStatusCurrent(status, time.Now().UTC()) {
		t.Fatal("fresh running status was not current")
	}
	if info, err := os.Stat(RuntimeStatusPath(root)); err != nil {
		t.Fatal(err)
	} else if info.Mode().Perm() != 0o600 {
		t.Fatalf("status mode=%v", info.Mode().Perm())
	}
	if err := writer.Stop(); err != nil {
		t.Fatal(err)
	}
	status, _ = LoadRuntimeStatus(root)
	if status.State != "stopped" || status.StoppedAt == "" || RuntimeStatusCurrent(status, time.Now().UTC()) {
		t.Fatalf("stopped status=%#v", status)
	}
}
