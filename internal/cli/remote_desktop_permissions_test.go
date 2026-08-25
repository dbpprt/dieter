package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/store"
)

func TestRemoteDesktopPermissionGuideEnablesOnlyAfterCaptureProbe(t *testing.T) {
	data := store.New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	client := New(data)
	output := &bytes.Buffer{}
	client.Out = output
	if err := client.runRemoteDesktopPermissionGuide(remotedesktop.SourceOptions{Kind: "synthetic"}, false, true); err != nil {
		t.Fatal(err)
	}
	settings, err := data.Settings()
	if err != nil {
		t.Fatal(err)
	}
	if !settings.RemoteDesktopEnabled || settings.RemoteDesktopControlEnabled {
		t.Fatalf("remote desktop settings=%#v", settings)
	}
	if !strings.Contains(output.String(), "no image was saved") {
		t.Fatalf("onboarding output=%q", output.String())
	}
}

func TestRemoteDesktopPermissionCheckDoesNotChangeSettings(t *testing.T) {
	data := store.New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	client := New(data)
	client.Out = &bytes.Buffer{}
	if err := client.runRemoteDesktopPermissionGuide(remotedesktop.SourceOptions{Kind: "synthetic"}, true, true); err != nil {
		t.Fatal(err)
	}
	settings, err := data.Settings()
	if err != nil {
		t.Fatal(err)
	}
	if settings.RemoteDesktopEnabled {
		t.Fatalf("check-only permission probe changed settings: %#v", settings)
	}
}
