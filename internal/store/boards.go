package store

import (
	"errors"
	"fmt"
	"github.com/dbpprt/dieter/internal/model"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
	"strings"
	"time"
)

// Public mutations retain the central Store write lock and journal transaction.
// Unexported projection helpers run within their caller's existing lock boundary.

type CreateBoardInput struct {
	Project, Name, Workflow, Description, DoneArchivePolicy string
	BaseRemote, RemotePublishMode                           string
}

func normalizeWorkflow(value string) (string, error) {
	if value == "" {
		value = model.WorkflowReview
	}
	if value != model.WorkflowDirect && value != model.WorkflowReview {
		return "", errors.New("workflow must be direct or review")
	}
	return value, nil
}

func normalizeDoneArchivePolicy(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		value = model.DoneArchiveNever
	}
	switch value {
	case model.DoneArchiveNever, model.DoneArchiveImmediately, model.DoneArchiveAfter1Day, model.DoneArchiveAfter7Days, model.DoneArchiveAfter30Days, model.DoneArchiveAfter90Days:
		return value, nil
	default:
		return "", errors.New("Done archive policy must be never, immediately, after_1_day, after_7_days, after_30_days, or after_90_days")
	}
}

func normalizeRemotePublishMode(value string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		value = model.RemotePublishManual
	}
	switch value {
	case model.RemotePublishManual, model.RemotePublishPullRequest, model.RemotePublishPushBase:
		return value, nil
	default:
		return "", errors.New("remote publish mode must be manual, pull_request, or push_base")
	}
}

func doneArchiveDelay(policy string) (time.Duration, bool) {
	switch policy {
	case model.DoneArchiveImmediately:
		return 0, true
	case model.DoneArchiveAfter1Day:
		return 24 * time.Hour, true
	case model.DoneArchiveAfter7Days:
		return 7 * 24 * time.Hour, true
	case model.DoneArchiveAfter30Days:
		return 30 * 24 * time.Hour, true
	case model.DoneArchiveAfter90Days:
		return 90 * 24 * time.Hour, true
	default:
		return 0, false
	}
}

func hydrateBoard(item model.Board) model.Board {
	if item.DoneArchivePolicy == "" {
		item.DoneArchivePolicy = model.DoneArchiveNever
	}
	if item.RemotePublishMode == "" {
		item.RemotePublishMode = model.RemotePublishManual
	}
	item.Lanes = model.WorkflowLanes(item.Workflow)
	return item
}

func (s *Store) CreateBoard(input CreateBoardInput) (model.Board, error) {
	workflow, err := normalizeWorkflow(input.Workflow)
	if err != nil {
		return model.Board{}, err
	}
	if strings.TrimSpace(input.Name) == "" {
		return model.Board{}, errors.New("board name is required")
	}
	archivePolicy, err := normalizeDoneArchivePolicy(input.DoneArchivePolicy)
	if err != nil {
		return model.Board{}, err
	}
	remotePublishMode, err := normalizeRemotePublishMode(input.RemotePublishMode)
	if err != nil {
		return model.Board{}, err
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Board{}, err
	}
	defer release()
	project, err := s.ResolveProject(input.Project)
	if err != nil {
		return model.Board{}, err
	}
	now := timestamp()
	baseRemote := strings.TrimSpace(input.BaseRemote)
	if baseRemote == "" {
		baseRemote = strings.TrimSpace(project.BaseRemote)
	}
	item := model.Board{ID: newID("b_"), ProjectID: project.ID, Name: strings.TrimSpace(input.Name), Workflow: workflow, Description: strings.TrimSpace(input.Description), DoneArchivePolicy: archivePolicy, BaseRemote: baseRemote, RemotePublishMode: remotePublishMode, CreatedAt: now, UpdatedAt: now}
	err = s.writeBoard(item)
	return hydrateBoard(item), err
}

func (s *Store) RenameBoard(ref, name string) (model.Board, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return model.Board{}, errors.New("board name is required")
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Board{}, err
	}
	defer release()
	board, err := s.ResolveBoard("", ref)
	if err != nil {
		return model.Board{}, err
	}
	if board.Name == name {
		return board, nil
	}
	board.Name, board.UpdatedAt = name, timestamp()
	return s.saveBoard(board)
}

func (s *Store) UpdateBoardDoneArchivePolicy(ref, policy string) (model.Board, error) {
	policy, err := normalizeDoneArchivePolicy(policy)
	if err != nil {
		return model.Board{}, err
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Board{}, err
	}
	defer release()
	board, err := s.ResolveBoard("", ref)
	if err != nil {
		return model.Board{}, err
	}
	board.DoneArchivePolicy, board.UpdatedAt = policy, timestamp()
	return s.saveBoard(board)
}

func (s *Store) UpdateBoardGitSettings(ref, baseRemote, remotePublishMode string) (model.Board, error) {
	remotePublishMode, err := normalizeRemotePublishMode(remotePublishMode)
	if err != nil {
		return model.Board{}, err
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Board{}, err
	}
	defer release()
	board, err := s.ResolveBoard("", ref)
	if err != nil {
		return model.Board{}, err
	}
	board.BaseRemote = strings.TrimSpace(baseRemote)
	board.RemotePublishMode = remotePublishMode
	board.UpdatedAt = timestamp()
	return s.saveBoard(board)
}

func (s *Store) UpdateBoardPromptTemplate(ref, template string) (model.Board, error) {
	template = strings.TrimSpace(template)
	if template != "" {
		if err := dieterprompt.ValidateContextTemplate(template); err != nil {
			return model.Board{}, err
		}
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Board{}, err
	}
	defer release()
	board, err := s.ResolveBoard("", ref)
	if err != nil {
		return model.Board{}, err
	}
	board.PromptTemplate, board.UpdatedAt = template, timestamp()
	return s.saveBoard(board)
}

func (s *Store) listBoards() ([]model.Board, error) {
	boards, err := s.sharedBoards()
	active := boards[:0]
	for _, board := range boards {
		if !board.Retired {
			active = append(active, board)
		}
	}
	return active, err
}

func (s *Store) ListBoards(projectRef string) ([]model.Board, error) {
	projectID := ""
	activeProjects := map[string]bool{}
	if projectRef != "" {
		project, err := s.ResolveProject(projectRef)
		if err != nil {
			return nil, err
		}
		projectID = project.ID
	} else {
		projects, err := s.listProjects()
		if err != nil {
			return nil, err
		}
		for _, project := range projects {
			if !project.Archived {
				activeProjects[project.ID] = true
			}
		}
	}
	items, err := s.listBoards()
	if err != nil {
		return nil, err
	}
	result := make([]model.Board, 0, len(items))
	for _, item := range items {
		if projectID != "" && item.ProjectID != projectID {
			continue
		}
		if projectID == "" && !activeProjects[item.ProjectID] {
			continue
		}
		result = append(result, item)
	}
	return result, nil
}

func (s *Store) ResolveBoard(projectRef, ref string) (model.Board, error) {
	boards, err := s.ListBoards(projectRef)
	if err != nil {
		return model.Board{}, err
	}
	if ref == "" && len(boards) == 1 {
		return boards[0], nil
	}
	for _, item := range boards {
		if matchRef(ref, item.ID, item.Name) {
			return item, nil
		}
	}
	return model.Board{}, fmt.Errorf("board %q: %w", ref, ErrNotFound)
}

func (s *Store) UpdateBoardHostnames(ref string, values []string, appendValues bool) (model.Board, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.Board{}, err
	}
	defer release()
	board, err := s.ResolveBoard("", ref)
	if err != nil {
		return model.Board{}, err
	}
	if appendValues {
		values = append(append([]string(nil), board.Hostnames...), values...)
	}
	board.Hostnames, err = normalizeProjectHostnames(values)
	if err != nil {
		return model.Board{}, err
	}
	board.UpdatedAt = timestamp()
	return s.saveBoard(board)
}
