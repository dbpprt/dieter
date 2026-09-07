package changeset

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/gitexec"
	"github.com/dbpprt/dieter/internal/model"
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
	files, additions, deletions, err := s.changedFiles(ctx, value)
	if err != nil {
		return model.Changeset{}, err
	}
	if value.CardID != "" {
		value.ChangedFiles, value.Additions, value.Deletions = len(files), additions, deletions
		_, _ = s.Workspaces.Store.UpdateWorkspaceChangesetStats(value.CardID, len(files), additions, deletions)
	}
	return model.Changeset{
		CardID: value.CardID, ProjectID: value.ProjectID, Revision: value.Revision, Branch: value.Branch,
		BaseBranch: value.BaseBranch, BaseSHA: value.BaseSHA, CurrentBaseSHA: value.CurrentBaseSHA, MergeBaseSHA: value.HeadSHA,
		HeadSHA: value.HeadSHA, Ahead: value.Ahead, Behind: value.Behind,
		Additions: additions, Deletions: deletions, Dirty: value.Dirty, Conflicted: value.State == model.WorkspaceStateConflicted,
		CurrentOperationID: value.CurrentOperationID, Files: files, CreatedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}, nil
}

func (s *Service) resolveTarget(ctx context.Context, cardID, projectID string) (model.Workspace, error) {
	cardID, projectID = strings.TrimSpace(cardID), strings.TrimSpace(projectID)
	if (cardID == "") == (projectID == "") {
		return model.Workspace{}, errors.New("exactly one of card_id or project_id is required")
	}
	if projectID != "" {
		return s.Workspaces.ProjectCheckout(ctx, projectID, false)
	}
	value, err := s.Workspaces.Ensure(ctx, cardID)
	if err != nil {
		return model.Workspace{}, err
	}
	if value.Mode != model.WorkspaceModeWorktree {
		return model.Workspace{}, ErrProjectChangesRequireProject
	}
	return s.Workspaces.Refresh(ctx, cardID, false)
}

func (s *Service) changedFiles(ctx context.Context, value model.Workspace) ([]model.ChangedFile, int, int, error) {
	staged, err := s.diffSection(ctx, value.Path, true, value.HeadSHA != "")
	if err != nil {
		return nil, 0, 0, err
	}
	unstaged, err := s.diffSection(ctx, value.Path, false, value.HeadSHA != "")
	if err != nil {
		return nil, 0, 0, err
	}
	byPath := map[string]*model.ChangedFile{}
	mergeSection(byPath, staged, true)
	mergeSection(byPath, unstaged, false)
	porcelain, err := s.Git.Run(ctx, value.Path, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		return nil, 0, 0, err
	}
	parsePorcelainSections(value.Path, porcelain.Output, byPath)
	result := make([]model.ChangedFile, 0, len(byPath))
	additions, deletions := 0, 0
	for _, file := range byPath {
		if file.Conflicted {
			if diff, diffErr := s.Git.Run(ctx, value.Path, "diff", "--cc", "--no-color", "--", file.Path); diffErr == nil {
				file.HunkCount = strings.Count(string(diff.Output), "@@@")
			}
		}
		file.Additions = file.StagedAdditions + file.UnstagedAdditions
		file.Deletions = file.StagedDeletions + file.UnstagedDeletions
		if file.WorktreeStatus != "" {
			file.Status = file.WorktreeStatus
		} else if file.IndexStatus != "" {
			file.Status = file.IndexStatus
		}
		if file.Conflicted {
			file.Status = "conflicted"
		}
		additions += file.Additions
		deletions += file.Deletions
		result = append(result, *file)
	}
	sort.SliceStable(result, func(i, j int) bool { return result[i].Path < result[j].Path })
	return result, additions, deletions, nil
}

func (s *Service) diffSection(ctx context.Context, directory string, cached, hasHead bool) (map[string]*model.ChangedFile, error) {
	files := map[string]*model.ChangedFile{}
	base := []string{"diff"}
	if cached {
		base = append(base, "--cached")
	}
	statusArgs := append(append([]string{}, base...), "--name-status", "-z", "--find-renames")
	if cached && hasHead {
		statusArgs = append(statusArgs, "HEAD")
	}
	statusArgs = append(statusArgs, "--")
	status, err := s.Git.Run(ctx, directory, statusArgs...)
	if err != nil {
		return nil, err
	}
	parseNameStatus(status.Output, files)
	numstatArgs := append(append([]string{}, base...), "--numstat", "-z", "--find-renames")
	if cached && hasHead {
		numstatArgs = append(numstatArgs, "HEAD")
	}
	numstatArgs = append(numstatArgs, "--")
	numstat, err := s.Git.Run(ctx, directory, numstatArgs...)
	if err != nil {
		return nil, err
	}
	parseNumstat(numstat.Output, files)
	return files, nil
}

func mergeSection(target, section map[string]*model.ChangedFile, staged bool) {
	for path, source := range section {
		file := target[path]
		if file == nil {
			file = &model.ChangedFile{Path: path}
			target[path] = file
		}
		if file.PreviousPath == "" {
			file.PreviousPath = source.PreviousPath
		}
		file.Binary = file.Binary || source.Binary
		if staged {
			file.Staged, file.IndexStatus = true, source.Status
			file.StagedAdditions, file.StagedDeletions = source.Additions, source.Deletions
		} else {
			file.Unstaged, file.WorktreeStatus = true, source.Status
			file.UnstagedAdditions, file.UnstagedDeletions = source.Additions, source.Deletions
		}
	}
}

func parseNameStatus(raw []byte, files map[string]*model.ChangedFile) {
	fields := zeroFields(raw)
	for index := 0; index < len(fields); {
		parts := strings.SplitN(fields[index], "\t", 2)
		index++
		if len(parts) != 2 {
			continue
		}
		status, filePath := parts[0], parts[1]
		previous := ""
		if (strings.HasPrefix(status, "R") || strings.HasPrefix(status, "C")) && index < len(fields) {
			previous, filePath = filePath, fields[index]
			index++
		}
		files[filePath] = &model.ChangedFile{Path: filePath, PreviousPath: previous, Status: statusName(status)}
	}
}

func parseNumstat(raw []byte, files map[string]*model.ChangedFile) {
	fields := zeroFields(raw)
	for index := 0; index < len(fields); {
		entry := fields[index]
		index++
		parts := strings.Split(entry, "\t")
		if len(parts) < 3 {
			continue
		}
		filePath := parts[len(parts)-1]
		if filePath == "" && index+1 < len(fields) {
			index++ // previous path
			filePath = fields[index]
			index++
		}
		file := files[filePath]
		if file == nil {
			file = &model.ChangedFile{Path: filePath, Status: "modified"}
			files[filePath] = file
		}
		if parts[0] == "-" || parts[1] == "-" {
			file.Binary = true
			continue
		}
		file.Additions, _ = strconv.Atoi(parts[0])
		file.Deletions, _ = strconv.Atoi(parts[1])
	}
}

func parsePorcelainSections(root string, raw []byte, files map[string]*model.ChangedFile) {
	fields := zeroFields(raw)
	for index := 0; index < len(fields); index++ {
		entry := fields[index]
		if len(entry) < 4 {
			continue
		}
		xy, filePath := entry[:2], entry[3:]
		if (xy[0] == 'R' || xy[1] == 'R' || xy[0] == 'C' || xy[1] == 'C') && index+1 < len(fields) {
			index++
		}
		file := files[filePath]
		if file == nil {
			file = &model.ChangedFile{Path: filePath}
			files[filePath] = file
		}
		file.Conflicted = strings.ContainsRune(xy, 'U') || xy == "AA" || xy == "DD"
		if xy == "??" {
			file.Status, file.WorktreeStatus, file.Unstaged = "untracked", "untracked", true
			if raw, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(filePath))); err == nil {
				file.UnstagedAdditions = countLines(raw)
			}
			continue
		}
		if xy[0] != ' ' && xy[0] != '?' {
			file.Staged = true
			if file.IndexStatus == "" {
				file.IndexStatus = statusName(string(xy[0]))
			}
		}
		if xy[1] != ' ' && xy[1] != '?' {
			file.Unstaged = true
			if file.WorktreeStatus == "" {
				file.WorktreeStatus = statusName(string(xy[1]))
			}
		}
	}
}

func statusName(value string) string {
	if value == "" {
		return "modified"
	}
	switch value[0] {
	case 'A', '?':
		return "added"
	case 'D':
		return "deleted"
	case 'R':
		return "renamed"
	case 'C':
		return "copied"
	case 'U':
		return "conflicted"
	default:
		return "modified"
	}
}

func countLines(raw []byte) int {
	if len(raw) == 0 {
		return 0
	}
	count := strings.Count(string(raw), "\n")
	if raw[len(raw)-1] != '\n' {
		count++
	}
	return count
}

func zeroFields(raw []byte) []string {
	parts := strings.Split(string(raw), "\x00")
	result := parts[:0]
	for _, part := range parts {
		if part != "" {
			result = append(result, part)
		}
	}
	return result
}

func (s *Service) commits(ctx context.Context, value model.Workspace, comparison string) ([]model.WorkspaceCommit, error) {
	if value.HeadSHA == "" {
		return nil, nil
	}
	format := "%H%x1f%P%x1f%s%x1f%an%x1f%aI%x1e"
	result, err := s.Git.Run(ctx, value.Path, "log", "--reverse", "--format="+format, comparison+".."+value.HeadSHA, "--")
	if err != nil {
		var commandErr *gitexec.CommandError
		if errors.As(err, &commandErr) && commandErr.ExitCode == 128 {
			return nil, nil
		}
		return nil, err
	}
	var commits []model.WorkspaceCommit
	for _, record := range strings.Split(string(result.Output), "\x1e") {
		fields := strings.Split(strings.TrimSpace(record), "\x1f")
		if len(fields) < 5 || fields[0] == "" {
			continue
		}
		parent := strings.Fields(fields[1])
		item := model.WorkspaceCommit{SHA: fields[0], Subject: fields[2], Author: fields[3], AuthoredAt: fields[4]}
		if len(parent) > 0 {
			item.ParentSHA = parent[0]
		}
		stats, statsErr := s.Git.Run(ctx, value.Path, "show", "--numstat", "--format=", "--no-renames", item.SHA, "--")
		if statsErr == nil {
			for _, line := range strings.Split(string(stats.Output), "\n") {
				parts := strings.Split(line, "\t")
				if len(parts) != 3 {
					continue
				}
				if parts[0] != "-" {
					value, _ := strconv.Atoi(parts[0])
					item.Additions += value
				}
				if parts[1] != "-" {
					value, _ := strconv.Atoi(parts[1])
					item.Deletions += value
				}
				item.Files++
			}
		}
		commits = append(commits, item)
	}
	return commits, nil
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
	changes, err := s.GetTarget(ctx, cardID, projectID)
	if err != nil {
		return model.FileDiff{}, err
	}
	if expectedRevision == "" || changes.Revision != expectedRevision {
		return model.FileDiff{}, ErrStaleRevision
	}
	workspaceValue, err := s.resolveTarget(ctx, cardID, projectID)
	if err != nil {
		return model.FileDiff{}, err
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
