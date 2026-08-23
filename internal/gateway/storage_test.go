package gateway

import (
	"path/filepath"
	"testing"
)

func TestDefaultRootUsesDieterGatewayHome(t *testing.T) {
	want := filepath.Join(t.TempDir(), "gateway-state")
	t.Setenv("DIETER_GATEWAY_HOME", want)
	if got := DefaultRoot(); got != want {
		t.Fatalf("DefaultRoot() = %q, want %q", got, want)
	}
}

func TestDefaultRootUsesHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("DIETER_GATEWAY_HOME", "")
	if got, want := DefaultRoot(), filepath.Join(home, ".dieter-gateway"); got != want {
		t.Fatalf("DefaultRoot() = %q, want %q", got, want)
	}
}
