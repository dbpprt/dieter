package store

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPrivateMetadataCreationPreservesWorktreePermissions(t *testing.T) {
	s, project, board := setup(t, "review")
	card, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, Title: "Private"})
	if err != nil {
		t.Fatal(err)
	}
	worktreeFile := filepath.Join(s.Root, "worktrees", "project", "script.sh")
	if err := os.MkdirAll(filepath.Dir(worktreeFile), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(worktreeFile, []byte("project data"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(worktreeFile, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := s.Ensure(); err != nil {
		t.Fatal(err)
	}
	assertMode(t, s.Root, 0700)
	assertMode(t, s.cardDir(), 0700)
	assertMode(t, filepath.Join(s.cardDir(), card.ID+".md"), 0600)
	assertMode(t, worktreeFile, 0644)
}

func TestEnsureRehardensSensitiveRootFiles(t *testing.T) {
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
