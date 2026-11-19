package operations

import (
	"archive/tar"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/git"
	"github.com/dbpprt/dieter/internal/git/changeset"
	"github.com/dbpprt/dieter/internal/git/workspace"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/leases"
	"github.com/dbpprt/dieter/internal/store/workspaces"
)

var (
	ErrWaitingForResolution = fault.New(fault.FailedPrecondition, "Git operation is waiting for conflict resolution")
	ErrWorkspaceBusy        = fault.New(fault.FailedPrecondition, "workspace is busy")
)

type Request struct {
	CardID           string
	ProjectID        string
	Kind             string
	ExpectedRevision string
	Parameters       map[string]string
	// ExpectedFiles and ExpectedIndex are the preconditions of file-scoped
	// operations and of commits of the index (see checkPreconditions).
	ExpectedFiles map[string]string
	ExpectedIndex string
}

// pathChunk bounds the paths passed to one Git command.
const pathChunk = 200

type Manager struct {
	Store      *store.Store
	Workspaces *workspace.Manager
	Changesets *changeset.Service
	Git        git.Runner
	SCM        git.SCMProvider
	Log        *slog.Logger
	Busy       func(string) bool
	BusyPath   func(string) bool

	mu      sync.Mutex
	active  map[string]context.CancelFunc
	changed map[string]chan struct{}
}

func New(data *store.Store, workspaces *workspace.Manager, logger *slog.Logger) *Manager {
	if logger == nil {
		logger = slog.Default()
	}
	return &Manager{
		Store: data, Workspaces: workspaces, Changesets: changeset.New(workspaces), Git: workspaces.Git,
		SCM: git.NewGitHub(), Log: logger, active: map[string]context.CancelFunc{}, changed: map[string]chan struct{}{},
	}
}

func (m *Manager) Start(ctx context.Context, request Request) (model.GitOperation, error) {
	request.CardID, request.ProjectID = strings.TrimSpace(request.CardID), strings.TrimSpace(request.ProjectID)
	if (request.CardID == "") == (request.ProjectID == "") || strings.TrimSpace(request.Kind) == "" {
		return model.GitOperation{}, fault.New(fault.Invalid, "exactly one of card ID or project ID and a Git operation kind are required")
	}
	if !supportedOperation(request.Kind) {
		return model.GitOperation{}, fault.Invalidf("unsupported Git operation %q", request.Kind)
	}
	if ctx == nil {
		ctx = context.Background()
	}
	workspaceValue, requestedBy, err := m.resolveTarget(ctx, request.CardID, request.ProjectID)
	if err != nil {
		return model.GitOperation{}, err
	}
	if workspaceValue.CardID != "" {
		if active, leaseErr := m.Store.Leases.CardActive(workspaceValue.CardID); leaseErr != nil {
			return model.GitOperation{}, leaseErr
		} else if active {
			return model.GitOperation{}, leases.ErrCardActive
		}
	}
	if workspaceValue.Mode == model.WorkspaceModeProject && !projectCheckoutOperation(request.Kind) {
		return model.GitOperation{}, fault.Invalidf("Git operation %q is not available in a project checkout", request.Kind)
	}
	if err := admitPreconditions(request); err != nil {
		return model.GitOperation{}, err
	}
	if m.Busy != nil && workspaceValue.CardID != "" && m.Busy(workspaceValue.CardID) {
		return model.GitOperation{}, fmt.Errorf("%w: a terminal or process is running in it", ErrWorkspaceBusy)
	}
	if m.BusyPath != nil && m.BusyPath(workspaceValue.Path) {
		return model.GitOperation{}, fmt.Errorf("%w: a terminal or process is running in the checkout", ErrWorkspaceBusy)
	}
	if (workspaceValue.Mode == model.WorkspaceModeProject && projectOperationRequiresIdle(request.Kind)) || request.Kind == "merge_local" {
		if active, activeErr := m.Store.Workspaces.ProjectCheckoutActive(workspaceValue.ProjectID, workspaceValue.CardID, workspaceValue.CheckoutID); activeErr != nil {
			return model.GitOperation{}, activeErr
		} else if active {
			return model.GitOperation{}, fmt.Errorf("%w: an agent is working in this checkout; wait for it to finish or stop it", ErrWorkspaceBusy)
		}
	}
	release, err := m.lockTarget(ctx, workspaceValue)
	if err != nil {
		return model.GitOperation{}, err
	}
	defer release()
	workspaceValue, _, err = m.resolveTarget(ctx, request.CardID, request.ProjectID)
	if err != nil {
		return model.GitOperation{}, err
	}
	if workspaceValue.Mode == model.WorkspaceModeProject {
		if current, currentErr := m.Store.Workspaces.ActiveProjectGitOperation(workspaceValue.ProjectID, workspaceValue.CheckoutID); currentErr == nil {
			return model.GitOperation{}, fault.Invalidf("project checkout already has active Git operation %s", current.ID)
		} else if !errors.Is(currentErr, home.ErrNotFound) {
			return model.GitOperation{}, currentErr
		}
	} else if workspaceValue.CurrentOperationID != "" {
		if current, currentErr := m.Store.Workspaces.GitOperation(workspaceValue.CurrentOperationID); currentErr == nil &&
			(current.Status == model.GitOperationQueued || current.Status == model.GitOperationRunning || current.Status == model.GitOperationWaitingForResolution) {
			resolvingConflict := current.Status == model.GitOperationWaitingForResolution &&
				(request.Kind == "abort_conflict" || request.Kind == "continue_conflict")
			if !resolvingConflict {
				return model.GitOperation{}, fault.New(fault.Invalid, "workspace already has an active Git operation")
			}
			if request.Parameters == nil {
				request.Parameters = map[string]string{}
			}
			request.Parameters["conflicted_operation_id"] = current.ID
		}
	}
	var operation model.GitOperation
	if workspaceValue.CardID == "" {
		operation, err = m.Store.Workspaces.CreateProjectGitOperation(workspaceValue.ProjectID, request.Kind, request.ExpectedRevision)
	} else {
		operation, err = m.Store.Workspaces.CreateGitOperation(workspaceValue.CardID, request.Kind, request.ExpectedRevision)
	}
	if err != nil {
		return model.GitOperation{}, err
	}
	operation.CheckoutID = workspaceValue.CheckoutID
	operation.Parameters = cloneMap(request.Parameters)
	operation.ExpectedFiles, operation.ExpectedIndex = cloneMap(request.ExpectedFiles), strings.TrimSpace(request.ExpectedIndex)
	operation.RequestedByCardID = requestedBy
	operation.ExpectedBaseSHA, operation.ExpectedHeadSHA = workspaceValue.CurrentBaseSHA, workspaceValue.HeadSHA
	if request.Kind == "merge_local" && workspaceValue.BaseBranch != "" {
		if project, projectErr := m.Store.Kanban.ProjectForCheckout(workspaceValue.ProjectID, workspaceValue.CheckoutID); projectErr == nil {
			if localBase, baseErr := m.gitOutput(ctx, project.Path, "rev-parse", "--verify", workspaceValue.BaseBranch+"^{commit}"); baseErr == nil {
				operation.ExpectedBaseSHA = localBase
			}
		}
	}
	operation, err = m.Store.Workspaces.SaveGitOperation(operation)
	if err != nil {
		return model.GitOperation{}, err
	}
	if workspaceValue.CardID != "" {
		workspaceValue.CurrentOperationID = operation.ID
		if _, err := m.Store.Workspaces.Save(workspaceValue); err != nil {
			return model.GitOperation{}, err
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	m.mu.Lock()
	m.active[operation.ID] = cancel
	m.changed[operation.ID] = make(chan struct{})
	m.mu.Unlock()
	go m.run(ctx, operation)
	return operation, nil
}

func supportedOperation(value string) bool {
	switch value {
	case "stage", "unstage", "discard_changes", "commit", "update", "abort_conflict", "continue_conflict", "validate", "merge_local", "push",
		"cleanup", "discard", "adopt", "create_pr", "refresh_pr", "merge_pr":
		return true
	default:
		return false
	}
}

func projectCheckoutOperation(value string) bool {
	switch value {
	case "stage", "unstage", "discard_changes", "commit", "update", "validate", "push":
		return true
	default:
		return false
	}
}

func projectOperationRequiresIdle(value string) bool {
	switch value {
	case "discard_changes", "update":
		return true
	default:
		return false
	}
}

// admitPreconditions requires the precondition that matches what an
// operation acts on: the reviewed files for stage, unstage and
// discard_changes, the reviewed index for a commit of staged changes, the
// whole tree's revision for a commit of every change.
func admitPreconditions(request Request) error {
	switch request.Kind {
	case "stage", "unstage", "discard_changes":
		if len(request.ExpectedFiles) == 0 {
			return fault.Invalidf("%s needs the reviewed files and their revisions", request.Kind)
		}
		for filePath := range request.ExpectedFiles {
			if _, err := relativePath(filePath); err != nil {
				return err
			}
		}
	case "commit":
		if request.Parameters["stage_all"] == "true" {
			if strings.TrimSpace(request.ExpectedRevision) == "" {
				return fault.New(fault.Invalid, "committing every change needs the reviewed revision")
			}
		} else if strings.TrimSpace(request.ExpectedIndex) == "" {
			return fault.New(fault.Invalid, "a commit needs the reviewed staged changes")
		}
	}
	return nil
}

// checkPreconditions fails an operation only when what it acts on changed
// since it was reviewed: writes elsewhere in the tree do not matter to a
// file-scoped operation or to a commit of the index.
func checkPreconditions(operation model.GitOperation, changes model.Changeset) error {
	switch operation.Kind {
	case "stage", "unstage", "discard_changes":
		if changes.FilesTruncated {
			return git.ErrTooManyChanges
		}
		current := make(map[string]string, len(changes.Files))
		for _, file := range changes.Files {
			current[file.Path] = file.Revision
		}
		var changed []string
		for filePath, revision := range operation.ExpectedFiles {
			if current[filePath] != revision {
				changed = append(changed, filePath)
			}
		}
		if len(changed) > 0 {
			return staleFiles(changed)
		}
	case "commit":
		if operation.Parameters["stage_all"] == "true" {
			if operation.ExpectedRevision != changes.Revision {
				return changeset.ErrStaleRevision
			}
		} else if operation.ExpectedIndex != changes.IndexFingerprint {
			return fault.New(fault.Conflict, "the staged changes changed since they were reviewed; review them again")
		}
	default:
		if operation.ExpectedRevision != "" && changes.Revision != operation.ExpectedRevision {
			return changeset.ErrStaleRevision
		}
	}
	return nil
}

func staleFiles(paths []string) error {
	sort.Strings(paths)
	if len(paths) == 1 {
		return fault.New(fault.Conflict, paths[0]+" changed since it was reviewed; review it again")
	}
	shown := paths
	if len(shown) > 3 {
		shown = shown[:3]
	}
	names := strings.Join(shown, ", ")
	if extra := len(paths) - len(shown); extra > 0 {
		names += fmt.Sprintf(" and %d more", extra)
	}
	return fault.New(fault.Conflict, names+" changed since they were reviewed; review them again")
}

// targetPaths are exactly the reviewed files a file-scoped operation acts on,
// within its optional path parameter, plus the old path of a staged rename.
func targetPaths(operation model.GitOperation, changes model.Changeset) ([]string, error) {
	scope, err := operationPath(operation.Parameters, false)
	if err != nil {
		return nil, err
	}
	previous := make(map[string]string, len(changes.Files))
	for _, file := range changes.Files {
		previous[file.Path] = file.PreviousPath
	}
	set := map[string]bool{}
	for filePath := range operation.ExpectedFiles {
		clean, err := relativePath(filePath)
		if err != nil {
			return nil, err
		}
		if scope != "" && clean != scope && !strings.HasPrefix(clean, scope+"/") {
			return nil, fault.Invalidf("%s is outside %s", clean, scope)
		}
		set[clean] = true
		if old := previous[clean]; old != "" {
			set[old] = true
		}
	}
	paths := make([]string, 0, len(set))
	for filePath := range set {
		paths = append(paths, filePath)
	}
	sort.Strings(paths)
	return paths, nil
}

// runPaths runs args followed by "--" and the paths, at most pathChunk at a
// time, and concatenates the outputs.
func (m *Manager) runPaths(ctx context.Context, directory string, args []string, paths []string) ([]byte, error) {
	var output []byte
	for start := 0; start < len(paths); start += pathChunk {
		end := min(start+pathChunk, len(paths))
		command := append(append(append([]string{"--literal-pathspecs"}, args...), "--"), paths[start:end]...)
		result, err := m.Git.Run(ctx, directory, command...)
		if err != nil {
			return nil, err
		}
		output = append(output, result.Output...)
	}
	return output, nil
}

func describePaths(verb string, paths []string) string {
	if len(paths) == 1 {
		return verb + " " + paths[0]
	}
	return fmt.Sprintf("%s %d files", verb, len(paths))
}

func cloneMap(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	result := make(map[string]string, len(values))
	for key, value := range values {
		result[key] = value
	}
	return result
}

// resolveTarget returns the directory an operation acts on. A
// project-directory conversation acts on its checkout; requestedBy is then
// that conversation.
func (m *Manager) resolveTarget(ctx context.Context, cardID, projectID string) (value model.Workspace, requestedBy string, err error) {
	if projectID != "" {
		value, err = m.Workspaces.ProjectCheckout(ctx, projectID, false)
		return value, "", err
	}
	value, err = m.Workspaces.Ensure(ctx, cardID)
	if err != nil || value.Mode != model.WorkspaceModeProject {
		return value, "", err
	}
	checkoutID := value.CheckoutID
	if card, cardErr := m.Store.Kanban.ResolveCard(value.CardID); cardErr == nil && card.CheckoutID != "" {
		checkoutID = card.CheckoutID
	}
	checkout, err := m.Workspaces.ProjectCheckout(kanban.WithCheckout(ctx, checkoutID), value.ProjectID, false)
	return checkout, value.CardID, err
}

func (m *Manager) lockTarget(ctx context.Context, value model.Workspace) (func(), error) {
	if value.Mode == model.WorkspaceModeProject {
		return m.Workspaces.LockCheckout(kanban.WithCheckout(ctx, value.CheckoutID), value.ProjectID)
	}
	return m.Workspaces.LockWorkspace(ctx, value.CardID)
}

func (m *Manager) run(ctx context.Context, operation model.GitOperation) {
	ctx = kanban.WithCheckout(ctx, operation.CheckoutID)
	operation.Status, operation.StartedAt = model.GitOperationRunning, now()
	operation, _ = m.Store.Workspaces.SaveGitOperation(operation)
	m.appendLog(&operation, "operation started: "+operation.Kind)
	m.notify(operation.ID)

	workspaceValue, _, err := m.resolveTarget(ctx, operation.CardID, func() string {
		if operation.CardID == "" {
			return operation.ProjectID
		}
		return ""
	}())
	if err == nil {
		var release func()
		release, err = m.lockTarget(ctx, workspaceValue)
		if err == nil {
			defer release()
			err = m.execute(ctx, &operation, workspaceValue)
			m.Changesets.InvalidatePath(workspaceValue.Path)
		}
	}
	switch {
	case errors.Is(err, ErrWaitingForResolution):
		operation.Status = model.GitOperationWaitingForResolution
		operation.Error = ""
		m.appendLog(&operation, "operation is waiting for conflict resolution")
	case errors.Is(err, context.Canceled):
		operation.Status, operation.Error, operation.FinishedAt = model.GitOperationCanceled, "operation canceled", now()
		m.appendLog(&operation, operation.Error)
	case err != nil:
		operation.Status, operation.Error, operation.FinishedAt = model.GitOperationFailed, git.Redact(err.Error()), now()
		m.appendLog(&operation, "operation failed: "+operation.Error)
	default:
		operation.Status, operation.FinishedAt = model.GitOperationSucceeded, now()
		m.appendLog(&operation, "operation completed")
	}
	if operation.Status != model.GitOperationWaitingForResolution && operation.CardID != "" {
		if latest, workspaceErr := m.Store.Workspaces.Get(operation.CardID); workspaceErr == nil && latest.CurrentOperationID == operation.ID {
			latest.CurrentOperationID = ""
			_, _ = m.Store.Workspaces.Save(latest)
		}
	}
	operation, _ = m.Store.Workspaces.SaveGitOperation(operation)
	m.mu.Lock()
	delete(m.active, operation.ID)
	m.mu.Unlock()
	m.notify(operation.ID)
}

func (m *Manager) execute(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	changes, err := m.Changesets.GetTargetFresh(ctx, operation.CardID, func() string {
		if operation.CardID == "" {
			return operation.ProjectID
		}
		return ""
	}())
	if err != nil {
		return err
	}
	if err := checkPreconditions(*operation, changes); err != nil {
		return err
	}
	var paths []string
	if operation.Kind == "stage" || operation.Kind == "unstage" || operation.Kind == "discard_changes" {
		if paths, err = targetPaths(*operation, changes); err != nil {
			return err
		}
	}
	// Start and execution are intentionally separate durable steps. Refresh the
	// branch and HEAD under the operation lock so a push/update never acts on the
	// short presentation snapshot captured when the request was admitted.
	value.Branch, value.HeadSHA = changes.Branch, changes.HeadSHA
	value.Ahead, value.Behind, value.Dirty = changes.Ahead, changes.Behind, changes.Dirty
	switch operation.Kind {
	case "stage":
		return m.stage(ctx, operation, value, paths)
	case "unstage":
		return m.unstage(ctx, operation, value, paths)
	case "discard_changes":
		return m.discardChanges(ctx, operation, value, paths)
	case "commit":
		return m.commit(ctx, operation, value)
	case "update":
		return m.update(ctx, operation, value)
	case "abort_conflict":
		return m.abortConflict(ctx, operation, value)
	case "continue_conflict":
		return m.continueConflict(ctx, operation, value)
	case "validate":
		return m.validate(ctx, operation, value.Path, value.ProjectID)
	case "merge_local":
		return m.mergeLocal(ctx, operation, value)
	case "push":
		return m.push(ctx, operation, value)
	case "cleanup":
		return m.cleanup(ctx, operation, value, false)
	case "discard":
		return m.cleanup(ctx, operation, value, true)
	case "adopt":
		return m.adopt(ctx, operation, value)
	case "create_pr":
		return m.createPullRequest(ctx, operation, value)
	case "refresh_pr":
		return m.refreshPullRequest(ctx, operation, value)
	case "merge_pr":
		return m.mergePullRequest(ctx, operation, value)
	default:
		return fault.Invalidf("unsupported Git operation %q", operation.Kind)
	}
}

func (m *Manager) appendLog(operation *model.GitOperation, message string) {
	sequence, err := m.Store.Workspaces.AppendGitOperationLog(operation.ID, message)
	if err == nil {
		operation.Sequence = sequence
	}
}

func (m *Manager) step(operation *model.GitOperation, name string) {
	operation.CompletedSteps = append(operation.CompletedSteps, name)
	m.appendLog(operation, name)
	*operation, _ = m.Store.Workspaces.SaveGitOperation(*operation)
	m.notify(operation.ID)
}

func operationPath(parameters map[string]string, required bool) (string, error) {
	value := strings.TrimSpace(parameters["path"])
	if value == "" {
		if required {
			return "", fault.New(fault.Invalid, "operation requires a checkout-relative path")
		}
		return "", nil
	}
	return relativePath(value)
}

func relativePath(value string) (string, error) {
	if strings.ContainsRune(value, '\x00') || strings.Contains(value, "\\") || strings.HasPrefix(value, "/") || filepath.IsAbs(value) {
		return "", fault.New(fault.Invalid, "checkout path must be relative")
	}
	value = path.Clean(value)
	if value == "." || value == ".." || strings.HasPrefix(value, "../") || value == ".git" || strings.HasPrefix(value, ".git/") {
		return "", fault.New(fault.Invalid, "checkout path is invalid")
	}
	return value, nil
}

func (m *Manager) stage(ctx context.Context, operation *model.GitOperation, value model.Workspace, paths []string) error {
	if _, err := m.runPaths(ctx, value.Path, []string{"add", "-A"}, paths); err != nil {
		return err
	}
	m.step(operation, describePaths("staged", paths))
	m.refreshTarget(ctx, value)
	return nil
}

func (m *Manager) unstage(ctx context.Context, operation *model.GitOperation, value model.Workspace, paths []string) error {
	args := []string{"reset", "-q", "HEAD"}
	if value.HeadSHA == "" {
		// An unborn repository has no HEAD for reset to copy into the index.
		// Removing the cached entry is the equivalent unstage operation; force
		// is required when the working copy changed after it was staged.
		args = []string{"rm", "-r", "--cached", "-q", "-f", "--ignore-unmatch"}
	}
	if _, err := m.runPaths(ctx, value.Path, args, paths); err != nil {
		return err
	}
	m.step(operation, describePaths("unstaged", paths))
	m.refreshTarget(ctx, value)
	return nil
}

// discardChanges restores exactly the reviewed files to HEAD after saving a
// recovery copy. Files absent from HEAD are untracked there and removed;
// ignored files and files nobody reviewed stay.
func (m *Manager) discardChanges(ctx context.Context, operation *model.GitOperation, value model.Workspace, paths []string) error {
	if err := m.createRecovery(ctx, operation, value); err != nil {
		return err
	}
	var headFiles []string
	if value.HeadSHA != "" {
		listed, err := m.runPaths(ctx, value.Path, []string{"ls-tree", "-r", "--name-only", "-z", "HEAD"}, paths)
		if err != nil {
			return err
		}
		headFiles = zeroFields(listed)
		if _, err := m.runPaths(ctx, value.Path, []string{"reset", "-q", "HEAD"}, paths); err != nil {
			return err
		}
	} else if _, err := m.runPaths(ctx, value.Path, []string{"rm", "-r", "--cached", "--ignore-unmatch", "-q", "-f"}, paths); err != nil {
		return err
	}
	if len(headFiles) > 0 {
		if _, err := m.runPaths(ctx, value.Path, []string{"restore", "--source=HEAD", "--worktree"}, headFiles); err != nil {
			return err
		}
	}
	// After the reset, anything left that HEAD lacks is untracked.
	untracked, err := m.runPaths(ctx, value.Path, []string{"ls-files", "--others", "--exclude-standard", "-z"}, paths)
	if err != nil {
		return err
	}
	for _, relative := range zeroFields(untracked) {
		if err := removeUntracked(value.Path, relative); err != nil {
			return err
		}
	}
	m.step(operation, describePaths("discarded", paths)+" after creating recovery artifacts")
	m.refreshTarget(ctx, value)
	return nil
}

// removeUntracked deletes one regular untracked file inside the checkout.
func removeUntracked(root, relative string) error {
	target := filepath.Join(root, filepath.FromSlash(relative))
	parent, err := filepath.EvalSymlinks(filepath.Dir(target))
	if err != nil {
		return err
	}
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return err
	}
	inside, err := filepath.Rel(resolvedRoot, parent)
	if err != nil || inside == ".." || strings.HasPrefix(inside, ".."+string(filepath.Separator)) {
		return fault.New(fault.Invalid, "checkout path leaves the checkout")
	}
	info, err := os.Lstat(target)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fault.New(fault.Invalid, "only regular untracked files can be discarded")
	}
	return os.Remove(target)
}

func (m *Manager) refreshTarget(ctx context.Context, value model.Workspace) {
	m.Changesets.InvalidatePath(value.Path)
	if value.CardID != "" {
		_, _ = m.Workspaces.Refresh(ctx, value.CardID, false)
	}
}

func (m *Manager) commit(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	subject := strings.TrimSpace(operation.Parameters["subject"])
	if subject == "" {
		return fault.New(fault.Invalid, "commit subject is required")
	}
	if operation.Parameters["stage_all"] == "true" {
		if _, err := m.Git.Run(ctx, value.Path, "add", "-A"); err != nil {
			return err
		}
		m.step(operation, "staged checkout changes for commit")
	}
	stagedArgs := []string{"diff", "--cached", "--name-only", "-z"}
	if value.HeadSHA != "" {
		stagedArgs = append(stagedArgs, "HEAD")
	}
	stagedArgs = append(stagedArgs, "--")
	staged, err := m.Git.Run(ctx, value.Path, stagedArgs...)
	if err != nil {
		return err
	}
	if len(staged.Output) == 0 {
		return fault.New(fault.Invalid, "no staged changes to commit")
	}
	args := []string{"-c", "commit.gpgSign=false", "commit", "--no-gpg-sign", "-m", subject}
	if body := strings.TrimSpace(operation.Parameters["body"]); body != "" {
		args = append(args, "-m", body)
	}
	if _, err := m.Git.Run(ctx, value.Path, args...); err != nil {
		return err
	}
	head, _ := m.gitOutput(ctx, value.Path, "rev-parse", "HEAD")
	operation.Result = head
	m.step(operation, "created commit "+shortSHA(head))
	m.refreshTarget(ctx, value)
	return nil
}

func (m *Manager) update(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	if !hasReviewBranch(value) {
		clean, err := m.isClean(ctx, value.Path)
		if err != nil {
			return err
		}
		if !clean {
			return fault.New(fault.Invalid, "project directory must be clean before updating its current branch")
		}
	}
	target := value.BaseBranch
	if value.BaseRemote != "" && value.BaseBranch != "" && operation.Parameters["fetch"] != "false" {
		if _, err := m.Git.Run(ctx, value.Path, "fetch", "--no-tags", value.BaseRemote, value.BaseBranch); err != nil {
			return err
		}
		target = "FETCH_HEAD"
		m.step(operation, "fetched "+value.BaseRemote+"/"+value.BaseBranch)
	}
	if target == "" {
		return fault.New(fault.Invalid, "workspace base branch is not configured")
	}
	if !hasReviewBranch(value) {
		if _, err := m.Git.Run(ctx, value.Path, "merge", "--ff-only", target); err != nil {
			return err
		}
		m.step(operation, "fast-forwarded project directory")
		m.refreshTarget(ctx, value)
		return nil
	}
	if _, err := m.Git.Run(ctx, value.Path, "rebase", target); err != nil {
		conflicts := m.conflicts(ctx, value.Path)
		if len(conflicts) > 0 {
			operation.Conflicts = conflicts
			value.State = model.WorkspaceStateConflicted
			_, _ = m.Store.Workspaces.Save(value)
			return ErrWaitingForResolution
		}
		return err
	}
	m.step(operation, "rebased workspace onto "+target)
	m.refreshTarget(ctx, value)
	return m.validateIfRequested(ctx, operation, value.Path, value.ProjectID)
}

func (m *Manager) abortConflict(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	if _, err := m.Git.Run(ctx, value.Path, "rebase", "--abort"); err != nil {
		if _, mergeErr := m.Git.Run(ctx, value.Path, "merge", "--abort"); mergeErr != nil {
			return fault.New(fault.Invalid, "workspace has no rebase or merge to abort")
		}
	}
	value.State, value.CurrentOperationID = model.WorkspaceStateReady, ""
	_, _ = m.Store.Workspaces.Save(value)
	m.finishConflictedOperation(operation.Parameters["conflicted_operation_id"], model.GitOperationCanceled, "operation aborted")
	m.step(operation, "aborted conflicted Git operation")
	m.refreshTarget(ctx, value)
	return nil
}

func (m *Manager) continueConflict(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	conflicts := m.conflicts(ctx, value.Path)
	if len(conflicts) > 0 {
		operation.Conflicts = conflicts
		return ErrWaitingForResolution
	}
	if _, err := m.Git.Run(ctx, value.Path, "rebase", "--continue"); err != nil {
		conflicts = m.conflicts(ctx, value.Path)
		if len(conflicts) > 0 {
			operation.Conflicts = conflicts
			return ErrWaitingForResolution
		}
		return err
	}
	value.State = model.WorkspaceStateReady
	_, _ = m.Store.Workspaces.Save(value)
	m.finishConflictedOperation(operation.Parameters["conflicted_operation_id"], model.GitOperationSucceeded, "conflict resolved")
	m.step(operation, "continued conflicted rebase")
	m.refreshTarget(ctx, value)
	return m.validateIfRequested(ctx, operation, value.Path, value.ProjectID)
}

func (m *Manager) finishConflictedOperation(id, status, message string) {
	if id == "" {
		return
	}
	previous, err := m.Store.Workspaces.GitOperation(id)
	if err != nil || previous.Status != model.GitOperationWaitingForResolution {
		return
	}
	previous.Status, previous.Error, previous.FinishedAt = status, message, now()
	_, _ = m.Store.Workspaces.SaveGitOperation(previous)
	m.notify(id)
}

func (m *Manager) validateIfRequested(ctx context.Context, operation *model.GitOperation, directory, projectID string) error {
	if operation.Parameters["validate"] == "false" {
		return nil
	}
	return m.validate(ctx, operation, directory, projectID)
}

func (m *Manager) validate(ctx context.Context, operation *model.GitOperation, directory, projectID string) error {
	project, err := m.Store.Kanban.ProjectForCheckout(projectID, kanban.CheckoutFromContext(ctx))
	if err != nil {
		return err
	}
	for _, configured := range project.ValidationCommands {
		timeout := time.Duration(configured.TimeoutSeconds) * time.Second
		if timeout <= 0 {
			timeout = 10 * time.Minute
		}
		commandCtx, cancel := context.WithTimeout(ctx, timeout)
		workingDirectory := directory
		if configured.WorkingDirectory != "" {
			workingDirectory = filepath.Join(directory, filepath.Clean(configured.WorkingDirectory))
			relative, relErr := filepath.Rel(directory, workingDirectory)
			if relErr != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
				cancel()
				return fault.New(fault.Invalid, "validation working directory leaves the workspace")
			}
		}
		started := time.Now()
		command := exec.CommandContext(commandCtx, configured.Executable, configured.Arguments...)
		command.Dir = workingDirectory
		command.Env = os.Environ()
		for key, value := range configured.Environment {
			command.Env = append(command.Env, key+"="+value)
		}
		output, commandErr := command.CombinedOutput()
		cancel()
		truncated := false
		if len(output) > 1<<20 {
			output, truncated = output[:1<<20], true
		}
		exitCode := 0
		if commandErr != nil {
			exitCode = -1
			var exit *exec.ExitError
			if errors.As(commandErr, &exit) {
				exitCode = exit.ExitCode()
			}
		}
		name := configured.Name
		if name == "" {
			name = configured.Executable
		}
		operation.ValidationResults = append(operation.ValidationResults, model.ValidationResult{
			Name: name, ExitCode: exitCode, Output: git.Redact(string(output)), Truncated: truncated,
			DurationMS: time.Since(started).Milliseconds(),
		})
		m.step(operation, "validation completed: "+name)
		if commandErr != nil {
			return fault.Invalidf("validation %s failed with exit code %d", name, exitCode)
		}
	}
	return nil
}

func (m *Manager) mergeLocal(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	if value.Mode != model.WorkspaceModeWorktree {
		return fault.New(fault.Invalid, "local merge requires a worktree workspace")
	}
	if value.RemotePublishMode == model.RemotePublishPullRequest {
		return fault.New(fault.Invalid, "this conversation is configured for pull-request publishing; create a pull request instead")
	}
	clean, err := m.isClean(ctx, value.Path)
	if err != nil {
		return err
	}
	if !clean {
		return fault.New(fault.Invalid, "workspace changes must be committed before merging")
	}
	project, err := m.Store.Kanban.ProjectForCheckout(value.ProjectID, value.CheckoutID)
	if err != nil {
		return err
	}
	releaseRepo, err := m.Workspaces.LockRepository(kanban.WithCheckout(ctx, value.CheckoutID), value.ProjectID)
	if err != nil {
		return err
	}
	defer releaseRepo()
	baseSHA, err := m.gitOutput(ctx, project.Path, "rev-parse", "--verify", value.BaseBranch+"^{commit}")
	unborn := false
	if err != nil && operation.ExpectedBaseSHA == "" && value.BaseSHA == "" {
		baseErr := err
		unborn, err = git.UnbornHead(ctx, m.Git, project.Path, value.BaseBranch)
		if err == nil && !unborn {
			return baseErr
		}
	}
	if err != nil {
		return err
	}
	if unborn {
		baseSHA = ""
	}
	if baseSHA == "" && !unborn {
		return fault.New(fault.Invalid, "base branch is missing")
	}
	if operation.ExpectedBaseSHA != "" && baseSHA != operation.ExpectedBaseSHA {
		return fault.New(fault.Invalid, "base branch moved after the merge was requested")
	}
	headSHA, err := m.gitOutput(ctx, value.Path, "rev-parse", "HEAD^{commit}")
	if err != nil {
		return err
	}
	if operation.ExpectedHeadSHA != "" && headSHA != operation.ExpectedHeadSHA {
		return fault.New(fault.Invalid, "workspace head moved after the merge was requested")
	}
	integrationRoot := filepath.Join(m.Store.RuntimeDir(), "integration")
	if err := os.MkdirAll(integrationRoot, 0o700); err != nil {
		return err
	}
	integrationPath, err := os.MkdirTemp(integrationRoot, "merge-")
	if err != nil {
		return err
	}
	_ = os.Remove(integrationPath)
	integrationBase := baseSHA
	if unborn {
		integrationBase = headSHA
	}
	if _, err := m.Git.Run(ctx, project.Path, "worktree", "add", "--detach", integrationPath, integrationBase); err != nil {
		return err
	}
	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		_, _ = m.Git.Run(cleanupCtx, project.Path, "worktree", "remove", "--force", integrationPath)
	}()
	m.step(operation, "prepared isolated integration worktree")
	strategy := operation.Parameters["strategy"]
	if strategy == "" {
		strategy = "squash"
	}
	resultSHA := headSHA
	switch strategy {
	case "fast_forward":
		if !unborn {
			if _, err := m.Git.Run(ctx, integrationPath, "merge-base", "--is-ancestor", baseSHA, headSHA); err != nil {
				return fault.New(fault.Invalid, "workspace cannot be fast-forwarded into the base branch")
			}
		}
		if _, err := m.Git.Run(ctx, integrationPath, "reset", "--hard", headSHA); err != nil {
			return err
		}
	case "merge_commit":
		if unborn {
			break
		}
		args := []string{"-c", "commit.gpgSign=false", "merge", "--no-gpg-sign", "--no-ff", "--no-edit"}
		if value.BaseSHA == "" {
			args = append(args, "--allow-unrelated-histories")
		}
		args = append(args, headSHA)
		if _, err := m.Git.Run(ctx, integrationPath, args...); err != nil {
			return fmt.Errorf("prepare merge commit: %w", err)
		}
		resultSHA, err = m.gitOutput(ctx, integrationPath, "rev-parse", "HEAD")
	case "squash":
		message := strings.TrimSpace(operation.Parameters["subject"])
		if message == "" {
			message = "Merge " + value.Branch
		}
		if unborn {
			// There is no parent yet. Squash the workspace tree into one root
			// commit, then validate the exact result in the isolated checkout.
			resultSHA, err = m.gitOutput(ctx, integrationPath, "-c", "commit.gpgSign=false", "commit-tree", headSHA+"^{tree}", "-m", message)
			if err != nil {
				return err
			}
			if _, err := m.Git.Run(ctx, integrationPath, "reset", "--hard", resultSHA); err != nil {
				return err
			}
		} else {
			args := []string{"merge", "--squash"}
			if value.BaseSHA == "" {
				args = append(args, "--allow-unrelated-histories")
			}
			args = append(args, headSHA)
			if _, err := m.Git.Run(ctx, integrationPath, args...); err != nil {
				return fmt.Errorf("prepare squash merge: %w", err)
			}
			if _, err := m.Git.Run(ctx, integrationPath, "-c", "commit.gpgSign=false", "commit", "--no-gpg-sign", "-m", message); err != nil {
				return err
			}
			resultSHA, err = m.gitOutput(ctx, integrationPath, "rev-parse", "HEAD")
		}
	default:
		return fault.New(fault.Invalid, "merge strategy must be squash, merge_commit, or fast_forward")
	}
	if err != nil {
		return err
	}
	m.step(operation, "prepared "+strategy+" result "+shortSHA(resultSHA))
	if err := m.validateIfRequested(ctx, operation, integrationPath, value.ProjectID); err != nil {
		return err
	}
	releaseCheckout, err := m.Workspaces.LockCheckout(kanban.WithCheckout(ctx, value.CheckoutID), value.ProjectID)
	if err != nil {
		return err
	}
	defer releaseCheckout()
	branch, _ := m.gitOutput(ctx, project.Path, "symbolic-ref", "--quiet", "--short", "HEAD")
	if branch != value.BaseBranch {
		return fault.Invalidf("registered checkout must be on %s before local merge", value.BaseBranch)
	}
	clean, err = m.isClean(ctx, project.Path)
	if err != nil || !clean {
		return fault.New(fault.Invalid, "registered base checkout must be clean before local merge")
	}
	if unborn {
		stillUnborn, err := git.UnbornHead(ctx, m.Git, project.Path, value.BaseBranch)
		if err != nil {
			return err
		}
		if !stillUnborn {
			return fault.New(fault.Invalid, "registered base checkout moved during merge preparation")
		}
	} else {
		current, err := m.gitOutput(ctx, project.Path, "rev-parse", "HEAD")
		if err != nil || current != baseSHA {
			return fault.New(fault.Invalid, "registered base checkout moved during merge preparation")
		}
	}
	if unborn {
		if err := m.checkInitialCheckout(ctx, project.Path, resultSHA); err != nil {
			return err
		}
	}
	if value.RemotePublishMode == model.RemotePublishPushBase {
		if value.BaseRemote == "" {
			return fault.New(fault.Invalid, "push-base publishing requires a configured remote")
		}
		if _, err := m.Git.Run(ctx, integrationPath, "push", value.BaseRemote, resultSHA+":refs/heads/"+value.BaseBranch); err != nil {
			return fmt.Errorf("push integrated %s to %s: %w", value.BaseBranch, value.BaseRemote, err)
		}
		m.step(operation, "pushed "+value.BaseBranch+" to "+value.BaseRemote)
	}
	if _, err := m.Git.Run(ctx, project.Path, "merge", "--no-overwrite-ignore", "--ff-only", resultSHA); err != nil {
		return err
	}
	value.State = model.WorkspaceStateCleanupPending
	value.IntegratedHeadSHA, value.IntegratedResultSHA = headSHA, resultSHA
	value.IntegrationStrategy, value.IntegratedAt = strategy, now()
	if _, err := m.Store.Workspaces.Save(value); err != nil {
		return err
	}
	operation.Result = resultSHA
	m.step(operation, "fast-forwarded "+value.BaseBranch+" to "+shortSHA(resultSHA))
	return nil
}

// Git's unborn-branch merge can overwrite ignored files even when given
// --no-overwrite-ignore. Refuse collisions, including symlink/file ancestors,
// before populating the first tree in the operator's checkout.
func (m *Manager) checkInitialCheckout(ctx context.Context, directory, commit string) error {
	files, err := m.Git.Run(ctx, directory, "ls-tree", "-r", "--name-only", "-z", commit)
	if err != nil {
		return err
	}
	if files.Truncated {
		return fault.New(fault.Invalid, "initial checkout is too large to check safely")
	}
	for _, name := range zeroFields(files.Output) {
		if _, err := relativePath(name); err != nil {
			return err
		}
		parts := strings.Split(name, "/")
		target := directory
		for i, part := range parts {
			target = filepath.Join(target, part)
			info, err := os.Lstat(target)
			if errors.Is(err, os.ErrNotExist) {
				break
			}
			if err != nil {
				return err
			}
			if i == len(parts)-1 || !info.IsDir() {
				return fault.Invalidf("initial merge would overwrite existing checkout path %s", name)
			}
		}
	}
	return nil
}

func (m *Manager) push(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	if value.BaseRemote == "" {
		return fault.New(fault.Invalid, "workspace has no configured remote")
	}
	if value.Branch == "" {
		return fault.New(fault.Invalid, "workspace is not on a branch")
	}
	if value.Mode != model.WorkspaceModeProject && !hasReviewBranch(value) {
		return fault.New(fault.Invalid, "the project directory is on its base branch; switch branches or use a worktree before pushing a review branch")
	}
	args := []string{"push", "--set-upstream", value.BaseRemote, value.Branch + ":" + value.Branch}
	if operation.Parameters["force_with_lease"] == "true" {
		expected := strings.TrimSpace(operation.Parameters["expected_remote_sha"])
		if expected == "" {
			return fault.New(fault.Invalid, "force-with-lease requires expected_remote_sha")
		}
		args = []string{"push", "--force-with-lease=refs/heads/" + value.Branch + ":" + expected, "--set-upstream", value.BaseRemote, value.Branch + ":" + value.Branch}
	}
	if _, err := m.Git.Run(ctx, value.Path, args...); err != nil {
		return err
	}
	m.step(operation, "pushed "+value.Branch+" to "+value.BaseRemote)
	return nil
}

func hasReviewBranch(value model.Workspace) bool {
	return value.Branch != "" && value.BaseBranch != "" && value.Branch != value.BaseBranch
}

func (m *Manager) cleanup(ctx context.Context, operation *model.GitOperation, value model.Workspace, discard bool) error {
	if m.Busy != nil && m.Busy(value.CardID) {
		return fmt.Errorf("%w: active terminal or process", ErrWorkspaceBusy)
	}
	clean, err := m.isClean(ctx, value.Path)
	if err != nil {
		return err
	}
	if !clean && !discard {
		return fault.New(fault.Invalid, "workspace has uncommitted changes")
	}
	if value.Mode == model.WorkspaceModeProject {
		if discard {
			return fault.New(fault.Invalid, "Dieter cannot discard the user-owned project directory")
		}
		return m.Store.Workspaces.Delete(value.CardID)
	}
	project, err := m.Store.Kanban.ProjectForCheckout(value.ProjectID, value.CheckoutID)
	if err != nil {
		return err
	}
	if discard {
		if err := m.createRecovery(ctx, operation, value); err != nil {
			return err
		}
	}
	integrated := value.State == model.WorkspaceStateCleanupPending && value.IntegratedHeadSHA != "" && value.IntegratedHeadSHA == value.HeadSHA
	if !discard && value.HeadSHA != "" && !integrated {
		if _, err := m.Git.Run(ctx, value.Path, "merge-base", "--is-ancestor", value.HeadSHA, value.BaseBranch); err != nil {
			return fault.New(fault.Invalid, "workspace branch is not merged into its base")
		}
	}
	args := []string{"worktree", "remove"}
	if discard {
		args = append(args, "--force")
	}
	args = append(args, value.Path)
	if _, err := m.Git.Run(ctx, project.Path, args...); err != nil {
		return err
	}
	if value.ManagedBranch && value.Branch != "" && value.HeadSHA != "" {
		deleteFlag := "-d"
		if discard || integrated {
			deleteFlag = "-D"
		}
		if _, err := m.Git.Run(ctx, project.Path, "branch", deleteFlag, value.Branch); err != nil {
			return err
		}
	}
	m.step(operation, "removed workspace")
	return m.Store.Workspaces.Delete(value.CardID)
}

func (m *Manager) createRecovery(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	directory := filepath.Join(m.Store.RecoveryDir(), operation.ID)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	if value.Branch != "" && value.HeadSHA != "" {
		if _, err := m.Git.Run(ctx, value.Path, "bundle", "create", filepath.Join(directory, "branch.bundle"), value.Branch); err != nil {
			return fmt.Errorf("create recovery bundle: %w", err)
		}
	}
	for name, args := range map[string][]string{
		"unstaged.patch": {"diff", "--binary", "--"},
		"staged.patch":   {"diff", "--cached", "--binary", "--"},
	} {
		result, err := m.Git.Run(ctx, value.Path, args...)
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(directory, name), result.Output, 0o600); err != nil {
			return err
		}
	}
	untracked, err := m.Git.Run(ctx, value.Path, "ls-files", "--others", "--exclude-standard", "-z")
	if err != nil {
		return err
	}
	if err := archiveUntracked(value.Path, filepath.Join(directory, "untracked.tar"), zeroFields(untracked.Output)); err != nil {
		return err
	}
	metadata := fmt.Sprintf("card=%s\nproject=%s\nmode=%s\npath=%s\nbranch=%s\nbase_sha=%s\nhead_sha=%s\n", value.CardID, value.ProjectID, value.Mode, value.Path, value.Branch, value.BaseSHA, value.HeadSHA)
	if err := os.WriteFile(filepath.Join(directory, "RESTORE.txt"), []byte(metadata), 0o600); err != nil {
		return err
	}
	m.step(operation, "created recovery artifacts at "+directory)
	return nil
}

func archiveUntracked(root, target string, paths []string) error {
	file, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	writer := tar.NewWriter(file)
	for _, relative := range paths {
		clean := filepath.Clean(filepath.FromSlash(relative))
		if clean == "." || clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
			continue
		}
		absolute := filepath.Join(root, clean)
		info, err := os.Lstat(absolute)
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		header, err := tar.FileInfoHeader(info, "")
		if err != nil {
			continue
		}
		header.Name = filepath.ToSlash(clean)
		if err := writer.WriteHeader(header); err != nil {
			writer.Close()
			file.Close()
			return err
		}
		input, err := os.Open(absolute)
		if err == nil {
			_, err = io.Copy(writer, input)
			_ = input.Close()
		}
		if err != nil {
			writer.Close()
			file.Close()
			return err
		}
	}
	if err := writer.Close(); err != nil {
		file.Close()
		return err
	}
	return file.Close()
}

func (m *Manager) adopt(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	target := strings.TrimSpace(operation.Parameters["target_card_id"])
	if target == "" {
		return fault.New(fault.Invalid, "workspace adoption requires target_card_id")
	}
	if active, err := m.Store.Leases.CardActive(target); err != nil || active {
		if err != nil {
			return err
		}
		return leases.ErrCardActive
	}
	targetCard, err := m.Store.Kanban.ResolveCard(target)
	if err != nil {
		return err
	}
	if _, err := m.Store.Kanban.UpdateCardWorkspaceSelection(target, value.Mode, value.Branch, value.BaseBranch, value.BaseRemote, value.RemotePublishMode, true); err != nil {
		return err
	}
	transferred, err := m.Store.Workspaces.Transfer(value.CardID, targetCard.ID)
	if err != nil {
		return err
	}
	transferred.CurrentOperationID = ""
	if transferred, err = m.Store.Workspaces.Save(transferred); err != nil {
		return err
	}
	operation.Result = transferred.CardID
	m.step(operation, "transferred workspace to "+targetCard.ID)
	return nil
}

func (m *Manager) createPullRequest(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	if value.RemotePublishMode == model.RemotePublishPushBase {
		return fault.New(fault.Invalid, "this conversation is configured to push the base branch directly; local-merge it instead")
	}
	if !hasReviewBranch(value) {
		return fault.New(fault.Invalid, "the project directory is on its base branch; switch branches or use a worktree before creating a pull request")
	}
	if operation.Parameters["push"] != "false" {
		if err := m.push(ctx, operation, value); err != nil {
			return err
		}
	}
	pullRequest, err := m.SCM.CreatePullRequest(ctx, value.Path, value.BaseRemote, git.CreatePullRequestInput{
		Title: operation.Parameters["title"], Body: operation.Parameters["body"],
		Base: value.BaseBranch, Head: value.Branch, Draft: operation.Parameters["draft"] == "true",
	})
	if err != nil {
		return err
	}
	pullRequest.CardID = value.CardID
	if _, err := m.Store.Workspaces.SavePullRequest(pullRequest); err != nil {
		return err
	}
	operation.Result = pullRequest.URL
	m.step(operation, "created pull request "+pullRequest.URL)
	return nil
}

func (m *Manager) refreshPullRequest(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	current, err := m.Store.Workspaces.PullRequest(value.CardID)
	if err != nil {
		return err
	}
	refreshed, err := m.SCM.PullRequest(ctx, value.Path, value.BaseRemote, current.Number)
	if err != nil {
		return err
	}
	refreshed.CardID = value.CardID
	if _, err := m.Store.Workspaces.SavePullRequest(refreshed); err != nil {
		return err
	}
	operation.Result = refreshed.URL
	m.step(operation, "refreshed pull request state")
	return nil
}

func (m *Manager) mergePullRequest(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	current, err := m.Store.Workspaces.PullRequest(value.CardID)
	if err != nil {
		return err
	}
	expectedHead := strings.TrimSpace(operation.Parameters["expected_head_sha"])
	if expectedHead == "" {
		expectedHead = current.HeadSHA
	}
	strategy := operation.Parameters["strategy"]
	if strategy == "" {
		strategy = "squash"
	}
	merged, err := m.SCM.MergePullRequest(ctx, value.Path, value.BaseRemote, current.Number, strategy, expectedHead)
	if err != nil {
		return err
	}
	merged.CardID = value.CardID
	if _, err := m.Store.Workspaces.SavePullRequest(merged); err != nil {
		return err
	}
	value.State = model.WorkspaceStateCleanupPending
	value.IntegratedHeadSHA, value.IntegrationStrategy, value.IntegratedAt = current.HeadSHA, strategy, now()
	value.IntegratedResultSHA = merged.BaseSHA
	if _, err := m.Store.Workspaces.Save(value); err != nil {
		return err
	}
	operation.Result = merged.URL
	m.step(operation, "merged pull request")
	return nil
}

func (m *Manager) conflicts(ctx context.Context, directory string) []model.GitConflict {
	result, err := m.Git.Run(ctx, directory, "diff", "--name-only", "--diff-filter=U", "-z")
	if err != nil {
		return nil
	}
	conflicts := make([]model.GitConflict, 0)
	for _, path := range zeroFields(result.Output) {
		diff, _ := m.Git.Run(ctx, directory, "diff", "--cc", "--no-color", "--", path)
		conflicts = append(conflicts, model.GitConflict{Path: path, HunkCount: bytes.Count(diff.Output, []byte("@@@"))})
	}
	return conflicts
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

func (m *Manager) gitOutput(ctx context.Context, directory string, args ...string) (string, error) {
	result, err := m.Git.Run(ctx, directory, args...)
	return strings.TrimSpace(string(result.Output)), err
}

func (m *Manager) isClean(ctx context.Context, directory string) (bool, error) {
	result, err := m.Git.Run(ctx, directory, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	return len(result.Output) == 0, err
}

func shortSHA(value string) string {
	if len(value) > 12 {
		return value[:12]
	}
	return value
}

func now() string { return time.Now().UTC().Format(time.RFC3339Nano) }

func (m *Manager) Get(id string) (model.GitOperation, error) {
	return m.Store.Workspaces.GitOperation(id)
}

func (m *Manager) Cancel(id string) error {
	m.mu.Lock()
	cancel := m.active[id]
	m.mu.Unlock()
	if cancel == nil {
		operation, err := m.Store.Workspaces.GitOperation(id)
		if err != nil {
			return err
		}
		if operation.Status == model.GitOperationWaitingForResolution {
			return fault.New(fault.Invalid, "abort the conflicted workspace instead of canceling its observer")
		}
		return fault.New(fault.Invalid, "Git operation is not running")
	}
	cancel()
	return nil
}

func (m *Manager) notify(id string) {
	m.mu.Lock()
	changed := m.changed[id]
	if changed != nil {
		close(changed)
		m.changed[id] = make(chan struct{})
	}
	m.mu.Unlock()
}

func (m *Manager) Changed(id string) <-chan struct{} {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.changed[id] == nil {
		m.changed[id] = make(chan struct{})
	}
	return m.changed[id]
}

func (m *Manager) Logs(id string, after uint64) ([]workspaces.GitOperationLogEntry, error) {
	return m.Store.Workspaces.GitOperationLog(id, after, 500)
}
