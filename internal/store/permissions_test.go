package store

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEnsureMigratesMetadataPermissionsWithoutChangingWorktrees(t *testing.T) {
	root := filepath.Join(t.TempDir(), "dieter")
	metadata := filepath.Join(root, "cards", "card.md")
	logFile := filepath.Join(root, "logs", "daemon.log")
	leaseFile := filepath.Join(root, "runtime", "leases", "card.json")
	worktreeFile := filepath.Join(root, "worktrees", "project", "script.sh")
	for _, path := range []string{metadata, logFile, leaseFile, worktreeFile} {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("private"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chmod(root, 0o755); err != nil {
		t.Fatal(err)
	}
	s := New(root)
	if err := s.Ensure(); err != nil {
		t.Fatal(err)
	}
	assertMode(t, root, 0o700)
	assertMode(t, filepath.Dir(metadata), 0o700)
	assertMode(t, metadata, 0o600)
	assertMode(t, logFile, 0o600)
	assertMode(t, leaseFile, 0o600)
	assertMode(t, worktreeFile, 0o644)
	assertMode(t, filepath.Join(root, privateMetadataPermissionsMarker), 0o600)
}

func TestEnsureRehardensSensitiveRootFilesAfterMigration(t *testing.T) {
	root := filepath.Join(t.TempDir(), "dieter")
	s := New(root)
	if err := s.Ensure(); err != nil {
		t.Fatal(err)
	}
	serviceEnvironment := filepath.Join(root, "service.env")
	if err := os.WriteFile(serviceEnvironment, []byte("TOKEN=secret\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := s.Ensure(); err != nil {
		t.Fatal(err)
	}
	assertMode(t, serviceEnvironment, 0o600)
}

func assertMode(t *testing.T, path string, want os.FileMode) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != want {
		t.Fatalf("%s mode = %04o, want %04o", path, got, want)
	}
}
