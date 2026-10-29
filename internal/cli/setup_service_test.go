package cli

import (
	"io"
	"log/slog"
	"os"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/api"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestSetupRejectsConflictingForegroundDaemon(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	c := New(data.Root)
	t.Cleanup(c.Close)
	host := testkit.HTTPServer(api.New(data, slog.New(slog.NewTextHandler(io.Discard, nil))).Handler())
	t.Cleanup(host.Close)
	writer, err := link.NewStatusWriter(data.Root, link.RuntimeStatus{
		PID: os.Getpid(), State: "running", ListenAddress: strings.TrimPrefix(host.URL, "http://"),
	})
	if err != nil {
		t.Fatal(err)
	}
	err = setupServicePreflight(data.Root)
	if err == nil || !strings.Contains(err.Error(), "Ctrl-C") || !strings.Contains(err.Error(), "dieter setup") {
		t.Fatalf("missing actionable foreground conflict: %v", err)
	}
	if err := writer.Update(func(status *link.RuntimeStatus) { status.ServiceManaged = true }); err != nil {
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
	t.Parallel()
	identity := &link.Identity{ID: "d_expected", GatewayURL: "https://gateway.example"}
	ready := link.RuntimeStatus{ServiceManaged: true, Enrolled: true, DaemonID: identity.ID, GatewayURL: identity.GatewayURL, GatewayState: link.GatewayConnected}
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
				status.GatewayState = link.GatewayConnecting
			}
			if setupDaemonReady(status, identity) {
				t.Fatal("setup accepted stale or unready daemon")
			}
		})
	}
}
