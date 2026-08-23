package gateway

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestDefaultRootMigratesLegacyDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("DIETER_GATEWAY_HOME", "")
	t.Setenv("NAUCLIO_GATEWAY_HOME", "")
	legacy := filepath.Join(home, ".nauclio-gateway")
	if err := os.MkdirAll(legacy, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacy, "marker"), []byte("kept"), 0o600); err != nil {
		t.Fatal(err)
	}

	root := DefaultRoot()
	if want := filepath.Join(home, ".dieter-gateway"); root != want {
		t.Fatalf("DefaultRoot() = %q, want %q", root, want)
	}
	if data, err := os.ReadFile(filepath.Join(root, "marker")); err != nil || string(data) != "kept" {
		t.Fatalf("migrated marker = %q, %v", data, err)
	}
	if _, err := os.Stat(legacy); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("legacy directory still exists: %v", err)
	}
}
