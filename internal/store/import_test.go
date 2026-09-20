package store

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func TestOfflineImportPreservesConversationIDsAndBackup(t *testing.T) {
	root := t.TempDir()
	s := New(root)
	repo := sharedRepo(t)
	p := model.Project{ID: "p_legacy", Name: "Legacy", Path: repo, Prompt: "Keep instructions", CreatedAt: timestamp()}
	b := model.Board{ID: "b_legacy", ProjectID: p.ID, Name: "Main", Workflow: model.WorkflowReview, CreatedAt: timestamp()}
	c := model.Card{ID: "c_legacy", ProjectID: p.ID, BoardID: b.ID, Title: "Durable", InitialPrompt: "Keep task", Lane: model.LaneTodo, Position: 1024, CreatedAt: timestamp(), WorkspaceMode: model.WorkspaceModeProject}
	if err := writeMarkdown(filepath.Join(s.projectDir(), p.ID+".md"), p, p.Prompt); err != nil {
		t.Fatal(err)
	}
	if err := writeMarkdown(filepath.Join(s.boardDir(), b.ID+".md"), b, ""); err != nil {
		t.Fatal(err)
	}
	if err := writeMarkdown(filepath.Join(s.cardDir(), c.ID+".md"), c, c.InitialPrompt); err != nil {
		t.Fatal(err)
	}
	payload := []byte("retained conversation evidence")
	if err := atomicWrite(filepath.Join(s.conversationDir(), c.ID, "evidence.txt"), payload); err != nil {
		t.Fatal(err)
	}
	if err := s.Ensure(); !errors.Is(err, ErrLegacyStore) {
		t.Fatalf("legacy start: %v", err)
	}
	backup := filepath.Join(t.TempDir(), "backup")
	report, err := s.ImportLegacy(backup, false)
	if err != nil || report.Projects != 1 || report.Conversations != 1 || report.Applied {
		t.Fatalf("dry run: %+v %v", report, err)
	}
	if _, err = os.Stat(backup); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("dry run created a backup")
	}
	report, err = s.ImportLegacy(backup, true)
	if err != nil || !report.Applied {
		t.Fatalf("apply: %+v %v", report, err)
	}
	if err = New(root).Ensure(); err != nil {
		t.Fatal(err)
	}
	detail, err := New(root).CardDetail(c.ID)
	if err != nil || detail.Card.ID != c.ID || detail.Project.Path != repo || detail.Card.InitialPrompt != c.InitialPrompt {
		t.Fatalf("detail: %+v %v", detail, err)
	}
	if data, err := os.ReadFile(filepath.Join(backup, "conversations", c.ID, "evidence.txt")); err != nil || string(data) != string(payload) {
		t.Fatalf("backup changed: %q %v", data, err)
	}
	if data, err := os.ReadFile(filepath.Join(root, "conversations", c.ID, "evidence.txt")); err != nil || string(data) != string(payload) {
		t.Fatalf("conversation changed: %q %v", data, err)
	}
}

func TestOfflineImportRefusesRunningSource(t *testing.T) {
	s := New(t.TempDir())
	if err := writeJSON(filepath.Join(s.runtimeDir(), "daemon.json"), map[string]int{"pid": os.Getpid()}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.ImportLegacy(filepath.Join(t.TempDir(), "backup"), true); err == nil {
		t.Fatal("live source imported")
	}
}

func TestOfflineImportRejectsSQLiteReferencesBeforeBackup(t *testing.T) {
	s := New(t.TempDir())
	db, err := s.scheduleDatabase()
	if err != nil {
		t.Fatal(err)
	}
	if err = upsertScheduleDocument(db, model.Schedule{ID: "sc_orphan", ProjectID: "p_missing"}); err != nil {
		t.Fatal(err)
	}
	backup := filepath.Join(t.TempDir(), "backup")
	if _, err = s.ImportLegacy(backup, true); err == nil {
		t.Fatal("invalid SQLite schedule imported")
	}
	if _, err = os.Stat(backup); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("preflight failure created backup")
	}
}

func TestOfflineImportResumesAfterReadyBackupAndDrainsScheduleOutbox(t *testing.T) {
	s := New(t.TempDir())
	p := model.Project{ID: "p_resume", Name: "Resume", Path: sharedRepo(t), CreatedAt: timestamp()}
	if err := writeMarkdown(filepath.Join(s.projectDir(), p.ID+".md"), p, ""); err != nil {
		t.Fatal(err)
	}
	db, err := s.scheduleDatabase()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 105; i++ {
		item := model.Schedule{ID: fmt.Sprintf("sc_%03d", i), ProjectID: p.ID, Name: fmt.Sprintf("Schedule %03d", i)}
		if err = upsertScheduleDocument(db, item); err != nil {
			t.Fatal(err)
		}
	}
	if err = db.Close(); err != nil {
		t.Fatal(err)
	}
	s.scheduleDB = nil
	backup := filepath.Join(t.TempDir(), "backup")
	if err = copyStoreBackup(s.Root, backup); err != nil {
		t.Fatal(err)
	}
	if err = writeJSON(filepath.Join(s.Root, "import-state.json"), importManifest{Backup: backup, Ready: true}); err != nil {
		t.Fatal(err)
	}
	// A crash after writing the new schema and removing old project projections
	// must recover from the immutable backup, not incomplete source projections.
	if err = os.Remove(filepath.Join(s.projectDir(), p.ID+".md")); err != nil {
		t.Fatal(err)
	}
	if err = atomicWrite(filepath.Join(s.Root, "storage-schema.json"), []byte(`{"version":2}`)); err != nil {
		t.Fatal(err)
	}
	if err = New(s.Root).Ensure(); err == nil {
		t.Fatal("incomplete import became runnable")
	}
	report, err := s.ImportLegacy(backup, true)
	if err != nil || !report.Applied {
		t.Fatalf("resume: %+v %v", report, err)
	}
	if err = New(s.Root).Ensure(); err != nil {
		t.Fatal(err)
	}
	ids, err := s.localScheduleIDs()
	if err != nil || len(ids) != 105 {
		t.Fatalf("schedule summaries: %d %v", len(ids), err)
	}
	if _, err = os.Stat(filepath.Join(backup, "projects", p.ID+".md")); err != nil {
		t.Fatal("backup changed", err)
	}
}
