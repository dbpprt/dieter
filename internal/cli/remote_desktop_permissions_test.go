package cli

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	dieterdaemon "github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/server"
	"github.com/dbpprt/dieter/internal/store"
)

func permissionCLI(t *testing.T, options remotedesktop.Options) (*CLI, *bytes.Buffer, *store.Store) {
	t.Helper()
	data := store.New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	manager := remotedesktop.New(options)
	t.Cleanup(func() { manager.Shutdown(context.Background()) })
	application := server.NewWithOptions(data, slog.New(slog.NewTextHandler(io.Discard, nil)), server.Options{Runner: &fakeRunner{}, RemoteDesktop: manager})
	host := httptest.NewServer(application.Handler())
	t.Cleanup(host.Close)
	// A different caller root catches accidental local-store permission writes.
	local := store.New(t.TempDir())
	if err := local.Ensure(); err != nil {
		t.Fatal(err)
	}
	if _, err := dieterdaemon.NewStatusWriter(local.Root, dieterdaemon.RuntimeStatus{PID: os.Getpid(), State: "running", ListenAddress: strings.TrimPrefix(host.URL, "http://")}); err != nil {
		t.Fatal(err)
	}
	client := New(local)

	output := &bytes.Buffer{}
	client.Out, client.Err = output, output
	t.Cleanup(client.Close)
	return client, output, data
}

func TestRemoteDesktopPermissionGuideEnablesOnlyAfterDaemonProbe(t *testing.T) {
	client, output, data := permissionCLI(t, remotedesktop.Options{Source: remotedesktop.SourceOptions{Kind: "synthetic"}})
	if err := client.Run([]string{"daemon", "permissions", "--no-open"}); err != nil {
		t.Fatal(err)
	}
	settings, err := data.Settings()
	if err != nil {
		t.Fatal(err)
	}
	if !settings.RemoteDesktopEnabled || !settings.RemoteDesktopControlEnabled {
		t.Fatalf("daemon settings=%#v", settings)
	}
	local, _ := client.Store.Settings()
	if local.RemoteDesktopEnabled || local.RemoteDesktopControlEnabled {
		t.Fatal("onboarding mutated caller's store")
	}
	if !strings.Contains(output.String(), "no image was saved") || !strings.Contains(output.String(), "Daemon:") {
		t.Fatal(output.String())
	}
}

func TestRemoteDesktopPermissionCheckDoesNotChangeSettings(t *testing.T) {
	client, _, data := permissionCLI(t, remotedesktop.Options{Source: remotedesktop.SourceOptions{Kind: "synthetic"}})
	for _, args := range [][]string{{"daemon", "permissions", "--check"}, {"screen", "permissions"}} {
		if err := client.Run(args); err != nil {
			t.Fatal(err)
		}
	}
	settings, _ := data.Settings()
	if settings.RemoteDesktopEnabled || settings.RemoteDesktopControlEnabled {
		t.Fatal("check changed settings")
	}
}

func TestRemoteDesktopPermissionCheckUsesDeniedDaemonContext(t *testing.T) {
	t.Setenv("DIETER_REMOTE_DESKTOP_SOURCE", "synthetic")
	client, out, data := permissionCLI(t, remotedesktop.Options{Source: remotedesktop.SourceOptions{Kind: "synthetic"}, CaptureProbe: func(context.Context, remotedesktop.SourceOptions) error {
		return errors.New("denied in launchd service")
	}})
	for _, args := range [][]string{{"daemon", "permissions", "--check"}, {"screen", "permissions"}} {
		out.Reset()
		err := client.Run(args)
		if err == nil {
			t.Fatal("reported a denied daemon as ready")
		}
		if !strings.Contains(err.Error()+out.String(), "denied in launchd service") {
			t.Fatalf("lost service error: %v %s", err, out.String())
		}
	}
	settings, _ := data.Settings()
	if settings.RemoteDesktopEnabled {
		t.Fatal("denied capture enabled screen sharing")
	}
}

func TestRemoteDesktopPermissionCheckRequiresRunningDaemon(t *testing.T) {
	t.Setenv("DIETER_REMOTE_DESKTOP_SOURCE", "synthetic")
	client := New(store.New(t.TempDir()))

	client.Out = io.Discard
	defer client.Close()
	if err := client.Run([]string{"daemon", "permissions", "--check"}); err == nil {
		t.Fatal("unavailable service silently fell back to caller")
	}
}
