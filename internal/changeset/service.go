package changeset

import (
	"context"
	"errors"
	"fmt"
	"path"
	"path/filepath"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/gitexec"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/workspace"
)

const maxDiffPageBytes = 1 << 20

var ErrStaleRevision = errors.New("workspace changed; refresh the changeset")
var ErrProjectChangesRequireProject = errors.New("project-directory changes are project-scoped; request them with project_id")

const (
	DiffSectionCombined = "combined"
	DiffSectionStaged   = "staged"
	DiffSectionUnstaged = "unstaged"
)

type Service struct {
	Workspaces *workspace.Manager
	Git        gitexec.Runner
}

func New(workspaces *workspace.Manager) *Service {
	return &Service{Workspaces: workspaces, Git: workspaces.Git}
}

func (s *Service) Get(ctx context.Context, cardID string) (model.Changeset, error) {
	return s.GetTarget(ctx, cardID, "")
}

func (s *Service) GetProject(ctx context.Context, projectID string) (model.Changeset, error) {
	return s.GetTarget(ctx, "", projectID)
}

func (s *Service) GetTarget(ctx context.Context, cardID, projectID string) (model.Changeset, error) {
	value, err := s.resolveTarget(ctx, cardID, projectID)
	if err != nil {
		return model.Changeset{}, err
	}
	return s.changesForWorkspace(ctx, value, false)
}

// GetTargetFresh bypasses the short presentation cache. Mutations and selected
// file diffs use it so an external editor or agent cannot make a stale revision
// look current.
func (s *Service) GetTargetFresh(ctx context.Context, cardID, projectID string) (model.Changeset, error) {
	value, err := s.resolveTarget(ctx, cardID, projectID)
	if err != nil {
		return model.Changeset{}, err
	}
	return s.changesForWorkspace(ctx, value, true)
}

func (s *Service) resolveTarget(ctx context.Context, cardID, projectID string) (model.Workspace, error) {
	cardID, projectID = strings.TrimSpace(cardID), strings.TrimSpace(projectID)
	if (cardID == "") == (projectID == "") {
		return model.Workspace{}, errors.New("exactly one of card_id or project_id is required")
	}
	if projectID != "" {
		project, err := s.Workspaces.Store.ProjectForCheckout(projectID, store.CheckoutFromContext(ctx))
		if err != nil {
			return model.Workspace{}, err
		}
		checkoutID := ""
		for _, checkout := range project.Checkouts {
			if checkout.Path == project.Path && !checkout.Detached {
				checkoutID = checkout.ID
				break
			}
		}
		return model.Workspace{
			ProjectID: project.ID, CheckoutID: checkoutID, Mode: model.WorkspaceModeProject,
			Path: project.Path, BaseRemote: strings.TrimSpace(project.BaseRemote),
			BaseBranch: strings.TrimSpace(project.BaseBranch), State: model.WorkspaceStateReady,
		}, nil
	}
	value, err := s.Workspaces.Store.Workspace(cardID)
	if errors.Is(err, store.ErrNotFound) || (err == nil && (value.Path == "" || value.State == model.WorkspaceStateProvisioning)) {
		value, err = s.Workspaces.Ensure(ctx, cardID)
	}
	if err != nil {
		return model.Workspace{}, err
	}
	if value.Mode != model.WorkspaceModeWorktree {
		return model.Workspace{}, ErrProjectChangesRequireProject
	}
	return value, nil
}

func (s *Service) changesForWorkspace(ctx context.Context, workspaceValue model.Workspace, force bool) (model.Changeset, error) {
	status, err := s.Workspaces.Status.Read(ctx, workspaceValue.Path, force)
	if err != nil {
		return model.Changeset{}, err
	}
	workspaceValue.Branch, workspaceValue.HeadSHA, workspaceValue.UpstreamRef = status.Branch, status.HeadSHA, status.Upstream
	workspaceValue.Dirty, workspaceValue.Revision = status.Dirty, status.Revision
	if workspaceValue.BaseBranch == "" {
		workspaceValue.BaseBranch = status.Branch
	}
	if status.Upstream != "" {
		workspaceValue.Ahead, workspaceValue.Behind = status.Ahead, status.Behind
	}
	return model.Changeset{
		CardID: workspaceValue.CardID, ProjectID: workspaceValue.ProjectID, Revision: status.Revision,
		Branch: status.Branch, BaseBranch: workspaceValue.BaseBranch, BaseSHA: workspaceValue.BaseSHA,
		CurrentBaseSHA: workspaceValue.CurrentBaseSHA, MergeBaseSHA: status.HeadSHA, HeadSHA: status.HeadSHA,
		Ahead: workspaceValue.Ahead, Behind: workspaceValue.Behind, Dirty: status.Dirty, Conflicted: status.Conflicted,
		CurrentOperationID: workspaceValue.CurrentOperationID, Files: status.Files,
		CreatedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}, nil
}

func (s *Service) InvalidatePath(value string) {
	s.Workspaces.Status.Invalidate(value)
}

func cleanPath(value string) (string, error) {
	if strings.ContainsRune(value, '\x00') || strings.Contains(value, "\\") || strings.HasPrefix(value, "/") || filepath.IsAbs(value) {
		return "", errors.New("diff path must be relative")
	}
	value = path.Clean(value)
	if value == "." || value == ".." || strings.HasPrefix(value, "../") || value == ".git" || strings.HasPrefix(value, ".git/") {
		return "", errors.New("diff path is invalid")
	}
	return value, nil
}

func (s *Service) FileDiff(ctx context.Context, cardID, expectedRevision, filePath, commitSHA string, offset, limit int) (model.FileDiff, error) {
	return s.FileDiffTarget(ctx, cardID, "", expectedRevision, filePath, commitSHA, DiffSectionCombined, offset, limit)
}

func (s *Service) FileDiffTarget(ctx context.Context, cardID, projectID, expectedRevision, filePath, commitSHA, section string, offset, limit int) (model.FileDiff, error) {
	// An empty path with a commit produces the whole-commit patch; working-tree
	// diffs still require a concrete file.
	if commitSHA == "" || filePath != "" {
		cleaned, err := cleanPath(filePath)
		if err != nil {
			return model.FileDiff{}, err
		}
		filePath = cleaned
	}
	workspaceValue, err := s.resolveTarget(ctx, cardID, projectID)
	if err != nil {
		return model.FileDiff{}, err
	}
	changes, err := s.changesForWorkspace(ctx, workspaceValue, true)
	if err != nil {
		return model.FileDiff{}, err
	}
	if expectedRevision == "" || changes.Revision != expectedRevision {
		return model.FileDiff{}, ErrStaleRevision
	}
	section = strings.ToLower(strings.TrimSpace(section))
	if section == "" {
		section = DiffSectionCombined
	}
	if section != DiffSectionCombined && section != DiffSectionStaged && section != DiffSectionUnstaged {
		return model.FileDiff{}, errors.New("diff section must be combined, staged, or unstaged")
	}
	args := []string{"diff"}
	if commitSHA == "" && section == DiffSectionStaged {
		args = append(args, "--cached")
	}
	args = append(args, "--no-ext-diff", "--no-color", "--find-renames")
	untracked := false
	if commitSHA == "" {
		for _, file := range changes.Files {
			if file.Path == filePath && file.Status == "untracked" && section != DiffSectionStaged {
				untracked = true
				break
			}
		}
	}
	if commitSHA != "" {
		args = append(args, commitSHA+"^!")
	} else if section != DiffSectionUnstaged && changes.HeadSHA != "" {
		args = append(args, "HEAD")
	}
	if filePath != "" {
		args = append(args, "--", filePath)
	}
	var patch []byte
	if untracked || (commitSHA == "" && section == DiffSectionCombined && changes.HeadSHA == "") {
		result, diffErr := s.Git.Run(ctx, workspaceValue.Path, "diff", "--no-index", "--no-ext-diff", "--no-color", "--", "/dev/null", filePath)
		var commandErr *gitexec.CommandError
		if diffErr != nil && (!errors.As(diffErr, &commandErr) || commandErr.ExitCode != 1) {
			return model.FileDiff{}, diffErr
		}
		patch = result.Output
	} else {
		result, diffErr := s.Git.Run(ctx, workspaceValue.Path, args...)
		if diffErr != nil {
			return model.FileDiff{}, diffErr
		}
		patch = result.Output
	}
	total := len(patch)
	if offset < 0 || offset > len(patch) {
		return model.FileDiff{}, errors.New("diff offset is invalid")
	}
	patch = patch[offset:]
	truncated, next := false, 0
	if limit <= 0 || limit > maxDiffPageBytes {
		limit = maxDiffPageBytes
	}
	if len(patch) > limit {
		patch = patch[:limit]
		truncated, next = true, offset+len(patch)
	}
	binary := strings.Contains(string(patch), "Binary files ") || strings.IndexByte(string(patch), 0) >= 0
	return model.FileDiff{
		CardID: cardID, ProjectID: projectID, Revision: changes.Revision, Path: filePath, CommitSHA: commitSHA, Section: section,
		Patch: string(patch), Binary: binary, Truncated: truncated, NextOffset: next, TotalBytes: total,
	}, nil
}

func (s *Service) CommitDiff(ctx context.Context, cardID, expectedRevision, commitSHA, filePath string, offset, limit int) (model.FileDiff, error) {
	if strings.TrimSpace(commitSHA) == "" {
		return model.FileDiff{}, fmt.Errorf("commit SHA is required")
	}
	return s.FileDiffTarget(ctx, cardID, "", expectedRevision, filePath, commitSHA, DiffSectionCombined, offset, limit)
}
