package changeset

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/git"
	"github.com/dbpprt/dieter/internal/git/workspace"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
)

const (
	maxDiffPageBytes = 1 << 20
	// A changeset lists at most this many files; TotalFiles counts all.
	maxChangesetFiles = 5000
	// Line statistics are skipped for a tree whose diff takes longer.
	statsTimeout = 2 * time.Second
	// Untracked files are counted line by line up to these bounds.
	maxUntrackedCountBytes = 1 << 20
	maxUntrackedTotalBytes = 16 << 20
	maxBranchCommits       = 100
	// Rendered patches kept so that every page of a diff comes from one rendering.
	patchCacheBytes   = 16 << 20
	patchCacheEntries = 32
	// Line statistics and branch commits are kept for this many directories.
	derivedCacheEntries = 64
)

// ErrStaleRevision refuses an operation on the whole tree after the tree
// changed. Reads never return it.
var ErrStaleRevision = fault.New(fault.Conflict, "the workspace changed since it was reviewed; review it again")

const (
	DiffSectionCombined = "combined"
	DiffSectionStaged   = "staged"
	DiffSectionUnstaged = "unstaged"
)

type Service struct {
	Workspaces *workspace.Manager
	Git        git.Runner

	mu            sync.Mutex
	patches       []cachedPatch
	stats         map[string]cachedStats
	statsInflight map[string]*statsCall
	commits       map[string][]model.WorkspaceCommit
}

// statsCall lets concurrent reads of one revision share one numstat pass.
type statsCall struct {
	done  chan struct{}
	files map[string]fileStats
}

type patchKey struct {
	directory, path, section, commit, revision string
}

type cachedPatch struct {
	key   patchKey
	patch []byte
}

type fileStats struct {
	stagedAdditions, stagedDeletions, unstagedAdditions, unstagedDeletions int
	binary                                                                 bool
}

type cachedStats struct {
	revision string
	files    map[string]fileStats
}

func New(workspaces *workspace.Manager) *Service {
	return &Service{
		Workspaces: workspaces, Git: workspaces.Git,
		stats: map[string]cachedStats{}, statsInflight: map[string]*statsCall{}, commits: map[string][]model.WorkspaceCommit{},
	}
}

// Target is the directory one changes request reads: a conversation's own
// worktree, or a project checkout. A project-directory conversation resolves
// to its checkout; CardID keeps the conversation the request named.
type Target struct {
	Workspace model.Workspace
	CardID    string
}

// Scope is model.ChangesetScopeWorktree or model.ChangesetScopeCheckout.
func (t Target) Scope() string {
	if t.Workspace.Mode == model.WorkspaceModeWorktree {
		return model.ChangesetScopeWorktree
	}
	return model.ChangesetScopeCheckout
}

// Resolve finds the directory for a card or a project (and the checkout in
// ctx). Exactly one of cardID and projectID is set.
func (s *Service) Resolve(ctx context.Context, cardID, projectID string) (Target, error) {
	cardID, projectID = strings.TrimSpace(cardID), strings.TrimSpace(projectID)
	if (cardID == "") == (projectID == "") {
		return Target{}, fault.New(fault.Invalid, "exactly one of card_id or project_id is required")
	}
	if projectID != "" {
		value, err := s.checkout(projectID, kanban.CheckoutFromContext(ctx))
		return Target{Workspace: value}, err
	}
	value, err := s.Workspaces.Store.Workspaces.Get(cardID)
	if errors.Is(err, home.ErrNotFound) || (err == nil && (value.Path == "" || value.State == model.WorkspaceStateProvisioning)) {
		value, err = s.Workspaces.Ensure(ctx, cardID)
	}
	if err != nil {
		return Target{}, err
	}
	if value.Mode == model.WorkspaceModeWorktree {
		return Target{Workspace: value, CardID: value.CardID}, nil
	}
	checkoutID := value.CheckoutID
	if card, cardErr := s.Workspaces.Store.Kanban.ResolveCard(value.CardID); cardErr == nil && card.CheckoutID != "" {
		checkoutID = card.CheckoutID
	}
	checkout, err := s.checkout(value.ProjectID, checkoutID)
	return Target{Workspace: checkout, CardID: value.CardID}, err
}

// checkout is a project checkout's workspace, read without running Git.
func (s *Service) checkout(projectID, checkoutID string) (model.Workspace, error) {
	project, err := s.Workspaces.Store.Kanban.ProjectForCheckout(projectID, checkoutID)
	if err != nil {
		return model.Workspace{}, err
	}
	resolved := ""
	for _, checkout := range project.Checkouts {
		if checkout.Path == project.Path && !checkout.Detached {
			resolved = checkout.ID
			break
		}
	}
	return model.Workspace{
		ProjectID: project.ID, CheckoutID: resolved, Mode: model.WorkspaceModeProject,
		Path: project.Path, BaseRemote: strings.TrimSpace(project.BaseRemote),
		BaseBranch: strings.TrimSpace(project.BaseBranch), State: model.WorkspaceStateReady,
	}, nil
}

func (s *Service) GetTarget(ctx context.Context, cardID, projectID string) (model.Changeset, error) {
	target, err := s.Resolve(ctx, cardID, projectID)
	if err != nil {
		return model.Changeset{}, err
	}
	return s.Get(ctx, target, false)
}

// GetTargetFresh bypasses the short presentation cache. Operations use it so
// an external editor or agent cannot make a stale state look current.
func (s *Service) GetTargetFresh(ctx context.Context, cardID, projectID string) (model.Changeset, error) {
	target, err := s.Resolve(ctx, cardID, projectID)
	if err != nil {
		return model.Changeset{}, err
	}
	return s.Get(ctx, target, true)
}

// Get reads target's changeset.
func (s *Service) Get(ctx context.Context, target Target, force bool) (model.Changeset, error) {
	status, err := s.Workspaces.Status.Read(ctx, target.Workspace.Path, force)
	if err != nil {
		return model.Changeset{}, err
	}
	return s.Build(ctx, target, status), nil
}

// Build turns one status snapshot into target's changeset: line statistics,
// the branch's commits for a worktree, and what works in the directory now.
func (s *Service) Build(ctx context.Context, target Target, status git.StatusSnapshot) model.Changeset {
	value := target.Workspace
	if value.Mode == model.WorkspaceModeWorktree {
		if latest, err := s.Workspaces.Store.Workspaces.Get(value.CardID); err == nil {
			value.CurrentBaseSHA, value.BaseSHA, value.CurrentOperationID = latest.CurrentBaseSHA, latest.BaseSHA, latest.CurrentOperationID
			value.Ahead, value.Behind = latest.Ahead, latest.Behind
		}
	}
	activity, operationID := s.activity(value)
	baseBranch := value.BaseBranch
	if baseBranch == "" {
		baseBranch = status.Branch
	}
	ahead, behind := 0, 0
	if status.Upstream != "" {
		ahead, behind = status.Ahead, status.Behind
	} else if value.Mode == model.WorkspaceModeWorktree {
		ahead, behind = value.Ahead, value.Behind
	}
	files := append([]model.ChangedFile(nil), status.Files...)
	additions, deletions := s.applyStats(ctx, value.Path, status, files)
	changes := model.Changeset{
		CardID: target.CardID, ProjectID: value.ProjectID, Revision: status.Revision,
		Branch: status.Branch, BaseBranch: baseBranch, BaseSHA: value.BaseSHA,
		CurrentBaseSHA: value.CurrentBaseSHA, MergeBaseSHA: status.HeadSHA, HeadSHA: status.HeadSHA,
		Ahead: ahead, Behind: behind, Additions: additions, Deletions: deletions,
		Dirty: status.Dirty, Conflicted: status.Conflicted, CurrentOperationID: operationID,
		CreatedAt: time.Now().UTC().Format(time.RFC3339Nano),
		Scope:     target.Scope(), CheckoutID: value.CheckoutID, IndexFingerprint: status.IndexFingerprint,
		Activity: activity, FilesTruncated: status.Truncated, TotalFiles: len(files),
	}
	if len(files) > maxChangesetFiles {
		files, changes.FilesTruncated = files[:maxChangesetFiles], true
	}
	changes.Files = files
	if value.Mode == model.WorkspaceModeWorktree {
		changes.Commits = s.branchCommits(ctx, value, status.HeadSHA)
	}
	return changes
}

// activity reports the agent turns working in value's directory and its
// running Git operation.
func (s *Service) activity(value model.Workspace) (model.ChangesetActivity, string) {
	store := s.Workspaces.Store
	if value.Mode == model.WorkspaceModeWorktree {
		if active, err := store.Leases.CardActive(value.CardID); err == nil && active {
			return model.ChangesetActivity{AgentActive: true, AgentCardIDs: []string{value.CardID}}, value.CurrentOperationID
		}
		return model.ChangesetActivity{}, value.CurrentOperationID
	}
	var checkout []string
	if value.CheckoutID != "" {
		checkout = []string{value.CheckoutID}
	}
	activity := model.ChangesetActivity{}
	if cards, err := store.Workspaces.ProjectCheckoutTurns(value.ProjectID, "", checkout...); err == nil && len(cards) > 0 {
		activity = model.ChangesetActivity{AgentActive: true, AgentCardIDs: cards}
	}
	operationID := ""
	if operation, err := store.Workspaces.ActiveProjectGitOperation(value.ProjectID, checkout...); err == nil {
		operationID = operation.ID
	}
	return activity, operationID
}

// AgentActive reports whether an agent turn works in target's directory; a
// watcher reads it more often then.
func (s *Service) AgentActive(target Target) bool {
	activity, _ := s.activity(target.Workspace)
	return activity.AgentActive
}

func (s *Service) InvalidatePath(value string) {
	s.Workspaces.Status.Invalidate(value)
}

func cleanPath(value string) (string, error) {
	if strings.ContainsRune(value, '\x00') || strings.Contains(value, "\\") || strings.HasPrefix(value, "/") || filepath.IsAbs(value) {
		return "", fault.New(fault.Invalid, "diff path must be relative")
	}
	value = path.Clean(value)
	if value == "." || value == ".." || strings.HasPrefix(value, "../") || value == ".git" || strings.HasPrefix(value, ".git/") {
		return "", fault.New(fault.Invalid, "diff path is invalid")
	}
	return value, nil
}

// FileDiffTarget reads one file's diff, or a whole commit's with an empty
// path. It never fails because something else in the tree changed. Later
// pages pass the file revision of the first; they come from the same
// rendering, or the diff restarts at the first page when it is gone and the
// file changed.
func (s *Service) FileDiffTarget(ctx context.Context, cardID, projectID, filePath, commitSHA, section, fileRevision string, offset, limit int) (model.FileDiff, error) {
	// An empty path with a commit produces the whole-commit patch; working-tree
	// diffs still require a concrete file.
	if commitSHA == "" || filePath != "" {
		cleaned, err := cleanPath(filePath)
		if err != nil {
			return model.FileDiff{}, err
		}
		filePath = cleaned
	}
	section = strings.ToLower(strings.TrimSpace(section))
	if section == "" || commitSHA != "" {
		section = DiffSectionCombined
	}
	if section != DiffSectionCombined && section != DiffSectionStaged && section != DiffSectionUnstaged {
		return model.FileDiff{}, fault.New(fault.Invalid, "diff section must be combined, staged, or unstaged")
	}
	if offset < 0 {
		return model.FileDiff{}, fault.New(fault.Invalid, "diff offset is invalid")
	}
	target, err := s.Resolve(ctx, cardID, projectID)
	if err != nil {
		return model.FileDiff{}, err
	}
	directory := target.Workspace.Path
	result := model.FileDiff{CardID: target.CardID, ProjectID: target.Workspace.ProjectID, Path: filePath, CommitSHA: commitSHA, Section: section}
	if commitSHA != "" {
		key := patchKey{directory: directory, path: filePath, section: section, commit: commitSHA, revision: commitSHA}
		patch, err := s.patch(key, func() ([]byte, error) {
			args := []string{"show", "--format=", "--root", "--no-ext-diff", "--no-color", "--find-renames", "--end-of-options", commitSHA + "^0"}
			if filePath != "" {
				args = append(args, "--", filePath)
			}
			output, err := s.Git.Run(ctx, directory, args...)
			return output.Output, err
		})
		if err != nil {
			return model.FileDiff{}, err
		}
		result.FileRevision = commitSHA
		return page(result, patch, offset, limit)
	}
	status, err := s.Workspaces.Status.Read(ctx, directory, true)
	if err != nil {
		return model.FileDiff{}, err
	}
	var file *model.ChangedFile
	for index := range status.Files {
		if status.Files[index].Path == filePath {
			file = &status.Files[index]
			break
		}
	}
	current := "clean:" + status.HeadSHA
	if file != nil {
		current = file.Revision
	}
	result.Revision, result.FileRevision = status.Revision, current
	if offset > 0 && fileRevision != "" && fileRevision != current {
		// Finish the pages of the rendering the reader started, if it is kept.
		if patch, ok := s.cachedPatch(patchKey{directory: directory, path: filePath, section: section, revision: fileRevision}); ok {
			result.FileRevision = fileRevision
			return page(result, patch, offset, limit)
		}
		offset, result.Restarted = 0, true
	}
	key := patchKey{directory: directory, path: filePath, section: section, revision: current}
	patch, err := s.patch(key, func() ([]byte, error) {
		return s.renderWorkingDiff(ctx, directory, status, file, filePath, section)
	})
	if err != nil {
		return model.FileDiff{}, err
	}
	return page(result, patch, offset, limit)
}

func (s *Service) renderWorkingDiff(ctx context.Context, directory string, status git.StatusSnapshot, file *model.ChangedFile, filePath, section string) ([]byte, error) {
	if file == nil {
		return nil, nil
	}
	untracked := file.Status == "untracked" && section != DiffSectionStaged
	if untracked || (section == DiffSectionCombined && status.HeadSHA == "") {
		result, err := s.Git.Run(ctx, directory, "diff", "--no-index", "--no-ext-diff", "--no-color", "--", "/dev/null", filePath)
		var commandErr *git.CommandError
		if err != nil && (!errors.As(err, &commandErr) || commandErr.ExitCode != 1) {
			return nil, err
		}
		return result.Output, nil
	}
	args := []string{"diff"}
	if section == DiffSectionStaged {
		args = append(args, "--cached")
	}
	args = append(args, "--no-ext-diff", "--no-color", "--find-renames")
	if section != DiffSectionUnstaged && status.HeadSHA != "" {
		args = append(args, "HEAD")
	}
	args = append(args, "--", filePath)
	// A staged rename shows as one renamed file when both of its paths are given.
	if file.PreviousPath != "" && section != DiffSectionUnstaged {
		args = append(args, file.PreviousPath)
	}
	result, err := s.Git.Run(ctx, directory, append([]string{"--literal-pathspecs"}, args...)...)
	if err != nil {
		return nil, err
	}
	return result.Output, nil
}

func page(result model.FileDiff, patch []byte, offset, limit int) (model.FileDiff, error) {
	total := len(patch)
	if offset > total {
		return model.FileDiff{}, fault.New(fault.Invalid, "diff offset is invalid")
	}
	part := patch[offset:]
	if limit <= 0 || limit > maxDiffPageBytes {
		limit = maxDiffPageBytes
	}
	if len(part) > limit {
		part = part[:limit]
		result.Truncated, result.NextOffset = true, offset+len(part)
	}
	result.Patch, result.TotalBytes = string(part), total
	result.Binary = bytes.Contains(part, []byte("Binary files ")) || bytes.IndexByte(part, 0) >= 0
	return result, nil
}

// patch returns a cached rendering or renders and keeps it, most recently
// used last, within the cache's entry and byte bounds.
func (s *Service) patch(key patchKey, render func() ([]byte, error)) ([]byte, error) {
	if cached, ok := s.cachedPatch(key); ok {
		return cached, nil
	}
	patch, err := render()
	if err != nil {
		return nil, err
	}
	if len(patch) > patchCacheBytes/2 {
		return patch, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.patches = append(s.patches, cachedPatch{key: key, patch: patch})
	total := 0
	for _, entry := range s.patches {
		total += len(entry.patch)
	}
	for len(s.patches) > patchCacheEntries || total > patchCacheBytes {
		total -= len(s.patches[0].patch)
		s.patches = s.patches[1:]
	}
	return patch, nil
}

func (s *Service) cachedPatch(key patchKey) ([]byte, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for index, entry := range s.patches {
		if entry.key == key {
			s.patches = append(append(s.patches[:index:index], s.patches[index+1:]...), entry)
			return entry.patch, true
		}
	}
	return nil, false
}

// applyStats fills each file's line counts from one staged and one unstaged
// numstat, cached by the tree's revision, and returns the totals. A tree too
// large to diff within statsTimeout gets no counts rather than a slow list.
func (s *Service) applyStats(ctx context.Context, directory string, status git.StatusSnapshot, files []model.ChangedFile) (int, int) {
	if len(files) == 0 || len(files) > maxChangesetFiles || status.Truncated {
		return 0, 0
	}
	counted := s.statsFor(ctx, directory, status, files)
	additions, deletions := 0, 0
	for index := range files {
		stats, ok := counted[files[index].Path]
		if !ok {
			continue
		}
		file := &files[index]
		file.StagedAdditions, file.StagedDeletions = stats.stagedAdditions, stats.stagedDeletions
		file.UnstagedAdditions, file.UnstagedDeletions = stats.unstagedAdditions, stats.unstagedDeletions
		file.Additions = stats.stagedAdditions + stats.unstagedAdditions
		file.Deletions = stats.stagedDeletions + stats.unstagedDeletions
		file.Binary = stats.binary
		additions += file.Additions
		deletions += file.Deletions
	}
	return additions, deletions
}

func (s *Service) statsFor(ctx context.Context, directory string, status git.StatusSnapshot, files []model.ChangedFile) map[string]fileStats {
	key := directory + "\x00" + status.Revision
	s.mu.Lock()
	if cached, ok := s.stats[directory]; ok && cached.revision == status.Revision {
		s.mu.Unlock()
		return cached.files
	}
	if call := s.statsInflight[key]; call != nil {
		s.mu.Unlock()
		select {
		case <-call.done:
			return call.files
		case <-ctx.Done():
			return nil
		}
	}
	call := &statsCall{done: make(chan struct{})}
	s.statsInflight[key] = call
	s.mu.Unlock()
	call.files = s.readStats(ctx, directory, status, files)
	s.mu.Lock()
	delete(s.statsInflight, key)
	if len(s.stats) >= derivedCacheEntries {
		clear(s.stats)
	}
	s.stats[directory] = cachedStats{revision: status.Revision, files: call.files}
	s.mu.Unlock()
	close(call.done)
	return call.files
}

func (s *Service) readStats(ctx context.Context, directory string, status git.StatusSnapshot, files []model.ChangedFile) map[string]fileStats {
	ctx, cancel := context.WithTimeout(ctx, statsTimeout)
	defer cancel()
	result := map[string]fileStats{}
	staged := []string{"diff", "--cached", "--numstat", "-z", "--no-ext-diff", "--find-renames"}
	if status.HeadSHA != "" {
		staged = append(staged, "HEAD")
	}
	for index, args := range [][]string{staged, {"diff", "--numstat", "-z", "--no-ext-diff"}} {
		output, err := s.Git.Run(ctx, directory, args...)
		if err != nil || output.Truncated {
			return map[string]fileStats{}
		}
		for filePath, counts := range parseNumstat(output.Output) {
			stats := result[filePath]
			if index == 0 {
				stats.stagedAdditions, stats.stagedDeletions = counts[0], counts[1]
			} else {
				stats.unstagedAdditions, stats.unstagedDeletions = counts[0], counts[1]
			}
			stats.binary = stats.binary || counts[0] < 0
			if counts[0] < 0 {
				stats.stagedAdditions, stats.stagedDeletions = max(stats.stagedAdditions, 0), max(stats.stagedDeletions, 0)
				stats.unstagedAdditions, stats.unstagedDeletions = max(stats.unstagedAdditions, 0), max(stats.unstagedDeletions, 0)
			}
			result[filePath] = stats
		}
	}
	budget := maxUntrackedTotalBytes
	for _, file := range files {
		if file.Status != "untracked" || budget <= 0 {
			continue
		}
		full := filepath.Join(directory, filepath.FromSlash(file.Path))
		info, err := os.Lstat(full)
		if err != nil || !info.Mode().IsRegular() || info.Size() > maxUntrackedCountBytes {
			continue
		}
		content, err := os.ReadFile(full)
		if err != nil {
			continue
		}
		budget -= len(content)
		stats := result[file.Path]
		if bytes.IndexByte(content, 0) >= 0 {
			stats.binary = true
		} else {
			stats.unstagedAdditions = bytes.Count(content, []byte{'\n'})
			if len(content) > 0 && content[len(content)-1] != '\n' {
				stats.unstagedAdditions++
			}
		}
		result[file.Path] = stats
	}
	return result
}

// parseNumstat reads `git diff --numstat -z`: additions and deletions by
// path, -1 for a binary file. A rename is "A\tD\t" then its old and new paths.
func parseNumstat(raw []byte) map[string][2]int {
	result := map[string][2]int{}
	fields := strings.Split(string(raw), "\x00")
	for index := 0; index < len(fields); index++ {
		parts := strings.SplitN(fields[index], "\t", 3)
		if len(parts) != 3 {
			continue
		}
		additions, deletions := numstatCount(parts[0]), numstatCount(parts[1])
		filePath := parts[2]
		if filePath == "" && index+2 < len(fields) {
			filePath = fields[index+2]
			index += 2
		}
		if filePath != "" {
			result[filePath] = [2]int{additions, deletions}
		}
	}
	return result
}

func numstatCount(value string) int {
	if value == "-" {
		return -1
	}
	count, err := strconv.Atoi(value)
	if err != nil {
		return 0
	}
	return count
}

// branchCommits lists a worktree's commits since it left its base, newest
// first, cached by the base and HEAD.
func (s *Service) branchCommits(ctx context.Context, value model.Workspace, head string) []model.WorkspaceCommit {
	base := value.CurrentBaseSHA
	if base == "" {
		base = value.BaseSHA
	}
	if head == "" {
		return nil
	}
	key := value.Path + "\x00" + base + "\x00" + head
	s.mu.Lock()
	cached, ok := s.commits[key]
	s.mu.Unlock()
	if ok {
		return cached
	}
	ctx, cancel := context.WithTimeout(ctx, statsTimeout)
	defer cancel()
	commits, err := s.readCommits(ctx, value.Path, base, head, value.BaseSHA == "")
	if err != nil {
		return nil
	}
	s.mu.Lock()
	if len(s.commits) >= derivedCacheEntries {
		clear(s.commits)
	}
	s.commits[key] = commits
	s.mu.Unlock()
	return commits
}

func (s *Service) readCommits(ctx context.Context, directory, base, head string, unbornOrigin bool) ([]model.WorkspaceCommit, error) {
	rangeRef := head
	if base != "" {
		mergeBase, err := s.Git.Run(ctx, directory, "merge-base", base, head)
		if err != nil {
			var command *git.CommandError
			if !unbornOrigin || !errors.As(err, &command) || command.ExitCode != 1 {
				return nil, err
			}
		} else {
			from := strings.TrimSpace(string(mergeBase.Output))
			if from == "" || from == head {
				return []model.WorkspaceCommit{}, nil
			}
			rangeRef = from + ".." + head
		}
	}
	output, err := s.Git.Run(ctx, directory, "log", "--no-color", "--numstat", "--max-count="+strconv.Itoa(maxBranchCommits),
		"--format=%x1e%H%x1f%P%x1f%an%x1f%aI%x1f%s", rangeRef)
	if err != nil {
		return nil, err
	}
	var commits []model.WorkspaceCommit
	for _, record := range strings.Split(string(output.Output), "\x1e") {
		header, body, _ := strings.Cut(record, "\n")
		fields := strings.Split(header, "\x1f")
		if len(fields) != 5 || fields[0] == "" {
			continue
		}
		commit := model.WorkspaceCommit{SHA: fields[0], Author: fields[2], AuthoredAt: fields[3], Subject: fields[4]}
		if parents := strings.Fields(fields[1]); len(parents) > 0 {
			commit.ParentSHA = parents[0]
		}
		for _, line := range strings.Split(body, "\n") {
			parts := strings.SplitN(line, "\t", 3)
			if len(parts) != 3 {
				continue
			}
			commit.Files++
			commit.Additions += max(numstatCount(parts[0]), 0)
			commit.Deletions += max(numstatCount(parts[1]), 0)
		}
		commits = append(commits, commit)
	}
	return commits, nil
}
