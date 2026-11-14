package main

import (
	"context"
	"os"
	"path/filepath"
	"time"

	hostfolders "github.com/dbpprt/dieter/internal/host/folders"
)

// FoldersFixtureName is the synced folder the folder flows rely on.
const FoldersFixtureName = "Inbox"

// seedFoldersFixture creates the "Inbox" synced folder, kept by the fixture
// machine in HOME/synced/Inbox with welcome.txt, and waits for its first scan
// so a client sees the file at once. The engine must be running.
func seedFoldersFixture(ctx context.Context, folders *hostfolders.Engine, home string) error {
	dir := filepath.Join(home, "synced", FoldersFixtureName)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "welcome.txt"), []byte("Files you add here reach every member of the folder.\n"), 0o644); err != nil {
		return err
	}
	name := FoldersFixtureName
	definition, err := folders.CreateFolder(hostfolders.DefinitionChange{Name: &name})
	if err != nil {
		return err
	}
	if _, err := folders.Attach(ctx, hostfolders.AttachRequest{FolderID: definition.ID, Path: dir}); err != nil {
		return err
	}
	wait, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	return folders.WaitCycle(wait, definition.ID, true)
}
