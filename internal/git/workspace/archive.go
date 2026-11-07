package workspace

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/git"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/home"
)

// ArchiveCard retains the conversation even when its workspace cannot yet be
// removed. The serve-only sweep retries retained workspaces, including archives
// made by older releases or on another replica.
func (m *Manager) ArchiveCard(ctx context.Context, ref string, archived bool) (model.Card, error) {
	card, err := m.Store.Kanban.ArchiveCard(ref, archived)
	if err == nil && archived && m.Store.Kanban.RequireLocalCard(card) == nil {
		m.cleanupArchive(ctx, card.ID)
	}
	return card, err
}

func (m *Manager) cleanupArchive(ctx context.Context, cardID string) {
	if err := m.CleanupArchived(ctx, cardID); err != nil {
		m.Log.Warn("archived conversation worktree retained; cleanup will retry", "card", cardID, "error", git.Redact(err.Error()))
	}
}

// CleanupArchivedWorktrees is called by the scheduler, never by construction of
// an HTTP handler. Reserved records already represent reclaimed directories.
func (m *Manager) CleanupArchivedWorktrees(ctx context.Context) {
	values, err := m.Store.Workspaces.List("")
	if err != nil {
		m.Log.Warn("could not list archived worktrees", "error", err)
		return
	}
	for _, value := range values {
		if ctx.Err() != nil {
			return
		}
		if value.Mode != model.WorkspaceModeWorktree || value.State == model.WorkspaceStateReserved {
			continue
		}
		card, err := m.Store.Kanban.ResolveCard(value.CardID)
		if err == nil && card.Archived && m.Store.Kanban.RequireLocalCard(card) == nil {
			m.cleanupArchive(ctx, card.ID)
		}
	}
}

func (m *Manager) CleanupArchived(ctx context.Context, cardID string) error {
	card, err := m.Store.Kanban.ResolveCard(cardID)
	if err != nil {
		return err
	}
	project, err := m.Store.Kanban.ResolveProjectIncludingArchived(card.ProjectID)
	if err != nil || !project.DeleteWorktreesOnArchive {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if m.CleanupGuard != nil {
		defer m.CleanupGuard()()
	}
	release, err := m.LockWorkspace(ctx, cardID)
	if err != nil {
		return err
	}
	defer release()
	value, err := m.Store.Workspaces.ByCardID(cardID)
	if errors.Is(err, home.ErrNotFound) {
		return nil
	}
	if err != nil || value.Mode != model.WorkspaceModeWorktree || value.State == model.WorkspaceStateReserved {
		return err
	}
	project, err = m.Store.Kanban.ProjectForArchivedWorkspace(value)
	if err != nil {
		return err
	}
	releaseRepo, err := m.lockRepositoryPath(ctx, project.Path)
	if err != nil {
		return err
	}
	defer releaseRepo()
	return m.Store.Workspaces.CleanupArchivedWorkspace(cardID, func(value model.Workspace) (model.Workspace, error) {
		if value.State == model.WorkspaceStateConflicted || value.State == model.WorkspaceStateRecoveryRequired {
			return value, errors.New("workspace requires conflict resolution or recovery")
		}
		if m.Busy != nil && m.Busy(cardID) {
			return value, errors.New("workspace has an active terminal or process")
		}
		if err := m.validateArchivePath(value); err != nil {
			return value, err
		}
		project, err := m.Store.Kanban.ProjectForArchivedWorkspace(value)
		if err != nil {
			return value, err
		}
		if _, err := os.Lstat(value.Path); errors.Is(err, os.ErrNotExist) {
			// A crash after Git removal but before the metadata write is safe
			// to retry. Remove only this tree's stale Git admin entry, if any.
			listing, err := m.output(ctx, project.Path, "worktree", "list", "--porcelain")
			if err != nil {
				return value, err
			}
			parent, err := filepath.EvalSymlinks(filepath.Dir(value.Path))
			if err != nil {
				return value, err
			}
			canonicalPath := filepath.Join(parent, filepath.Base(value.Path))
			for _, line := range strings.Split(listing, "\n") {
				if line == "worktree "+value.Path || line == "worktree "+canonicalPath {
					if _, err := m.Git.Run(ctx, project.Path, "worktree", "remove", value.Path); err != nil {
						return value, err
					}
				}
			}
			return value, nil
		} else if err != nil {
			return value, err
		}
		status, err := m.Git.Run(ctx, value.Path, "status", "--porcelain=v1", "-z", "--untracked-files=all")
		if err != nil {
			return value, err
		}
		if len(status.Output) != 0 {
			return value, errors.New("workspace has uncommitted changes")
		}
		branch, err := m.output(ctx, value.Path, "symbolic-ref", "--quiet", "--short", "HEAD")
		if err != nil || branch == "" {
			return value, errors.New("workspace HEAD must be on a retained branch")
		}
		if branch != value.Branch {
			// Keep the durable restore branch correct even if the daemon dies
			// between Git removal and recording the reclaimed state.
			return value, errors.New("workspace branch changed; unarchive and refresh before cleanup")
		}
		head, err := m.output(ctx, value.Path, "rev-parse", "--verify", "HEAD")
		if err != nil {
			return value, err
		}
		// No --force: Git rechecks cleanliness and refuses locked worktrees
		// and submodules. Ignored build products are removed with the tree.
		if _, err := m.Git.Run(ctx, project.Path, "worktree", "remove", value.Path); err != nil {
			return value, fmt.Errorf("remove archived worktree: %w", err)
		}
		value.Branch, value.HeadSHA = branch, head
		m.Status.Invalidate(value.Path)
		return value, nil
	})
}

func (m *Manager) validateArchivePath(value model.Workspace) error {
	// Adopted workspaces retain their original directory. Never remove a
	// registered checkout or an arbitrary path supplied by stale metadata.
	valid := false
	for _, id := range append([]string{value.CardID}, value.PreviousCardIDs...) {
		if value.Path == filepath.Join(m.Store.WorktreeRoot(), value.ProjectID, id) {
			valid = true
		}
	}
	if !valid {
		return errors.New("workspace is outside its managed worktree directory")
	}
	root, err := filepath.EvalSymlinks(m.Store.WorktreeRoot())
	if err != nil {
		return err
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(value.Path))
	if err != nil {
		return err
	}
	if parent != filepath.Join(root, value.ProjectID) {
		return errors.New("managed worktree parent is a symlink outside its root")
	}
	if info, err := os.Lstat(value.Path); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return errors.New("managed worktree path is a symlink")
	}
	checkouts, err := m.Store.Kanban.OwnedCheckouts()
	if err != nil {
		return err
	}
	canonicalPath := filepath.Join(parent, filepath.Base(value.Path))
	for _, checkout := range checkouts {
		relative, err := filepath.Rel(canonicalPath, checkout.Path)
		if err == nil && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
			return errors.New("workspace contains a registered project checkout")
		}
	}
	return nil
}
