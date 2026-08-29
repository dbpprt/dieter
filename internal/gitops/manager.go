package gitops

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
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/changeset"
	"github.com/dbpprt/dieter/internal/gitexec"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/scm"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/workspace"
)

var (
	ErrWaitingForResolution = errors.New("Git operation is waiting for conflict resolution")
	ErrWorkspaceBusy        = errors.New("workspace is busy")
)

type Request struct {
	CardID           string
	Kind             string
	ExpectedRevision string
	Parameters       map[string]string
}

type Manager struct {
	Store      *store.Store
	Workspaces *workspace.Manager
	Changesets *changeset.Service
	Git        gitexec.Runner
	SCM        scm.Provider
	Log        *slog.Logger
	Busy       func(string) bool

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
		SCM: scm.NewGitHub(), Log: logger, active: map[string]context.CancelFunc{}, changed: map[string]chan struct{}{},
	}
}

func (m *Manager) Start(ctx context.Context, request Request) (model.GitOperation, error) {
	if strings.TrimSpace(request.CardID) == "" || strings.TrimSpace(request.Kind) == "" {
		return model.GitOperation{}, errors.New("card ID and Git operation kind are required")
	}
	if !supportedOperation(request.Kind) {
		return model.GitOperation{}, fmt.Errorf("unsupported Git operation %q", request.Kind)
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if active, err := m.Store.CardHasRuntimeLease(request.CardID); err != nil {
		return model.GitOperation{}, err
	} else if active {
		return model.GitOperation{}, store.ErrCardActive
	}
	workspaceValue, err := m.Workspaces.Ensure(ctx, request.CardID)
	if err != nil {
		return model.GitOperation{}, err
	}
	if m.Busy != nil && m.Busy(workspaceValue.CardID) {
		return model.GitOperation{}, fmt.Errorf("%w: active terminal or process", ErrWorkspaceBusy)
	}
	if workspaceValue.Mode == model.WorkspaceModeProject || request.Kind == "merge_local" {
		if active, activeErr := m.Store.ProjectHasRuntimeLease(workspaceValue.ProjectID, workspaceValue.CardID); activeErr != nil {
			return model.GitOperation{}, activeErr
		} else if active {
			return model.GitOperation{}, fmt.Errorf("%w: another conversation is active in the shared checkout", ErrWorkspaceBusy)
		}
	}
	release, err := m.Workspaces.LockWorkspace(ctx, workspaceValue.CardID)
	if err != nil {
		return model.GitOperation{}, err
	}
	defer release()
	workspaceValue, err = m.Store.Workspace(workspaceValue.CardID)
	if err != nil {
		return model.GitOperation{}, err
	}
	if workspaceValue.CurrentOperationID != "" {
		if current, currentErr := m.Store.GitOperation(workspaceValue.CurrentOperationID); currentErr == nil &&
			(current.Status == model.GitOperationQueued || current.Status == model.GitOperationRunning || current.Status == model.GitOperationWaitingForResolution) {
			resolvingConflict := current.Status == model.GitOperationWaitingForResolution &&
				(request.Kind == "abort_conflict" || request.Kind == "continue_conflict")
			if !resolvingConflict {
				return model.GitOperation{}, errors.New("workspace already has an active Git operation")
			}
			if request.Parameters == nil {
				request.Parameters = map[string]string{}
			}
			request.Parameters["conflicted_operation_id"] = current.ID
		}
	}
	operation, err := m.Store.CreateGitOperation(request.CardID, request.Kind, request.ExpectedRevision)
	if err != nil {
		return model.GitOperation{}, err
	}
	operation.Parameters = cloneMap(request.Parameters)
	operation.ExpectedBaseSHA, operation.ExpectedHeadSHA = workspaceValue.CurrentBaseSHA, workspaceValue.HeadSHA
	if request.Kind == "merge_local" && workspaceValue.BaseBranch != "" {
		if project, projectErr := m.Store.ResolveProject(workspaceValue.ProjectID); projectErr == nil {
			if localBase, baseErr := m.gitOutput(ctx, project.Path, "rev-parse", "--verify", workspaceValue.BaseBranch+"^{commit}"); baseErr == nil {
				operation.ExpectedBaseSHA = localBase
			}
		}
	}
	operation, err = m.Store.SaveGitOperation(operation)
	if err != nil {
		return model.GitOperation{}, err
	}
	workspaceValue.CurrentOperationID = operation.ID
	if _, err := m.Store.SaveWorkspace(workspaceValue); err != nil {
		return model.GitOperation{}, err
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
	case "commit", "update", "abort_conflict", "continue_conflict", "validate", "merge_local", "push",
		"cleanup", "discard", "adopt", "create_pr", "refresh_pr", "merge_pr":
		return true
	default:
		return false
	}
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

func (m *Manager) run(ctx context.Context, operation model.GitOperation) {
	operation.Status, operation.StartedAt = model.GitOperationRunning, now()
	operation, _ = m.Store.SaveGitOperation(operation)
	m.appendLog(&operation, "operation started: "+operation.Kind)
	m.notify(operation.ID)

	workspaceValue, err := m.Workspaces.Ensure(ctx, operation.CardID)
	if err == nil {
		var release func()
		release, err = m.Workspaces.LockWorkspace(ctx, operation.CardID)
		if err == nil {
			defer release()
			err = m.execute(ctx, &operation, workspaceValue)
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
		operation.Status, operation.Error, operation.FinishedAt = model.GitOperationFailed, gitexec.Redact(err.Error()), now()
		m.appendLog(&operation, "operation failed: "+operation.Error)
	default:
		operation.Status, operation.FinishedAt = model.GitOperationSucceeded, now()
		m.appendLog(&operation, "operation completed")
	}
	if operation.Status != model.GitOperationWaitingForResolution {
		if latest, workspaceErr := m.Store.Workspace(operation.CardID); workspaceErr == nil && latest.CurrentOperationID == operation.ID {
			latest.CurrentOperationID = ""
			_, _ = m.Store.SaveWorkspace(latest)
		}
	}
	operation, _ = m.Store.SaveGitOperation(operation)
	m.mu.Lock()
	delete(m.active, operation.ID)
	m.mu.Unlock()
	m.notify(operation.ID)
}

func (m *Manager) execute(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	if operation.ExpectedRevision != "" {
		changes, err := m.Changesets.Get(ctx, operation.CardID)
		if err != nil {
			return err
		}
		if changes.Revision != operation.ExpectedRevision {
			return changeset.ErrStaleRevision
		}
	}
	switch operation.Kind {
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
		return fmt.Errorf("unsupported Git operation %q", operation.Kind)
	}
}

func (m *Manager) appendLog(operation *model.GitOperation, message string) {
	sequence, err := m.Store.AppendGitOperationLog(operation.ID, message)
	if err == nil {
		operation.Sequence = sequence
	}
}

func (m *Manager) step(operation *model.GitOperation, name string) {
	operation.CompletedSteps = append(operation.CompletedSteps, name)
	m.appendLog(operation, name)
	*operation, _ = m.Store.SaveGitOperation(*operation)
	m.notify(operation.ID)
}

func (m *Manager) commit(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	includeUntracked := operation.Parameters["include_untracked"] != "false"
	add := []string{"add", "-u"}
	if includeUntracked {
		add = []string{"add", "-A"}
	}
	if _, err := m.Git.Run(ctx, value.Path, add...); err != nil {
		return err
	}
	m.step(operation, "staged workspace changes")
	subject := strings.TrimSpace(operation.Parameters["subject"])
	if subject == "" {
		return errors.New("commit subject is required")
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
	_, _ = m.Workspaces.Refresh(ctx, value.CardID, false)
	return nil
}

func (m *Manager) update(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	if !hasReviewBranch(value) {
		clean, err := m.isClean(ctx, value.Path)
		if err != nil {
			return err
		}
		if !clean {
			return errors.New("project directory must be clean before updating its current branch")
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
		return errors.New("workspace base branch is not configured")
	}
	if !hasReviewBranch(value) {
		if _, err := m.Git.Run(ctx, value.Path, "merge", "--ff-only", target); err != nil {
			return err
		}
		m.step(operation, "fast-forwarded project directory")
		_, _ = m.Workspaces.Refresh(ctx, value.CardID, false)
		return nil
	}
	if _, err := m.Git.Run(ctx, value.Path, "rebase", target); err != nil {
		conflicts := m.conflicts(ctx, value.Path)
		if len(conflicts) > 0 {
			operation.Conflicts = conflicts
			value.State = model.WorkspaceStateConflicted
			_, _ = m.Store.SaveWorkspace(value)
			return ErrWaitingForResolution
		}
		return err
	}
	m.step(operation, "rebased workspace onto "+target)
	_, _ = m.Workspaces.Refresh(ctx, value.CardID, false)
	return m.validateIfRequested(ctx, operation, value.Path, value.ProjectID)
}

func (m *Manager) abortConflict(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	if _, err := m.Git.Run(ctx, value.Path, "rebase", "--abort"); err != nil {
		if _, mergeErr := m.Git.Run(ctx, value.Path, "merge", "--abort"); mergeErr != nil {
			return errors.New("workspace has no rebase or merge to abort")
		}
	}
	value.State, value.CurrentOperationID = model.WorkspaceStateReady, ""
	_, _ = m.Store.SaveWorkspace(value)
	m.finishConflictedOperation(operation.Parameters["conflicted_operation_id"], model.GitOperationCanceled, "operation aborted")
	m.step(operation, "aborted conflicted Git operation")
	_, _ = m.Workspaces.Refresh(ctx, value.CardID, false)
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
	_, _ = m.Store.SaveWorkspace(value)
	m.finishConflictedOperation(operation.Parameters["conflicted_operation_id"], model.GitOperationSucceeded, "conflict resolved")
	m.step(operation, "continued conflicted rebase")
	_, _ = m.Workspaces.Refresh(ctx, value.CardID, false)
	return m.validateIfRequested(ctx, operation, value.Path, value.ProjectID)
}

func (m *Manager) finishConflictedOperation(id, status, message string) {
	if id == "" {
		return
	}
	previous, err := m.Store.GitOperation(id)
	if err != nil || previous.Status != model.GitOperationWaitingForResolution {
		return
	}
	previous.Status, previous.Error, previous.FinishedAt = status, message, now()
	_, _ = m.Store.SaveGitOperation(previous)
	m.notify(id)
}

func (m *Manager) validateIfRequested(ctx context.Context, operation *model.GitOperation, directory, projectID string) error {
	if operation.Parameters["validate"] == "false" {
		return nil
	}
	return m.validate(ctx, operation, directory, projectID)
}

func (m *Manager) validate(ctx context.Context, operation *model.GitOperation, directory, projectID string) error {
	project, err := m.Store.ResolveProject(projectID)
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
				return errors.New("validation working directory leaves the workspace")
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
			Name: name, ExitCode: exitCode, Output: gitexec.Redact(string(output)), Truncated: truncated,
			DurationMS: time.Since(started).Milliseconds(),
		})
		m.step(operation, "validation completed: "+name)
		if commandErr != nil {
			return fmt.Errorf("validation %s failed with exit code %d", name, exitCode)
		}
	}
	return nil
}

func (m *Manager) mergeLocal(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	if value.Mode != model.WorkspaceModeWorktree {
		return errors.New("local merge requires a worktree workspace")
	}
	clean, err := m.isClean(ctx, value.Path)
	if err != nil {
		return err
	}
	if !clean {
		return errors.New("workspace changes must be committed before merging")
	}
	project, err := m.Store.ResolveProject(value.ProjectID)
	if err != nil {
		return err
	}
	baseSHA, err := m.gitOutput(ctx, project.Path, "rev-parse", "--verify", value.BaseBranch+"^{commit}")
	if err != nil {
		return err
	}
	if operation.ExpectedBaseSHA != "" && baseSHA != operation.ExpectedBaseSHA {
		return errors.New("base branch moved after the merge was requested")
	}
	headSHA, err := m.gitOutput(ctx, value.Path, "rev-parse", "HEAD^{commit}")
	if err != nil {
		return err
	}
	if operation.ExpectedHeadSHA != "" && headSHA != operation.ExpectedHeadSHA {
		return errors.New("workspace head moved after the merge was requested")
	}
	releaseRepo, err := m.Workspaces.LockRepository(ctx, value.ProjectID)
	if err != nil {
		return err
	}
	defer releaseRepo()
	integrationRoot := filepath.Join(m.Store.RuntimeDir(), "integration")
	if err := os.MkdirAll(integrationRoot, 0o700); err != nil {
		return err
	}
	integrationPath, err := os.MkdirTemp(integrationRoot, "merge-")
	if err != nil {
		return err
	}
	_ = os.Remove(integrationPath)
	if _, err := m.Git.Run(ctx, project.Path, "worktree", "add", "--detach", integrationPath, baseSHA); err != nil {
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
		if _, err := m.Git.Run(ctx, integrationPath, "merge-base", "--is-ancestor", baseSHA, headSHA); err != nil {
			return errors.New("workspace cannot be fast-forwarded into the base branch")
		}
		if _, err := m.Git.Run(ctx, integrationPath, "reset", "--hard", headSHA); err != nil {
			return err
		}
	case "merge_commit":
		if _, err := m.Git.Run(ctx, integrationPath, "-c", "commit.gpgSign=false", "merge", "--no-gpg-sign", "--no-ff", "--no-edit", headSHA); err != nil {
			return fmt.Errorf("prepare merge commit: %w", err)
		}
		resultSHA, err = m.gitOutput(ctx, integrationPath, "rev-parse", "HEAD")
	case "squash":
		if _, err := m.Git.Run(ctx, integrationPath, "merge", "--squash", headSHA); err != nil {
			return fmt.Errorf("prepare squash merge: %w", err)
		}
		message := strings.TrimSpace(operation.Parameters["subject"])
		if message == "" {
			message = "Merge " + value.Branch
		}
		if _, err := m.Git.Run(ctx, integrationPath, "-c", "commit.gpgSign=false", "commit", "--no-gpg-sign", "-m", message); err != nil {
			return err
		}
		resultSHA, err = m.gitOutput(ctx, integrationPath, "rev-parse", "HEAD")
	default:
		return errors.New("merge strategy must be squash, merge_commit, or fast_forward")
	}
	if err != nil {
		return err
	}
	m.step(operation, "prepared "+strategy+" result "+shortSHA(resultSHA))
	if err := m.validateIfRequested(ctx, operation, integrationPath, value.ProjectID); err != nil {
		return err
	}
	releaseCheckout, err := m.Workspaces.LockCheckout(ctx, value.ProjectID)
	if err != nil {
		return err
	}
	defer releaseCheckout()
	branch, _ := m.gitOutput(ctx, project.Path, "symbolic-ref", "--quiet", "--short", "HEAD")
	if branch != value.BaseBranch {
		return fmt.Errorf("registered checkout must be on %s before local merge", value.BaseBranch)
	}
	clean, err = m.isClean(ctx, project.Path)
	if err != nil || !clean {
		return errors.New("registered base checkout must be clean before local merge")
	}
	current, err := m.gitOutput(ctx, project.Path, "rev-parse", "HEAD")
	if err != nil || current != baseSHA {
		return errors.New("registered base checkout moved during merge preparation")
	}
	if _, err := m.Git.Run(ctx, project.Path, "merge", "--ff-only", resultSHA); err != nil {
		return err
	}
	value.State = model.WorkspaceStateCleanupPending
	value.IntegratedHeadSHA, value.IntegratedResultSHA = headSHA, resultSHA
	value.IntegrationStrategy, value.IntegratedAt = strategy, now()
	if _, err := m.Store.SaveWorkspace(value); err != nil {
		return err
	}
	operation.Result = resultSHA
	m.step(operation, "fast-forwarded "+value.BaseBranch+" to "+shortSHA(resultSHA))
	return nil
}

func (m *Manager) push(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	if value.BaseRemote == "" {
		return errors.New("workspace has no configured remote")
	}
	if value.Branch == "" {
		return errors.New("workspace is not on a branch")
	}
	if !hasReviewBranch(value) {
		return errors.New("the project directory is on its base branch; switch branches or use a worktree before pushing a review branch")
	}
	args := []string{"push", "--set-upstream", value.BaseRemote, value.Branch + ":" + value.Branch}
	if operation.Parameters["force_with_lease"] == "true" {
		expected := strings.TrimSpace(operation.Parameters["expected_remote_sha"])
		if expected == "" {
			return errors.New("force-with-lease requires expected_remote_sha")
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
		return errors.New("workspace has uncommitted changes")
	}
	if value.Mode == model.WorkspaceModeProject {
		if discard {
			return errors.New("Dieter cannot discard the user-owned project directory")
		}
		return m.Store.DeleteWorkspace(value.CardID)
	}
	project, err := m.Store.ResolveProject(value.ProjectID)
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
			return errors.New("workspace branch is not merged into its base")
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
	if value.ManagedBranch && value.Branch != "" {
		deleteFlag := "-d"
		if discard || integrated {
			deleteFlag = "-D"
		}
		if _, err := m.Git.Run(ctx, project.Path, "branch", deleteFlag, value.Branch); err != nil {
			return err
		}
	}
	m.step(operation, "removed workspace")
	return m.Store.DeleteWorkspace(value.CardID)
}

func (m *Manager) createRecovery(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	directory := filepath.Join(m.Store.RecoveryDir(), operation.ID)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	if value.Branch != "" {
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
		return errors.New("workspace adoption requires target_card_id")
	}
	if active, err := m.Store.CardHasRuntimeLease(target); err != nil || active {
		if err != nil {
			return err
		}
		return store.ErrCardActive
	}
	targetCard, err := m.Store.ResolveCard(target)
	if err != nil {
		return err
	}
	if _, err := m.Store.UpdateCardWorkspaceSelection(target, value.Mode, value.Branch, value.BaseBranch, true); err != nil {
		return err
	}
	transferred, err := m.Store.TransferWorkspace(value.CardID, targetCard.ID)
	if err != nil {
		return err
	}
	transferred.CurrentOperationID = ""
	if transferred, err = m.Store.SaveWorkspace(transferred); err != nil {
		return err
	}
	operation.Result = transferred.CardID
	m.step(operation, "transferred workspace to "+targetCard.ID)
	return nil
}

func (m *Manager) createPullRequest(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	if !hasReviewBranch(value) {
		return errors.New("the project directory is on its base branch; switch branches or use a worktree before creating a pull request")
	}
	if operation.Parameters["push"] != "false" {
		if err := m.push(ctx, operation, value); err != nil {
			return err
		}
	}
	pullRequest, err := m.SCM.CreatePullRequest(ctx, value.Path, value.BaseRemote, scm.CreatePullRequestInput{
		Title: operation.Parameters["title"], Body: operation.Parameters["body"],
		Base: value.BaseBranch, Head: value.Branch, Draft: operation.Parameters["draft"] == "true",
	})
	if err != nil {
		return err
	}
	pullRequest.CardID = value.CardID
	if _, err := m.Store.SavePullRequest(pullRequest); err != nil {
		return err
	}
	operation.Result = pullRequest.URL
	m.step(operation, "created pull request "+pullRequest.URL)
	return nil
}

func (m *Manager) refreshPullRequest(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	current, err := m.Store.PullRequest(value.CardID)
	if err != nil {
		return err
	}
	refreshed, err := m.SCM.PullRequest(ctx, value.Path, value.BaseRemote, current.Number)
	if err != nil {
		return err
	}
	refreshed.CardID = value.CardID
	if _, err := m.Store.SavePullRequest(refreshed); err != nil {
		return err
	}
	operation.Result = refreshed.URL
	m.step(operation, "refreshed pull request state")
	return nil
}

func (m *Manager) mergePullRequest(ctx context.Context, operation *model.GitOperation, value model.Workspace) error {
	current, err := m.Store.PullRequest(value.CardID)
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
	if _, err := m.Store.SavePullRequest(merged); err != nil {
		return err
	}
	value.State = model.WorkspaceStateCleanupPending
	value.IntegratedHeadSHA, value.IntegrationStrategy, value.IntegratedAt = current.HeadSHA, strategy, now()
	value.IntegratedResultSHA = merged.BaseSHA
	if _, err := m.Store.SaveWorkspace(value); err != nil {
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

func (m *Manager) Get(id string) (model.GitOperation, error) { return m.Store.GitOperation(id) }

func (m *Manager) Cancel(id string) error {
	m.mu.Lock()
	cancel := m.active[id]
	m.mu.Unlock()
	if cancel == nil {
		operation, err := m.Store.GitOperation(id)
		if err != nil {
			return err
		}
		if operation.Status == model.GitOperationWaitingForResolution {
			return errors.New("abort the conflicted workspace instead of canceling its observer")
		}
		return errors.New("Git operation is not running")
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

func (m *Manager) Logs(id string, after uint64) ([]store.GitOperationLogEntry, error) {
	return m.Store.GitOperationLog(id, after, 500)
}
