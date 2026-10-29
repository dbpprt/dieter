package workspaces

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
)

const maxGitOperationLogBytes = 8 << 20

func (s *Store) Get(cardRef string) (model.Workspace, error) {
	card, err := s.kanban.ResolveCard(cardRef)
	if err != nil {
		return model.Workspace{}, err
	}
	return s.ByCardID(card.ID)
}

func (s *Store) ByCardID(cardID string) (model.Workspace, error) {
	if !home.ValidFileID(cardID) {
		return model.Workspace{}, fault.New(fault.Invalid, "card ID is invalid")
	}
	var value model.Workspace
	err := home.ReadJSON(filepath.Join(s.home.WorkspaceDir(), cardID+".json"), &value)
	if err == nil {
		value.Mode, err = kanban.NormalizeWorkspaceMode(value.Mode)
		value.ManagedBranch = value.ManagedBranch && value.Mode == model.WorkspaceModeWorktree
	}
	return value, err
}

func (s *Store) Save(value model.Workspace) (model.Workspace, error) {
	if !home.ValidFileID(value.CardID) || !home.ValidFileID(value.ProjectID) {
		return model.Workspace{}, fault.New(fault.Invalid, "workspace card and project IDs are required")
	}
	mode, err := kanban.NormalizeWorkspaceMode(value.Mode)
	if err != nil {
		return model.Workspace{}, err
	}
	value.Mode = mode
	if value.State == "" {
		value.State = model.WorkspaceStateReserved
	}
	now := home.Timestamp()
	if value.CreatedAt == "" {
		value.CreatedAt = now
	}
	value.UpdatedAt = now
	if value.LastActivityAt == "" {
		value.LastActivityAt = now
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Workspace{}, err
	}
	defer release()
	if _, err := s.kanban.ResolveCard(value.CardID); err != nil {
		return model.Workspace{}, err
	}
	project, err := s.kanban.ResolveProject(value.ProjectID)
	if err != nil || project.ID != value.ProjectID {
		return model.Workspace{}, fmt.Errorf("workspace project: %w", err)
	}
	return value, home.WriteJSON(filepath.Join(s.home.WorkspaceDir(), value.CardID+".json"), value)
}

// UpdateChangesetStats patches only derived changeset counters. A
// changeset can take long enough to overlap a Git operation, so saving the
// snapshot it started with would otherwise overwrite newer lifecycle state
// such as cleanup_pending and its integration metadata.
func (s *Store) UpdateChangesetStats(cardID string, changedFiles, additions, deletions int) (model.Workspace, error) {
	if !home.ValidFileID(cardID) {
		return model.Workspace{}, fault.New(fault.Invalid, "workspace card ID is invalid")
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Workspace{}, err
	}
	defer release()
	var value model.Workspace
	if err := home.ReadJSON(filepath.Join(s.home.WorkspaceDir(), cardID+".json"), &value); err != nil {
		return model.Workspace{}, err
	}
	value.ChangedFiles = changedFiles
	value.Additions = additions
	value.Deletions = deletions
	value.UpdatedAt = home.Timestamp()
	if err := home.WriteJSON(filepath.Join(s.home.WorkspaceDir(), cardID+".json"), value); err != nil {
		return model.Workspace{}, err
	}
	return value, nil
}

// UpdateGitState applies fields observed from Git while preserving
// operation and integration fields that may have changed since the refresh
// began.
func (s *Store) UpdateGitState(observed model.Workspace, includeSize bool) (model.Workspace, error) {
	if !home.ValidFileID(observed.CardID) {
		return model.Workspace{}, fault.New(fault.Invalid, "workspace card ID is invalid")
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Workspace{}, err
	}
	defer release()
	var current model.Workspace
	if err := home.ReadJSON(filepath.Join(s.home.WorkspaceDir(), observed.CardID+".json"), &current); err != nil {
		return model.Workspace{}, err
	}
	current.Mode, err = kanban.NormalizeWorkspaceMode(current.Mode)
	if err != nil {
		return model.Workspace{}, err
	}
	current.ManagedBranch = current.ManagedBranch && current.Mode == model.WorkspaceModeWorktree
	current.Branch = observed.Branch
	current.HeadSHA = observed.HeadSHA
	current.CurrentBaseSHA = observed.CurrentBaseSHA
	current.Dirty = observed.Dirty
	current.Ahead = observed.Ahead
	current.Behind = observed.Behind
	current.Revision = observed.Revision
	current.LastActivityAt = observed.LastActivityAt
	if includeSize {
		current.SizeBytes = observed.SizeBytes
	}
	if observed.State == model.WorkspaceStateOrphaned {
		current.State = model.WorkspaceStateOrphaned
	} else if current.State != model.WorkspaceStateConflicted && current.State != model.WorkspaceStateRecoveryRequired && current.State != model.WorkspaceStateCleanupPending {
		current.State = model.WorkspaceStateReady
	}
	current.UpdatedAt = home.Timestamp()
	if err := home.WriteJSON(filepath.Join(s.home.WorkspaceDir(), current.CardID+".json"), current); err != nil {
		return model.Workspace{}, err
	}
	return current, nil
}

func (s *Store) List(projectRef string) ([]model.Workspace, error) {
	projectID := ""
	if strings.TrimSpace(projectRef) != "" {
		project, err := s.kanban.ResolveProject(projectRef)
		if err != nil {
			return nil, err
		}
		projectID = project.ID
	}
	paths, err := home.ListJSON(s.home.WorkspaceDir())
	if err != nil {
		return nil, err
	}
	result := make([]model.Workspace, 0, len(paths))
	for _, path := range paths {
		var value model.Workspace
		if err := home.ReadJSON(path, &value); err != nil {
			return nil, err
		}
		value.Mode, err = kanban.NormalizeWorkspaceMode(value.Mode)
		if err != nil {
			return nil, err
		}
		value.ManagedBranch = value.ManagedBranch && value.Mode == model.WorkspaceModeWorktree
		if projectID == "" || value.ProjectID == projectID {
			result = append(result, value)
		}
	}
	sort.SliceStable(result, func(i, j int) bool { return result[i].LastActivityAt > result[j].LastActivityAt })
	return result, nil
}

func (s *Store) Delete(cardID string) error {
	if !home.ValidFileID(cardID) {
		return fault.New(fault.Invalid, "card ID is invalid")
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return err
	}
	defer release()
	err = os.Remove(filepath.Join(s.home.WorkspaceDir(), cardID+".json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func (s *Store) Transfer(fromCardRef, toCardRef string) (model.Workspace, error) {
	from, err := s.kanban.ResolveCard(fromCardRef)
	if err != nil {
		return model.Workspace{}, err
	}
	to, err := s.kanban.ResolveCard(toCardRef)
	if err != nil {
		return model.Workspace{}, err
	}
	if from.ProjectID != to.ProjectID {
		return model.Workspace{}, fault.New(fault.Invalid, "workspace adoption requires cards in the same project")
	}
	value, err := s.ByCardID(from.ID)
	if err != nil {
		return model.Workspace{}, err
	}
	if _, err := s.ByCardID(to.ID); err == nil {
		return model.Workspace{}, fault.New(fault.Invalid, "target conversation already has a workspace")
	} else if !errors.Is(err, home.ErrNotFound) {
		return model.Workspace{}, err
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Workspace{}, err
	}
	defer release()
	value.PreviousCardIDs = append(value.PreviousCardIDs, from.ID)
	value.CardID = to.ID
	value.UpdatedAt = home.Timestamp()
	if err := home.WriteJSON(filepath.Join(s.home.WorkspaceDir(), to.ID+".json"), value); err != nil {
		return model.Workspace{}, err
	}
	if err := os.Remove(filepath.Join(s.home.WorkspaceDir(), from.ID+".json")); err != nil {
		return model.Workspace{}, err
	}
	return value, nil
}

func (s *Store) CreateGitOperation(cardRef, kind, expectedRevision string) (model.GitOperation, error) {
	card, err := s.kanban.ResolveCard(cardRef)
	if err != nil {
		return model.GitOperation{}, err
	}
	return s.createGitOperation(card.ID, card.ProjectID, kind, expectedRevision)
}

func (s *Store) CreateProjectGitOperation(projectRef, kind, expectedRevision string) (model.GitOperation, error) {
	project, err := s.kanban.ResolveProject(projectRef)
	if err != nil {
		return model.GitOperation{}, err
	}
	return s.createGitOperation("", project.ID, kind, expectedRevision)
}

func (s *Store) createGitOperation(cardID, projectID, kind, expectedRevision string) (model.GitOperation, error) {
	now := home.Timestamp()
	value := model.GitOperation{
		ID: home.NewID("gitop_"), CardID: cardID, ProjectID: projectID, Kind: strings.TrimSpace(kind),
		Status: model.GitOperationQueued, ExpectedRevision: strings.TrimSpace(expectedRevision),
		CreatedAt: now, UpdatedAt: now,
	}
	if value.Kind == "" {
		return model.GitOperation{}, fault.New(fault.Invalid, "Git operation kind is required")
	}
	return s.SaveGitOperation(value)
}

func (s *Store) SaveGitOperation(value model.GitOperation) (model.GitOperation, error) {
	if !home.ValidFileID(value.ID) || !home.ValidFileID(value.ProjectID) || (value.CardID != "" && !home.ValidFileID(value.CardID)) {
		return model.GitOperation{}, fault.New(fault.Invalid, "Git operation ID, project ID, and optional card ID are invalid")
	}
	value.UpdatedAt = home.Timestamp()
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.GitOperation{}, err
	}
	defer release()
	return value, home.WriteJSON(filepath.Join(s.home.GitOperationDir(), value.ID+".json"), value)
}

func (s *Store) ActiveProjectGitOperation(projectRef string, checkoutIDs ...string) (model.GitOperation, error) {
	project, err := s.kanban.ResolveProject(projectRef)
	if err != nil {
		return model.GitOperation{}, err
	}
	values, err := s.ListGitOperations("")
	if err != nil {
		return model.GitOperation{}, err
	}
	for _, value := range values {
		if s.kanban.CanonicalProjectRef(value.ProjectID) == project.ID && value.CardID == "" && (len(checkoutIDs) == 0 || value.CheckoutID == checkoutIDs[0]) &&
			(value.Status == model.GitOperationQueued || value.Status == model.GitOperationRunning || value.Status == model.GitOperationWaitingForResolution) {
			return value, nil
		}
	}
	return model.GitOperation{}, home.ErrNotFound
}

func (s *Store) GitOperation(id string) (model.GitOperation, error) {
	if !home.ValidFileID(id) {
		return model.GitOperation{}, fault.New(fault.Invalid, "Git operation ID is invalid")
	}
	var value model.GitOperation
	err := home.ReadJSON(filepath.Join(s.home.GitOperationDir(), id+".json"), &value)
	return value, err
}

func (s *Store) ListGitOperations(cardRef string) ([]model.GitOperation, error) {
	cardID := ""
	if strings.TrimSpace(cardRef) != "" {
		card, err := s.kanban.ResolveCard(cardRef)
		if err != nil {
			return nil, err
		}
		cardID = card.ID
	}
	paths, err := home.ListJSON(s.home.GitOperationDir())
	if err != nil {
		return nil, err
	}
	result := make([]model.GitOperation, 0, len(paths))
	for _, path := range paths {
		var value model.GitOperation
		if err := home.ReadJSON(path, &value); err != nil {
			return nil, err
		}
		if cardID == "" || value.CardID == cardID {
			result = append(result, value)
		}
	}
	sort.SliceStable(result, func(i, j int) bool { return result[i].CreatedAt > result[j].CreatedAt })
	return result, nil
}

func (s *Store) AppendGitOperationLog(id, message string) (uint64, error) {
	if !home.ValidFileID(id) {
		return 0, fault.New(fault.Invalid, "Git operation ID is invalid")
	}
	message = strings.TrimSpace(message)
	if message == "" {
		operation, err := s.GitOperation(id)
		return operation.Sequence, err
	}
	release, err := s.home.BeginWriteLock()
	if err != nil {
		return 0, err
	}
	defer release()
	operation, err := s.GitOperation(id)
	if err != nil {
		return 0, err
	}
	operation.Sequence++
	line, _ := json.Marshal(struct {
		Sequence uint64 `json:"sequence"`
		Message  string `json:"message"`
		Created  string `json:"createdAt"`
	}{operation.Sequence, message, home.Timestamp()})
	path := filepath.Join(s.home.GitOperationDir(), id+".log")
	if info, statErr := os.Stat(path); statErr == nil && info.Size()+int64(len(line)+1) > maxGitOperationLogBytes {
		return operation.Sequence - 1, fault.New(fault.Invalid, "Git operation log limit reached")
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return operation.Sequence - 1, err
	}
	_, writeErr := file.Write(append(line, '\n'))
	if writeErr == nil {
		writeErr = file.Sync()
	}
	closeErr := file.Close()
	if writeErr != nil {
		return operation.Sequence - 1, writeErr
	}
	if closeErr != nil {
		return operation.Sequence - 1, closeErr
	}
	operation.UpdatedAt = home.Timestamp()
	if err := home.WriteJSON(filepath.Join(s.home.GitOperationDir(), id+".json"), operation); err != nil {
		return operation.Sequence - 1, err
	}
	return operation.Sequence, nil
}

type GitOperationLogEntry struct {
	Sequence  uint64 `json:"sequence"`
	Message   string `json:"message"`
	CreatedAt string `json:"createdAt"`
}

func (s *Store) GitOperationLog(id string, after uint64, limit int) ([]GitOperationLogEntry, error) {
	if !home.ValidFileID(id) {
		return nil, fault.New(fault.Invalid, "Git operation ID is invalid")
	}
	if limit <= 0 || limit > 500 {
		limit = 500
	}
	file, err := os.Open(filepath.Join(s.home.GitOperationDir(), id+".log"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()
	result := make([]GitOperationLogEntry, 0, limit)
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), 1<<20)
	for scanner.Scan() {
		var value GitOperationLogEntry
		if json.Unmarshal(scanner.Bytes(), &value) == nil && value.Sequence > after {
			result = append(result, value)
			if len(result) == limit {
				break
			}
		}
	}
	return result, scanner.Err()
}

func (s *Store) InterruptRunningGitOperations() error {
	operations, err := s.ListGitOperations("")
	if err != nil {
		return err
	}
	for _, operation := range operations {
		if operation.Status != model.GitOperationQueued && operation.Status != model.GitOperationRunning {
			continue
		}
		operation.Status = model.GitOperationInterrupted
		operation.Error = "daemon restarted while the Git operation was active"
		operation.FinishedAt = home.Timestamp()
		if _, err := s.SaveGitOperation(operation); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) PullRequest(cardRef string) (model.PullRequest, error) {
	card, err := s.kanban.ResolveCard(cardRef)
	if err != nil {
		return model.PullRequest{}, err
	}
	var value model.PullRequest
	err = home.ReadJSON(filepath.Join(s.home.PullRequestDir(), card.ID+".json"), &value)
	return value, err
}

func (s *Store) SavePullRequest(value model.PullRequest) (model.PullRequest, error) {
	if !home.ValidFileID(value.CardID) {
		return model.PullRequest{}, fault.New(fault.Invalid, "pull request card ID is required")
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.PullRequest{}, err
	}
	defer release()
	if _, err := s.kanban.ResolveCard(value.CardID); err != nil {
		return model.PullRequest{}, err
	}
	return value, home.WriteJSON(filepath.Join(s.home.PullRequestDir(), value.CardID+".json"), value)
}

func (s *Store) AddChangeComment(value model.ChangeComment) (model.ChangeComment, error) {
	card, err := s.kanban.ResolveCard(value.CardID)
	if err != nil {
		return model.ChangeComment{}, err
	}
	value.CardID = card.ID
	value.Body, value.Path = strings.TrimSpace(value.Body), strings.TrimSpace(value.Path)
	if value.Body == "" || value.Path == "" || strings.TrimSpace(value.ChangesetRevision) == "" {
		return model.ChangeComment{}, fault.New(fault.Invalid, "changeset revision, path, and body are required")
	}
	if value.ID == "" {
		value.ID = home.NewID("change_comment_")
	}
	if !home.ValidFileID(value.ID) {
		return model.ChangeComment{}, fault.New(fault.Invalid, "change comment ID is invalid")
	}
	if value.Author.Kind == "" {
		value.Author.Kind = "human"
	}
	value.CreatedAt = home.Timestamp()
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.ChangeComment{}, err
	}
	defer release()
	dir := filepath.Join(s.home.ChangeCommentDir(), card.ID)
	return value, home.WriteJSON(filepath.Join(dir, value.ID+".json"), value)
}

func (s *Store) ListChangeComments(cardRef string) ([]model.ChangeComment, error) {
	card, err := s.kanban.ResolveCard(cardRef)
	if err != nil {
		return nil, err
	}
	paths, err := home.ListJSON(filepath.Join(s.home.ChangeCommentDir(), card.ID))
	if err != nil {
		return nil, err
	}
	result := make([]model.ChangeComment, 0, len(paths))
	for _, path := range paths {
		var value model.ChangeComment
		if err := home.ReadJSON(path, &value); err != nil {
			return nil, err
		}
		result = append(result, value)
	}
	sort.SliceStable(result, func(i, j int) bool { return result[i].CreatedAt < result[j].CreatedAt })
	return result, nil
}

// WorkspaceSummary is the card-facing summary of a conversation's workspace,
// or nil when it has none.
func (s *Store) WorkspaceSummary(cardID string) *model.WorkspaceSummary {
	var workspace model.Workspace
	if home.ReadJSON(filepath.Join(s.home.WorkspaceDir(), cardID+".json"), &workspace) != nil {
		return nil
	}
	workspace.Mode, _ = kanban.NormalizeWorkspaceMode(workspace.Mode)
	return &model.WorkspaceSummary{
		Mode: workspace.Mode, State: workspace.State, Branch: workspace.Branch, BaseBranch: workspace.BaseBranch,
		Revision: workspace.Revision, HeadSHA: workspace.HeadSHA, BaseSHA: workspace.CurrentBaseSHA,
		CurrentOperationID: workspace.CurrentOperationID, Dirty: workspace.Dirty, Conflicted: workspace.State == model.WorkspaceStateConflicted,
		Ahead: workspace.Ahead, Behind: workspace.Behind, ChangedFiles: workspace.ChangedFiles,
		Additions: workspace.Additions, Deletions: workspace.Deletions, SizeBytes: workspace.SizeBytes, LastRefreshedAt: workspace.UpdatedAt,
	}
}

// PullRequestSummary is the card-facing summary of a conversation's pull
// request, or nil when it has none.
func (s *Store) PullRequestSummary(cardID string) *model.PullRequestSummary {
	var pullRequest model.PullRequest
	if home.ReadJSON(filepath.Join(s.home.PullRequestDir(), cardID+".json"), &pullRequest) != nil {
		return nil
	}
	return &model.PullRequestSummary{
		Provider: pullRequest.Provider, Number: pullRequest.Number, URL: pullRequest.URL, State: pullRequest.State,
		ReviewDecision: pullRequest.ReviewDecision, ChecksState: pullRequest.ChecksState,
		Mergeable: pullRequest.Mergeable, Draft: pullRequest.Draft, HeadSHA: pullRequest.HeadSHA,
		BaseSHA: pullRequest.BaseSHA, UpdatedAt: pullRequest.LastSyncedAt,
	}
}
