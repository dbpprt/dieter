package store

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
)

const privateMetadataPermissionsMarker = ".private-metadata-v1"

// migratePrivateMetadataPermissions hardens only Dieter-owned metadata. It
// deliberately excludes worktrees, recovery payloads, and the harness runtime,
// where changing file modes could alter user projects or executable packages.
func (s *Store) migratePrivateMetadataPermissions() error {
	marker := filepath.Join(s.Root, privateMetadataPermissionsMarker)
	_, markerErr := os.Lstat(marker)
	if markerErr != nil && !errors.Is(markerErr, os.ErrNotExist) {
		return markerErr
	}
	if errors.Is(markerErr, os.ErrNotExist) {
		directories := []string{
			s.projectDir(), s.boardDir(), s.cardDir(), s.archivedCardDir(),
			s.commentDir(), s.conversationDir(), s.scheduleDir(), s.scheduleRunDir(),
			s.authDir(), s.syncDir(), s.workspaceDir(), s.gitOperationDir(),
			s.pullRequestDir(), s.changeCommentDir(), filepath.Join(s.Root, "logs"), filepath.Join(s.runtimeDir(), "leases"),
		}
		for _, root := range directories {
			if err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
				if walkErr != nil {
					return walkErr
				}
				info, err := entry.Info()
				if err != nil {
					return err
				}
				if info.Mode()&os.ModeSymlink != 0 {
					return nil
				}
				if info.IsDir() {
					return os.Chmod(path, 0o700)
				}
				if info.Mode().IsRegular() {
					return os.Chmod(path, 0o600)
				}
				return nil
			}); err != nil {
				return err
			}
		}
		if err := atomicWriteMode(marker, []byte("Dieter metadata is private.\n"), 0o600); err != nil {
			return err
		}
	}
	for _, path := range []string{
		s.settingsPath(), s.scheduleDatabasePath(), s.scheduleDatabasePath() + "-wal",
		s.scheduleDatabasePath() + "-shm", filepath.Join(s.Root, ".env"), filepath.Join(s.Root, "service.env"),
		filepath.Join(s.runtimeDir(), "daemon.json"), filepath.Join(s.runtimeDir(), "daemon.lock"),
	} {
		if info, err := os.Lstat(path); err == nil && info.Mode().IsRegular() {
			if err := os.Chmod(path, 0o600); err != nil {
				return err
			}
		} else if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}
