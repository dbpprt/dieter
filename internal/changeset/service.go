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

type Service struct {
	Workspaces *workspace.Manager
	Git        gitexec.Runner
}

func New(workspaces *workspace.Manager) *Service {
	return &Service{Workspaces: workspaces, Git: workspaces.Git}
}

func (s *Service) Get(ctx context.Context, cardID string) (model.Changeset, error) {
	value, err := s.Workspaces.Refresh(ctx, cardID, false)
	if err != nil {
		return model.Changeset{}, err
	}
	comparison, mergeBase := value.BaseSHA, value.BaseSHA
	currentBase := value.CurrentBaseSHA
	if currentBase == "" {
		currentBase = value.BaseSHA
	}
	if value.Branch != "" && value.BaseBranch != "" && value.Branch != value.BaseBranch && currentBase != "" && value.HeadSHA != "" {
		if result, mergeErr := s.Git.Run(ctx, value.Path, "merge-base", currentBase, value.HeadSHA); mergeErr == nil {
			mergeBase = strings.TrimSpace(string(result.Output))
			comparison = mergeBase
		}
	}
	if comparison == "" {
		comparison = "HEAD"
	}
	files, additions, deletions, err := s.changedFiles(ctx, value, comparison)
	if err != nil {
		return model.Changeset{}, err
	}
	commits, err := s.commits(ctx, value, comparison)
	if err != nil {
		return model.Changeset{}, err
	}
	value.ChangedFiles, value.Additions, value.Deletions = len(files), additions, deletions
	_, _ = s.Workspaces.Store.UpdateWorkspaceChangesetStats(value.CardID, len(files), additions, deletions)
	return model.Changeset{
		CardID: value.CardID, Revision: value.Revision, BaseBranch: value.BaseBranch,
		BaseSHA: value.BaseSHA, CurrentBaseSHA: currentBase, MergeBaseSHA: mergeBase,
		HeadSHA: value.HeadSHA, Ahead: value.Ahead, Behind: value.Behind,
		Additions: additions, Deletions: deletions, Dirty: value.Dirty,
		Files: files, Commits: commits, CreatedAt: time.Now().UTC().Format(time.RFC3339Nano),
	}, nil
}

func (s *Service) changedFiles(ctx context.Context, value model.Workspace, comparison string) ([]model.ChangedFile, int, int, error) {
	byPath := map[string]*model.ChangedFile{}
	status, err := s.Git.Run(ctx, value.Path, "diff", "--name-status", "-z", "--find-renames", comparison, "--")
	if err != nil {
		return nil, 0, 0, err
	}
	parseNameStatus(status.Output, byPath)
	numstat, err := s.Git.Run(ctx, value.Path, "diff", "--numstat", "-z", "--find-renames", comparison, "--")
	if err != nil {
		return nil, 0, 0, err
	}
	parseNumstat(numstat.Output, byPath)
	porcelain, err := s.Git.Run(ctx, value.Path, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		return nil, 0, 0, err
	}
	parsePorcelain(value.Path, porcelain.Output, byPath)
	result := make([]model.ChangedFile, 0, len(byPath))
	additions, deletions := 0, 0
	for _, file := range byPath {
		if file.Conflicted {
			if diff, diffErr := s.Git.Run(ctx, value.Path, "diff", "--cc", "--no-color", "--", file.Path); diffErr == nil {
				file.HunkCount = strings.Count(string(diff.Output), "@@@")
			}
		}
		additions += file.Additions
		deletions += file.Deletions
		result = append(result, *file)
	}
	sort.SliceStable(result, func(i, j int) bool { return result[i].Path < result[j].Path })
	return result, additions, deletions, nil
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

func parsePorcelain(root string, raw []byte, files map[string]*model.ChangedFile) {
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
			file = &model.ChangedFile{Path: filePath, Status: statusName(xy)}
			files[filePath] = file
		}
		file.Conflicted = strings.ContainsRune(xy, 'U') || xy == "AA" || xy == "DD"
		if xy == "??" {
			file.Status = "untracked"
			if raw, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(filePath))); err == nil {
				file.Additions = countLines(raw)
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
	// An empty path with a commit produces the whole-commit patch; working-tree
	// diffs still require a concrete file.
	if commitSHA == "" || filePath != "" {
		cleaned, err := cleanPath(filePath)
		if err != nil {
			return model.FileDiff{}, err
		}
		filePath = cleaned
	}
	changes, err := s.Get(ctx, cardID)
	if err != nil {
		return model.FileDiff{}, err
	}
	if expectedRevision == "" || changes.Revision != expectedRevision {
		return model.FileDiff{}, ErrStaleRevision
	}
	workspaceValue, err := s.Workspaces.Store.Workspace(cardID)
	if err != nil {
		return model.FileDiff{}, err
	}
	args := []string{"diff", "--no-ext-diff", "--no-color", "--find-renames"}
	untracked := false
	if commitSHA == "" {
		for _, file := range changes.Files {
			if file.Path == filePath && file.Status == "untracked" {
				untracked = true
				break
			}
		}
	}
	if commitSHA != "" {
		args = append(args, commitSHA+"^!")
	} else {
		comparison := changes.MergeBaseSHA
		if comparison == "" {
			comparison = changes.BaseSHA
		}
		if comparison == "" {
			comparison = "HEAD"
		}
		args = append(args, comparison)
	}
	if filePath != "" {
		args = append(args, "--", filePath)
	}
	var patch []byte
	if untracked {
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
		CardID: cardID, Revision: changes.Revision, Path: filePath, CommitSHA: commitSHA,
		Patch: string(patch), Binary: binary, Truncated: truncated, NextOffset: next, TotalBytes: total,
	}, nil
}

func (s *Service) CommitDiff(ctx context.Context, cardID, expectedRevision, commitSHA, filePath string, offset, limit int) (model.FileDiff, error) {
	if strings.TrimSpace(commitSHA) == "" {
		return model.FileDiff{}, fmt.Errorf("commit SHA is required")
	}
	return s.FileDiff(ctx, cardID, expectedRevision, filePath, commitSHA, offset, limit)
}
