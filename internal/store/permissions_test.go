package store_test

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestPrivateMetadataCreationPreservesWorktreePermissions(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, "review")
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Private"})
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
	assertMode(t, s.CardDir(), 0700)
	assertMode(t, filepath.Join(s.CardDir(), card.ID+".md"), 0600)
	assertMode(t, worktreeFile, 0644)
}

func TestEnsureRehardensSensitiveRootFiles(t *testing.T) {
	t.Parallel()
	root := filepath.Join(t.TempDir(), "dieter")
	s := store.New(root)
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
