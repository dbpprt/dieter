//go:build e2e

package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestArchiveCLIReclaimsLocalWorktree(t *testing.T) {
	t.Parallel()
	client, output, data := daemonCLIForTest(t)
	repo := initTestRepository(t, "archive-cli")
	testkit.RunGit(t, repo, "add", ".")
	testkit.RunGit(t, repo, "commit", "-m", "initial")
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Archive", Path: repo, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	assertArchiveWorktreeCLI(t, client, output, data, project.ID)
}

func assertArchiveWorktreeCLI(t *testing.T, client *CLI, output *bytes.Buffer, data *store.Store, projectID string) {
	t.Helper()
	runDaemonCLI(t, client, output, "project", "update", "--delete-worktrees-on-archive=false", projectID)
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: projectID, Name: "Archive CLI"})
	if err != nil {
		t.Fatal(err)
	}
	var card struct {
		ID string `json:"id"`
	}
	raw := runDaemonCLI(t, client, output, "card", "create", "--project", projectID, "--board", board.ID, "--title", "Archive", "--prompt", "work", "--workspace", "worktree")
	if err := json.Unmarshal([]byte(raw), &card); err != nil || card.ID == "" {
		t.Fatalf("card: %s %v", raw, err)
	}
	runDaemonCLI(t, client, output, "workspace", "show", card.ID)
	value, err := data.Workspaces.Get(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	runDaemonCLI(t, client, output, "card", "archive", card.ID)
	if _, err := os.Stat(value.Path); err != nil {
		t.Fatalf("default archive deleted worktree: %v", err)
	}
	runDaemonCLI(t, client, output, "card", "unarchive", card.ID)
	runDaemonCLI(t, client, output, "project", "update", "--delete-worktrees-on-archive=true", projectID)
	runDaemonCLI(t, client, output, "project", "update", "--summary", "Keep archive preference", projectID)
	project, err := data.Kanban.ResolveProject(projectID)
	if err != nil || !project.DeleteWorktreesOnArchive {
		t.Fatalf("unrelated edit reset cleanup preference: %+v %v", project, err)
	}
	if err := os.WriteFile(filepath.Join(value.Path, "keep.txt"), []byte("uncommitted"), 0o644); err != nil {
		t.Fatal(err)
	}
	runDaemonCLI(t, client, output, "card", "archive", card.ID)
	if _, err := os.Stat(value.Path); err != nil {
		t.Fatalf("dirty tree removed: %v", err)
	}
	runDaemonCLI(t, client, output, "card", "unarchive", card.ID)
	if err := os.Remove(filepath.Join(value.Path, "keep.txt")); err != nil {
		t.Fatal(err)
	}
	runDaemonCLI(t, client, output, "card", "archive", card.ID)
	if _, err := os.Stat(value.Path); !os.IsNotExist(err) {
		t.Fatalf("tree remains: %v", err)
	}
	runDaemonCLI(t, client, output, "card", "unarchive", card.ID)
	runDaemonCLI(t, client, output, "workspace", "show", card.ID)
	if _, err := os.Stat(filepath.Join(value.Path, "README.md")); err != nil {
		t.Fatalf("tree not restored: %v", err)
	}
	runDaemonCLI(t, client, output, "project", "update", "--delete-worktrees-on-archive=false", projectID)
	runDaemonCLI(t, client, output, "card", "archive", card.ID)
	if _, err := os.Stat(value.Path); err != nil {
		t.Fatalf("disabled cleanup deleted worktree: %v", err)
	}
}
