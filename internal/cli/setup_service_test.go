package cli

import (
	"io"
	"log/slog"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	dieterdaemon "github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/server"
	"github.com/dbpprt/dieter/internal/store"
)

func TestSetupRejectsConflictingForegroundDaemon(t *testing.T) {
	data := store.New(t.TempDir())
	c := New(data)
	t.Cleanup(c.Close)
	host := httptest.NewServer(server.New(data, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler())
	t.Cleanup(host.Close)
	writer, err := dieterdaemon.NewStatusWriter(data.Root, dieterdaemon.RuntimeStatus{
		PID: os.Getpid(), State: "running", ListenAddress: strings.TrimPrefix(host.URL, "http://"),
	})
	if err != nil {
		t.Fatal(err)
	}
	err = setupServicePreflight(data.Root)
	if err == nil || !strings.Contains(err.Error(), "Ctrl-C") || !strings.Contains(err.Error(), "dieter setup") {
		t.Fatalf("missing actionable foreground conflict: %v", err)
	}
	if err := writer.Update(func(status *dieterdaemon.RuntimeStatus) { status.ServiceManaged = true }); err != nil {
		t.Fatal(err)
	}
	if err := setupServicePreflight(data.Root); err != nil {
		t.Fatalf("managed daemon rejected: %v", err)
	}
	if err := writer.Stop(); err != nil {
		t.Fatal(err)
	}
	if err := setupServicePreflight(data.Root); err != nil {
		t.Fatalf("stopped daemon rejected: %v", err)
	}
}

func TestSetupWaitRequiresEnrolledManagedDaemon(t *testing.T) {
	identity := &dieterdaemon.Identity{ID: "d_expected", GatewayURL: "https://gateway.example"}
	ready := dieterdaemon.RuntimeStatus{ServiceManaged: true, Enrolled: true, DaemonID: identity.ID, GatewayURL: identity.GatewayURL, GatewayState: dieterdaemon.GatewayConnected}
	if !setupDaemonReady(ready, identity) {
		t.Fatal("enrolled connected managed daemon not ready")
	}
	for _, name := range []string{"foreground", "unenrolled", "different identity", "different gateway", "connecting"} {
		t.Run(name, func(t *testing.T) {
			status := ready
			switch name {
			case "foreground":
				status.ServiceManaged = false
			case "unenrolled":
				status.Enrolled = false
			case "different identity":
				status.DaemonID = "d_old"
			case "different gateway":
				status.GatewayURL = "https://old.example"
			case "connecting":
				status.GatewayState = dieterdaemon.GatewayConnecting
			}
			if setupDaemonReady(status, identity) {
				t.Fatal("setup accepted stale or unready daemon")
			}
		})
	}
}
