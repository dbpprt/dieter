package home

import (
	"os"
	"path/filepath"
	"testing"
)

func TestProviderPathsAreCanonical(t *testing.T) {
	t.Parallel()
	dir := New("/data/dieter/")
	if got := dir.ProviderAccountDir("pa_x"); got != "/data/dieter/provider-accounts/pa_x" {
		t.Fatalf("account dir = %q", got)
	}
	if got := dir.CodexHome(); got != "/data/dieter/codex" {
		t.Fatalf("codex home = %q", got)
	}
}

func TestPrivateMetadataPermissionsCoverProviderSecrets(t *testing.T) {
	t.Parallel()
	dir := New(t.TempDir())
	files := []string{
		filepath.Join(dir.ProviderAccountDir("pa_one"), "siwc.json"),
		filepath.Join(dir.ProviderAccountsDir(), "ledger.ndjson"),
		filepath.Join(dir.ProviderAccountsDir(), "audit.ndjson"),
	}
	for _, path := range files {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("{}"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := dir.EnsurePrivateMetadataPermissions(); err != nil {
		t.Fatal(err)
	}
	for _, path := range files {
		info, err := os.Stat(path)
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Errorf("%s mode = %v, %v", path, info.Mode().Perm(), err)
		}
	}
}
