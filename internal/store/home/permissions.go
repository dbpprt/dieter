package home

import (
	"errors"
	"os"
	"path/filepath"
)

// Reapply private modes to sensitive files that external service tooling may
// replace. Dieter metadata writers create private files and directories directly.
func (s *Dir) EnsurePrivateMetadataPermissions() error {
	for _, path := range []string{
		s.SettingsPath(), s.ScheduleDatabasePath(), s.ScheduleDatabasePath() + "-wal",
		s.ScheduleDatabasePath() + "-shm", filepath.Join(s.Root, ".env"), filepath.Join(s.Root, "service.env"),
		filepath.Join(s.RuntimeDir(), "daemon.json"), filepath.Join(s.RuntimeDir(), "daemon.lock"),
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
