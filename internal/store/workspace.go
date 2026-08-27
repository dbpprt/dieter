package store

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
)

const maxGitOperationLogBytes = 8 << 20

func validWorkspaceMode(value string) bool {
	switch value {
	case model.WorkspaceModeMain, model.WorkspaceModeBranch, model.WorkspaceModeWorktree:
		return true
	default:
		return false
	}
}

func normalizeWorkspaceMode(value string) (string, error) {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "" {
		value = model.WorkspaceModeMain
	}
	if !validWorkspaceMode(value) {
		return "", errors.New("workspace mode must be main, branch, or worktree")
	}
	return value, nil
}

func writeJSON(path string, value any) error {
	raw, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(path, append(raw, '\n'))
}

func readJSON(path string, value any) error {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return ErrNotFound
	}
	if err != nil {
		return err
	}
	return json.Unmarshal(raw, value)
}

func listJSON(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	paths := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasSuffix(entry.Name(), ".json") {
			paths = append(paths, filepath.Join(dir, entry.Name()))
		}
	}
	sort.Strings(paths)
	return paths, nil
}

func (s *Store) Workspace(cardRef string) (model.Workspace, error) {
	card, err := s.ResolveCard(cardRef)
	if err != nil {
		return model.Workspace{}, err
	}
	return s.WorkspaceByCardID(card.ID)
}

func (s *Store) WorkspaceByCardID(cardID string) (model.Workspace, error) {
	if !validFileID(cardID) {
		return model.Workspace{}, errors.New("card ID is invalid")
	}
	var value model.Workspace
	err := readJSON(filepath.Join(s.workspaceDir(), cardID+".json"), &value)
	return value, err
}

func (s *Store) SaveWorkspace(value model.Workspace) (model.Workspace, error) {
	if !validFileID(value.CardID) || !validFileID(value.ProjectID) {
		return model.Workspace{}, errors.New("workspace card and project IDs are required")
	}
	mode, err := normalizeWorkspaceMode(value.Mode)
	if err != nil {
		return model.Workspace{}, err
	}
	value.Mode = mode
	if value.State == "" {
		value.State = model.WorkspaceStateReserved
	}
	now := timestamp()
	if value.CreatedAt == "" {
		value.CreatedAt = now
	}
	value.UpdatedAt = now
	if value.LastActivityAt == "" {
		value.LastActivityAt = now
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Workspace{}, err
	}
	defer release()
	if _, err := s.ResolveCard(value.CardID); err != nil {
		return model.Workspace{}, err
	}
	project, err := s.ResolveProject(value.ProjectID)
	if err != nil || project.ID != value.ProjectID {
		return model.Workspace{}, fmt.Errorf("workspace project: %w", err)
	}
	return value, writeJSON(filepath.Join(s.workspaceDir(), value.CardID+".json"), value)
}

func (s *Store) ListWorkspaces(projectRef string) ([]model.Workspace, error) {
	projectID := ""
	if strings.TrimSpace(projectRef) != "" {
		project, err := s.ResolveProject(projectRef)
		if err != nil {
			return nil, err
		}
		projectID = project.ID
	}
	paths, err := listJSON(s.workspaceDir())
	if err != nil {
		return nil, err
	}
	result := make([]model.Workspace, 0, len(paths))
	for _, path := range paths {
		var value model.Workspace
		if err := readJSON(path, &value); err != nil {
			return nil, err
		}
		if projectID == "" || value.ProjectID == projectID {
			result = append(result, value)
		}
	}
	sort.SliceStable(result, func(i, j int) bool { return result[i].LastActivityAt > result[j].LastActivityAt })
	return result, nil
}

func (s *Store) DeleteWorkspace(cardID string) error {
	if !validFileID(cardID) {
		return errors.New("card ID is invalid")
	}
	release, err := s.beginWrite()
	if err != nil {
		return err
	}
	defer release()
	err = os.Remove(filepath.Join(s.workspaceDir(), cardID+".json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

func (s *Store) TransferWorkspace(fromCardRef, toCardRef string) (model.Workspace, error) {
	from, err := s.ResolveCard(fromCardRef)
	if err != nil {
		return model.Workspace{}, err
	}
	to, err := s.ResolveCard(toCardRef)
	if err != nil {
		return model.Workspace{}, err
	}
	if from.ProjectID != to.ProjectID {
		return model.Workspace{}, errors.New("workspace adoption requires cards in the same project")
	}
	value, err := s.WorkspaceByCardID(from.ID)
	if err != nil {
		return model.Workspace{}, err
	}
	if _, err := s.WorkspaceByCardID(to.ID); err == nil {
		return model.Workspace{}, errors.New("target conversation already has a workspace")
	} else if !errors.Is(err, ErrNotFound) {
		return model.Workspace{}, err
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Workspace{}, err
	}
	defer release()
	value.PreviousCardIDs = append(value.PreviousCardIDs, from.ID)
	value.CardID = to.ID
	value.UpdatedAt = timestamp()
	if err := writeJSON(filepath.Join(s.workspaceDir(), to.ID+".json"), value); err != nil {
		return model.Workspace{}, err
	}
	if err := os.Remove(filepath.Join(s.workspaceDir(), from.ID+".json")); err != nil {
		return model.Workspace{}, err
	}
	return value, nil
}

func (s *Store) CreateGitOperation(cardRef, kind, expectedRevision string) (model.GitOperation, error) {
	card, err := s.ResolveCard(cardRef)
	if err != nil {
		return model.GitOperation{}, err
	}
	now := timestamp()
	value := model.GitOperation{
		ID: newID("gitop_"), CardID: card.ID, ProjectID: card.ProjectID, Kind: strings.TrimSpace(kind),
		Status: model.GitOperationQueued, ExpectedRevision: strings.TrimSpace(expectedRevision),
		CreatedAt: now, UpdatedAt: now,
	}
	if value.Kind == "" {
		return model.GitOperation{}, errors.New("Git operation kind is required")
	}
	return s.SaveGitOperation(value)
}

func (s *Store) SaveGitOperation(value model.GitOperation) (model.GitOperation, error) {
	if !validFileID(value.ID) || !validFileID(value.CardID) {
		return model.GitOperation{}, errors.New("Git operation ID and card ID are required")
	}
	value.UpdatedAt = timestamp()
	release, err := s.beginWrite()
	if err != nil {
		return model.GitOperation{}, err
	}
	defer release()
	return value, writeJSON(filepath.Join(s.gitOperationDir(), value.ID+".json"), value)
}

func (s *Store) GitOperation(id string) (model.GitOperation, error) {
	if !validFileID(id) {
		return model.GitOperation{}, errors.New("Git operation ID is invalid")
	}
	var value model.GitOperation
	err := readJSON(filepath.Join(s.gitOperationDir(), id+".json"), &value)
	return value, err
}

func (s *Store) ListGitOperations(cardRef string) ([]model.GitOperation, error) {
	cardID := ""
	if strings.TrimSpace(cardRef) != "" {
		card, err := s.ResolveCard(cardRef)
		if err != nil {
			return nil, err
		}
		cardID = card.ID
	}
	paths, err := listJSON(s.gitOperationDir())
	if err != nil {
		return nil, err
	}
	result := make([]model.GitOperation, 0, len(paths))
	for _, path := range paths {
		var value model.GitOperation
		if err := readJSON(path, &value); err != nil {
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
	if !validFileID(id) {
		return 0, errors.New("Git operation ID is invalid")
	}
	message = strings.TrimSpace(message)
	if message == "" {
		operation, err := s.GitOperation(id)
		return operation.Sequence, err
	}
	release, err := s.beginWriteLock()
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
	}{operation.Sequence, message, timestamp()})
	path := filepath.Join(s.gitOperationDir(), id+".log")
	if info, statErr := os.Stat(path); statErr == nil && info.Size()+int64(len(line)+1) > maxGitOperationLogBytes {
		return operation.Sequence - 1, errors.New("Git operation log limit reached")
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
	operation.UpdatedAt = timestamp()
	if err := writeJSON(filepath.Join(s.gitOperationDir(), id+".json"), operation); err != nil {
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
	if !validFileID(id) {
		return nil, errors.New("Git operation ID is invalid")
	}
	if limit <= 0 || limit > 500 {
		limit = 500
	}
	file, err := os.Open(filepath.Join(s.gitOperationDir(), id+".log"))
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
		operation.FinishedAt = timestamp()
		if _, err := s.SaveGitOperation(operation); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) PullRequest(cardRef string) (model.PullRequest, error) {
	card, err := s.ResolveCard(cardRef)
	if err != nil {
		return model.PullRequest{}, err
	}
	var value model.PullRequest
	err = readJSON(filepath.Join(s.pullRequestDir(), card.ID+".json"), &value)
	return value, err
}

func (s *Store) SavePullRequest(value model.PullRequest) (model.PullRequest, error) {
	if !validFileID(value.CardID) {
		return model.PullRequest{}, errors.New("pull request card ID is required")
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.PullRequest{}, err
	}
	defer release()
	if _, err := s.ResolveCard(value.CardID); err != nil {
		return model.PullRequest{}, err
	}
	return value, writeJSON(filepath.Join(s.pullRequestDir(), value.CardID+".json"), value)
}

func (s *Store) AddChangeComment(value model.ChangeComment) (model.ChangeComment, error) {
	card, err := s.ResolveCard(value.CardID)
	if err != nil {
		return model.ChangeComment{}, err
	}
	value.CardID = card.ID
	value.Body, value.Path = strings.TrimSpace(value.Body), strings.TrimSpace(value.Path)
	if value.Body == "" || value.Path == "" || strings.TrimSpace(value.ChangesetRevision) == "" {
		return model.ChangeComment{}, errors.New("changeset revision, path, and body are required")
	}
	if value.ID == "" {
		value.ID = newID("change_comment_")
	}
	if !validFileID(value.ID) {
		return model.ChangeComment{}, errors.New("change comment ID is invalid")
	}
	if value.Author.Kind == "" {
		value.Author.Kind = "human"
	}
	value.CreatedAt = timestamp()
	release, err := s.beginWrite()
	if err != nil {
		return model.ChangeComment{}, err
	}
	defer release()
	dir := filepath.Join(s.changeCommentDir(), card.ID)
	return value, writeJSON(filepath.Join(dir, value.ID+".json"), value)
}

func (s *Store) ListChangeComments(cardRef string) ([]model.ChangeComment, error) {
	card, err := s.ResolveCard(cardRef)
	if err != nil {
		return nil, err
	}
	paths, err := listJSON(filepath.Join(s.changeCommentDir(), card.ID))
	if err != nil {
		return nil, err
	}
	result := make([]model.ChangeComment, 0, len(paths))
	for _, path := range paths {
		var value model.ChangeComment
		if err := readJSON(path, &value); err != nil {
			return nil, err
		}
		result = append(result, value)
	}
	sort.SliceStable(result, func(i, j int) bool { return result[i].CreatedAt < result[j].CreatedAt })
	return result, nil
}
