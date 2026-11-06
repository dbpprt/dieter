package home

import (
	"path/filepath"
)

func (s *Dir) CardDir() string { return filepath.Join(s.Root, "cards") }

func (s *Dir) ArchivedCardDir() string { return filepath.Join(s.Root, "archived-cards") }

func (s *Dir) ConversationDir() string { return filepath.Join(s.Root, "conversations") }

func (s *Dir) ScheduleDatabasePath() string { return filepath.Join(s.Root, "schedules.db") }

func (s *Dir) WorkspaceDir() string { return filepath.Join(s.Root, "workspaces") }

func (s *Dir) GitOperationDir() string { return filepath.Join(s.Root, "git-operations") }

func (s *Dir) PullRequestDir() string { return filepath.Join(s.Root, "pull-requests") }

func (s *Dir) ChangeCommentDir() string { return filepath.Join(s.Root, "change-comments") }

func (s *Dir) SettingsPath() string { return filepath.Join(s.Root, "settings.yaml") }

func (s *Dir) RuntimeDir() string { return filepath.Join(s.Root, "runtime") }

func (s *Dir) WorktreeRoot() string { return filepath.Join(s.Root, "worktrees") }

func (s *Dir) RecoveryDir() string { return filepath.Join(s.Root, "recovery") }
