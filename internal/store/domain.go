package store

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
)

type CreateProjectInput struct {
	ID, Name, Path, Summary, Prompt string
}

func validFileID(id string) bool {
	id = strings.TrimSpace(id)
	return id != "" && id != "." && id != ".." && !strings.ContainsAny(id, `/\\`)
}

func (s *Store) CreateProject(input CreateProjectInput) (model.Project, error) {
	if strings.TrimSpace(input.ID) == "" {
		input.ID = newID("p_")
	}
	if !validFileID(input.ID) {
		return model.Project{}, errors.New("project ID is invalid")
	}
	path, err := normalizePath(input.Path)
	if err != nil {
		return model.Project{}, err
	}
	name := strings.TrimSpace(input.Name)
	if name == "" {
		name = filepath.Base(path)
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Project{}, err
	}
	defer release()
	if err := s.Ensure(); err != nil {
		return model.Project{}, err
	}
	projects, err := s.listProjects()
	if err != nil {
		return model.Project{}, err
	}
	for _, candidate := range projects {
		if candidate.ID == input.ID || candidate.Path == path {
			return model.Project{}, fmt.Errorf("project already registered as %s", candidate.ID)
		}
	}
	now := timestamp()
	project := model.Project{ID: input.ID, Name: name, Path: path, Summary: strings.TrimSpace(input.Summary), Prompt: strings.TrimSpace(input.Prompt), CreatedAt: now, UpdatedAt: now}
	return project, writeMarkdown(filepath.Join(s.projectDir(), project.ID+".md"), project, project.Prompt)
}

func (s *Store) listProjects() ([]model.Project, error) {
	paths, err := listMarkdown(s.projectDir())
	if err != nil {
		return nil, err
	}
	result := make([]model.Project, 0, len(paths))
	for _, path := range paths {
		var item model.Project
		body, readErr := readMarkdown(path, &item)
		if readErr != nil {
			return nil, readErr
		}
		item.Prompt = body
		result = append(result, item)
	}
	sort.Slice(result, func(i, j int) bool { return strings.ToLower(result[i].Name) < strings.ToLower(result[j].Name) })
	return result, nil
}

func (s *Store) ListProjects() ([]model.Project, error) {
	projects, err := s.listProjects()
	if err != nil {
		return nil, err
	}
	projects = filterProjectsByArchived(projects, false)
	return s.enrichProjects(projects)
}

func (s *Store) ListArchivedProjects() ([]model.Project, error) {
	projects, err := s.listProjects()
	if err != nil {
		return nil, err
	}
	projects = filterProjectsByArchived(projects, true)
	return s.enrichProjects(projects)
}

func filterProjectsByArchived(projects []model.Project, archived bool) []model.Project {
	result := make([]model.Project, 0, len(projects))
	for _, project := range projects {
		if project.Archived == archived {
			result = append(result, project)
		}
	}
	return result
}

func (s *Store) enrichProjects(projects []model.Project) ([]model.Project, error) {
	boards, boardErr := s.listBoards()
	if boardErr != nil {
		return nil, boardErr
	}
	cards, cardErr := s.listCards()
	if cardErr != nil {
		return nil, cardErr
	}
	for i := range projects {
		for _, board := range boards {
			if board.ProjectID == projects[i].ID {
				projects[i].BoardCount++
			}
		}
		for _, card := range cards {
			if card.ProjectID == projects[i].ID && !card.Archived {
				if card.Scope == model.ConversationScopeChat {
					projects[i].ChatCount++
				} else {
					projects[i].CardCount++
				}
			}
		}
	}
	return projects, nil
}

func (s *Store) ResolveProject(ref string) (model.Project, error) {
	projects, err := s.listProjects()
	if err != nil {
		return model.Project{}, err
	}
	return resolveProject(filterProjectsByArchived(projects, false), ref)
}

func (s *Store) ResolveProjectIncludingArchived(ref string) (model.Project, error) {
	projects, err := s.listProjects()
	if err != nil {
		return model.Project{}, err
	}
	return resolveProject(projects, ref)
}

func resolveProject(projects []model.Project, ref string) (model.Project, error) {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		cwd, _ := os.Getwd()
		var matches []model.Project
		for _, project := range projects {
			rel, relErr := filepath.Rel(project.Path, cwd)
			if relErr == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
				matches = append(matches, project)
			}
		}
		if len(matches) > 0 {
			sort.Slice(matches, func(i, j int) bool { return len(matches[i].Path) > len(matches[j].Path) })
			return matches[0], nil
		}
		if len(projects) == 1 {
			return projects[0], nil
		}
		return model.Project{}, errors.New("project is required; pass --project or run inside a registered project")
	}
	for _, project := range projects {
		if matchRef(ref, project.ID, project.Name) || project.Path == ref {
			return project, nil
		}
	}
	return model.Project{}, fmt.Errorf("project %q: %w", ref, ErrNotFound)
}

func (s *Store) ArchiveProject(ref string, archived bool) (model.Project, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.Project{}, err
	}
	defer release()
	project, err := s.ResolveProjectIncludingArchived(ref)
	if err != nil {
		return model.Project{}, err
	}
	if archived {
		leases, leaseErr := activeRuntimeLeases(filepath.Join(s.runtimeDir(), "leases"))
		if leaseErr != nil {
			return model.Project{}, leaseErr
		}
		for _, lease := range leases {
			if lease.ProjectID == project.ID {
				return model.Project{}, fmt.Errorf("%w on card %s", ErrCardActive, lease.CardID)
			}
		}
	}
	project.Archived = archived
	project.UpdatedAt = timestamp()
	return project, writeMarkdown(filepath.Join(s.projectDir(), project.ID+".md"), project, project.Prompt)
}

func (s *Store) UpdateProject(ref string, name, summary, prompt *string, paths ...*string) (model.Project, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.Project{}, err
	}
	defer release()
	project, err := s.ResolveProject(ref)
	if err != nil {
		return model.Project{}, err
	}
	if name != nil && strings.TrimSpace(*name) != "" {
		project.Name = strings.TrimSpace(*name)
	}
	if summary != nil {
		project.Summary = strings.TrimSpace(*summary)
	}
	if prompt != nil {
		project.Prompt = strings.TrimSpace(*prompt)
	}
	if len(paths) > 0 && paths[0] != nil {
		path, normalizeErr := normalizePath(*paths[0])
		if normalizeErr != nil {
			return model.Project{}, normalizeErr
		}
		projects, listErr := s.listProjects()
		if listErr != nil {
			return model.Project{}, listErr
		}
		for _, candidate := range projects {
			if candidate.ID != project.ID && candidate.Path == path {
				return model.Project{}, fmt.Errorf("project path is already registered as %s", candidate.ID)
			}
		}
		project.Path = path
	}
	project.UpdatedAt = timestamp()
	return project, writeMarkdown(filepath.Join(s.projectDir(), project.ID+".md"), project, project.Prompt)
}

func (s *Store) UpdateProjectPromptTemplate(ref, template string) (model.Project, error) {
	template = strings.TrimSpace(template)
	if template != "" {
		if err := dieterprompt.ValidateContextTemplate(template); err != nil {
			return model.Project{}, err
		}
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Project{}, err
	}
	defer release()
	project, err := s.ResolveProject(ref)
	if err != nil {
		return model.Project{}, err
	}
	project.PromptTemplate, project.UpdatedAt = template, timestamp()
	return project, writeMarkdown(filepath.Join(s.projectDir(), project.ID+".md"), project, project.Prompt)
}

type CreateBoardInput struct{ Project, Name, Workflow, Description, DoneArchivePolicy string }

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
	item.Lanes = model.WorkflowLanes(item.Workflow)
	return item
}

func (s *Store) CreateBoard(input CreateBoardInput) (model.Board, error) {
	project, err := s.ResolveProject(input.Project)
	if err != nil {
		return model.Board{}, err
	}
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
	release, err := s.beginWrite()
	if err != nil {
		return model.Board{}, err
	}
	defer release()
	now := timestamp()
	item := model.Board{ID: newID("b_"), ProjectID: project.ID, Name: strings.TrimSpace(input.Name), Workflow: workflow, Description: strings.TrimSpace(input.Description), DoneArchivePolicy: archivePolicy, CreatedAt: now, UpdatedAt: now}
	err = writeMarkdown(filepath.Join(s.boardDir(), item.ID+".md"), item, item.Description)
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
	return board, writeMarkdown(filepath.Join(s.boardDir(), board.ID+".md"), board, board.Description)
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
	return board, writeMarkdown(filepath.Join(s.boardDir(), board.ID+".md"), board, board.Description)
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
	return hydrateBoard(board), writeMarkdown(filepath.Join(s.boardDir(), board.ID+".md"), board, board.Description)
}

func (s *Store) listBoards() ([]model.Board, error) {
	paths, err := listMarkdown(s.boardDir())
	if err != nil {
		return nil, err
	}
	result := make([]model.Board, 0, len(paths))
	for _, path := range paths {
		var item model.Board
		body, readErr := readMarkdown(path, &item)
		if readErr != nil {
			return nil, readErr
		}
		item.Description = body
		result = append(result, hydrateBoard(item))
	}
	sort.Slice(result, func(i, j int) bool { return strings.ToLower(result[i].Name) < strings.ToLower(result[j].Name) })
	return result, nil
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

type CreateCardInput struct {
	Project, Board, ID, Lane, Title, Prompt, Provider, Model, Effort string
	LabelIDs                                                         []string
	ProviderOptions                                                  map[string]string
	Origin                                                           *model.CardOrigin
}

func cloneStringMap(values map[string]string) map[string]string {
	if len(values) == 0 {
		return nil
	}
	result := make(map[string]string, len(values))
	for key, value := range values {
		result[key] = value
	}
	return result
}

func stringMapsEqual(left, right map[string]string) bool {
	if len(left) != len(right) {
		return false
	}
	for key, value := range left {
		if right[key] != value {
			return false
		}
	}
	return true
}

type CardFilter struct {
	Project, Board, Lane, Runtime, Query, Label, Scope string
	Limit                                              int
	IncludeArchived                                    bool
}

func validLane(board model.Board, lane string) bool {
	for _, candidate := range board.Lanes {
		if candidate.ID == strings.ToLower(lane) || strings.EqualFold(candidate.Name, lane) {
			return true
		}
	}
	return false
}

func canonicalLane(board model.Board, lane string) string {
	for _, candidate := range board.Lanes {
		if candidate.ID == strings.ToLower(lane) || strings.EqualFold(candidate.Name, lane) {
			return candidate.ID
		}
	}
	return ""
}

func (s *Store) CreateCard(input CreateCardInput) (model.Card, error) {
	if strings.TrimSpace(input.ID) == "" {
		input.ID = newID("c_")
	}
	if !validFileID(input.ID) {
		return model.Card{}, errors.New("card ID is invalid")
	}
	project, err := s.ResolveProject(input.Project)
	if err != nil {
		return model.Card{}, err
	}
	board, err := s.ResolveBoard(project.ID, input.Board)
	if err != nil {
		return model.Card{}, err
	}
	lane := input.Lane
	if lane == "" {
		lane = model.LaneTodo
	}
	if !validLane(board, lane) {
		return model.Card{}, fmt.Errorf("lane %q is not part of the %s workflow", lane, board.Workflow)
	}
	if strings.TrimSpace(input.Title) == "" {
		return model.Card{}, errors.New("card title is required")
	}
	labelIDs, err := validateCardLabels(board, input.LabelIDs)
	if err != nil {
		return model.Card{}, err
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	if _, err := os.Stat(filepath.Join(s.cardDir(), input.ID+".md")); err == nil {
		return model.Card{}, fmt.Errorf("card already exists")
	}
	existing, _ := s.ListCards(CardFilter{Board: board.ID, Lane: canonicalLane(board, lane)})
	now := timestamp()
	item := model.Card{ID: input.ID, Scope: model.ConversationScopeBoard, ProjectID: project.ID, BoardID: board.ID, Lane: canonicalLane(board, lane), Position: int64(len(existing)+1) * 1024, Title: strings.TrimSpace(input.Title), InitialPrompt: strings.TrimSpace(input.Prompt), Provider: input.Provider, Model: input.Model, Effort: input.Effort, ProviderOptions: cloneStringMap(input.ProviderOptions), Runtime: "idle", RuntimeUpdatedAt: now, LastActivityAt: now, PhaseChangedAt: now, CreatedAt: now, UpdatedAt: now, LabelIDs: labelIDs, Origin: input.Origin}
	return item, writeMarkdown(filepath.Join(s.cardDir(), item.ID+".md"), item, item.InitialPrompt)
}

func (s *Store) CreateChat(input CreateCardInput) (model.Card, error) {
	if strings.TrimSpace(input.ID) == "" {
		input.ID = newID("c_")
	}
	if !validFileID(input.ID) {
		return model.Card{}, errors.New("chat ID is invalid")
	}
	project, err := s.ResolveProject(input.Project)
	if err != nil {
		return model.Card{}, err
	}
	title := strings.TrimSpace(input.Title)
	if title == "" {
		return model.Card{}, errors.New("chat title is required")
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	if _, err := os.Stat(filepath.Join(s.cardDir(), input.ID+".md")); err == nil {
		return model.Card{}, errors.New("chat already exists")
	}
	existing, _ := s.ListCards(CardFilter{Project: project.ID, Scope: model.ConversationScopeChat})
	now := timestamp()
	item := model.Card{ID: input.ID, Scope: model.ConversationScopeChat, ProjectID: project.ID, Position: int64(len(existing)+1) * 1024, Title: title, InitialPrompt: strings.TrimSpace(input.Prompt), Provider: input.Provider, Model: input.Model, Effort: input.Effort, ProviderOptions: cloneStringMap(input.ProviderOptions), Runtime: "idle", RuntimeUpdatedAt: now, LastActivityAt: now, PhaseChangedAt: now, CreatedAt: now, UpdatedAt: now}
	return item, writeMarkdown(filepath.Join(s.cardDir(), item.ID+".md"), item, item.InitialPrompt)
}

func (s *Store) listCards() ([]model.Card, error) {
	paths, err := listMarkdown(s.cardDir())
	if err != nil {
		return nil, err
	}
	result := make([]model.Card, 0, len(paths))
	for _, path := range paths {
		var item model.Card
		body, readErr := readMarkdown(path, &item)
		if readErr != nil {
			return nil, readErr
		}
		item.InitialPrompt = body
		if item.Scope == "" {
			if item.BoardID == "" {
				item.Scope = model.ConversationScopeChat
			} else {
				item.Scope = model.ConversationScopeBoard
			}
		}
		comments, _ := s.ListComments(item.ID, 0)
		item.CommentCount = len(comments)
		result = append(result, item)
	}
	return result, nil
}

func (s *Store) ListCards(filter CardFilter) ([]model.Card, error) {
	projectID, boardID := "", ""
	activeProjects := map[string]bool{}
	if filter.Project != "" {
		project, err := s.ResolveProject(filter.Project)
		if err != nil {
			return nil, err
		}
		projectID = project.ID
	}
	if filter.Board != "" {
		board, err := s.ResolveBoard(projectID, filter.Board)
		if err != nil {
			return nil, err
		}
		boardID = board.ID
	}
	if projectID == "" {
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
	items, err := s.listCards()
	if err != nil {
		return nil, err
	}
	result := make([]model.Card, 0, len(items))
	for _, item := range items {
		if projectID == "" && !activeProjects[item.ProjectID] || projectID != "" && item.ProjectID != projectID || boardID != "" && item.BoardID != boardID || filter.Scope != "" && item.Scope != filter.Scope || filter.Lane != "" && item.Lane != strings.ToLower(filter.Lane) || filter.Runtime != "" && item.Runtime != filter.Runtime {
			continue
		}
		if item.Archived && !filter.IncludeArchived {
			continue
		}
		if filter.Label != "" && !containsString(item.LabelIDs, filter.Label) {
			continue
		}
		if filter.Query != "" && !containsFold(item.Title+"\n"+item.InitialPrompt+"\n"+item.Summary, filter.Query) {
			continue
		}
		result = append(result, item)
	}
	sort.SliceStable(result, func(i, j int) bool {
		if result[i].Lane != result[j].Lane {
			return result[i].Lane < result[j].Lane
		}
		return result[i].Position < result[j].Position
	})
	if filter.Limit > 0 && len(result) > filter.Limit {
		result = result[:filter.Limit]
	}
	return result, nil
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func validateCardLabels(board model.Board, requested []string) ([]string, error) {
	result := make([]string, 0, len(requested))
	for _, ref := range requested {
		ref = strings.TrimSpace(ref)
		if ref == "" || containsString(result, ref) {
			continue
		}
		matched := ""
		for _, label := range board.Labels {
			if ref == label.ID || strings.EqualFold(ref, label.Name) {
				matched = label.ID
				break
			}
		}
		if matched == "" {
			return nil, fmt.Errorf("label %q is not defined on board %s", ref, board.Name)
		}
		if !containsString(result, matched) {
			result = append(result, matched)
		}
	}
	return result, nil
}

func (s *Store) CreateBoardLabel(boardRef, name, color string, instructions ...string) (model.Board, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return model.Board{}, errors.New("label name is required")
	}
	if color == "" {
		color = "#6558df"
	}
	if len(color) != 7 || color[0] != '#' {
		return model.Board{}, errors.New("label color must be a hex color such as #6558df")
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Board{}, err
	}
	defer release()
	board, err := s.ResolveBoard("", boardRef)
	if err != nil {
		return model.Board{}, err
	}
	for _, label := range board.Labels {
		if strings.EqualFold(label.Name, name) {
			return model.Board{}, fmt.Errorf("label %q already exists", name)
		}
	}
	prompt := ""
	if len(instructions) > 0 {
		prompt = strings.TrimSpace(instructions[0])
	}
	if len(prompt) > dieterprompt.MaxTemplateBytes {
		return model.Board{}, errors.New("label instructions exceed 32 KiB")
	}
	board.Labels = append(board.Labels, model.Label{ID: newID("label_"), Name: name, Color: color, Instructions: prompt})
	board.UpdatedAt = timestamp()
	err = writeMarkdown(filepath.Join(s.boardDir(), board.ID+".md"), board, board.Description)
	return hydrateBoard(board), err
}

func (s *Store) UpdateBoardLabel(boardRef, labelID, name, color, instructions string) (model.Board, error) {
	name, color, instructions = strings.TrimSpace(name), strings.TrimSpace(color), strings.TrimSpace(instructions)
	if name == "" {
		return model.Board{}, errors.New("label name is required")
	}
	if len(color) != 7 || color[0] != '#' {
		return model.Board{}, errors.New("label color must be a hex color such as #6558df")
	}
	if len(instructions) > dieterprompt.MaxTemplateBytes {
		return model.Board{}, errors.New("label instructions exceed 32 KiB")
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Board{}, err
	}
	defer release()
	board, err := s.ResolveBoard("", boardRef)
	if err != nil {
		return model.Board{}, err
	}
	found := false
	for index := range board.Labels {
		if board.Labels[index].ID == labelID {
			board.Labels[index].Name, board.Labels[index].Color, board.Labels[index].Instructions = name, color, instructions
			found = true
			continue
		}
		if strings.EqualFold(board.Labels[index].Name, name) {
			return model.Board{}, fmt.Errorf("label %q already exists", name)
		}
	}
	if !found {
		return model.Board{}, fmt.Errorf("label %q: %w", labelID, ErrNotFound)
	}
	board.UpdatedAt = timestamp()
	return hydrateBoard(board), writeMarkdown(filepath.Join(s.boardDir(), board.ID+".md"), board, board.Description)
}

func (s *Store) DeleteBoardLabel(boardRef, labelID string) (model.Board, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.Board{}, err
	}
	defer release()
	board, err := s.ResolveBoard("", boardRef)
	if err != nil {
		return model.Board{}, err
	}
	found := false
	labels := board.Labels[:0]
	for _, label := range board.Labels {
		if label.ID == labelID {
			found = true
			continue
		}
		labels = append(labels, label)
	}
	if !found {
		return model.Board{}, fmt.Errorf("label %q: %w", labelID, ErrNotFound)
	}
	board.Labels = labels
	board.UpdatedAt = timestamp()
	if err := writeMarkdown(filepath.Join(s.boardDir(), board.ID+".md"), board, board.Description); err != nil {
		return model.Board{}, err
	}
	cards, _ := s.ListCards(CardFilter{Board: board.ID})
	for _, card := range cards {
		if containsString(card.LabelIDs, labelID) {
			next := card.LabelIDs[:0]
			for _, id := range card.LabelIDs {
				if id != labelID {
					next = append(next, id)
				}
			}
			card.LabelIDs, card.UpdatedAt = next, timestamp()
			if err := s.writeCard(card); err != nil {
				return model.Board{}, err
			}
		}
	}
	return hydrateBoard(board), nil
}

func (s *Store) SetCardLabels(cardRef string, requested []string) (model.Card, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	card, err := s.ResolveCard(cardRef)
	if err != nil {
		return model.Card{}, err
	}
	if card.Scope != model.ConversationScopeBoard {
		return model.Card{}, errors.New("labels are only available for board cards")
	}
	board, err := s.ResolveBoard(card.ProjectID, card.BoardID)
	if err != nil {
		return model.Card{}, err
	}
	labels, err := validateCardLabels(board, requested)
	if err != nil {
		return model.Card{}, err
	}
	card.LabelIDs, card.UpdatedAt = labels, timestamp()
	return card, s.writeCard(card)
}

func (s *Store) ResolveCard(ref string) (model.Card, error) {
	items, err := s.listCards()
	if err != nil {
		return model.Card{}, err
	}
	for _, item := range items {
		if ref == item.ID {
			return item, nil
		}
	}
	return model.Card{}, fmt.Errorf("card %q: %w", ref, ErrNotFound)
}

func (s *Store) writeCard(item model.Card) error {
	return writeMarkdown(filepath.Join(s.cardDir(), item.ID+".md"), item, item.InitialPrompt)
}

func (s *Store) MoveCard(ref, lane string, position *int64) (model.Card, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	if item.Scope != model.ConversationScopeBoard {
		return model.Card{}, errors.New("chat conversations do not belong to board lanes")
	}
	board, err := s.ResolveBoard(item.ProjectID, item.BoardID)
	if err != nil {
		return model.Card{}, err
	}
	if !validLane(board, lane) {
		return model.Card{}, fmt.Errorf("lane %q is not part of the %s workflow", lane, board.Workflow)
	}
	nextLane := canonicalLane(board, lane)
	laneChanged := item.Lane != nextLane
	item.Lane = nextLane
	if laneChanged {
		item.DoneArchiveExempt = false
	}
	if position != nil {
		item.Position = *position
	} else {
		peers, _ := s.ListCards(CardFilter{Board: board.ID, Lane: item.Lane})
		item.Position = int64(len(peers)+1) * 1024
	}
	item.UpdatedAt = timestamp()
	if laneChanged {
		item.PhaseChangedAt = item.UpdatedAt
	}
	return item, s.writeCard(item)
}

type CardCacheInput struct {
	Title, Provider, Model, Runtime, Summary string
	Effort                                   *string
	ProviderOptions                          map[string]string
}

func (s *Store) UpdateCardCache(ref string, input CardCacheInput) (model.Card, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	title := item.Title
	if input.Title != "" {
		title = input.Title
	}
	provider, modelName, effort, runtime, summary := item.Provider, item.Model, item.Effort, item.Runtime, item.Summary
	providerOptions := item.ProviderOptions
	if input.Provider != "" {
		provider = input.Provider
	}
	if input.Model != "" {
		modelName = input.Model
	}
	if input.Effort != nil {
		effort = *input.Effort
	}
	if input.ProviderOptions != nil {
		providerOptions = cloneStringMap(input.ProviderOptions)
	}
	if input.Runtime != "" {
		runtime = input.Runtime
	}
	if input.Summary != "" {
		summary = input.Summary
	}
	if title == item.Title && provider == item.Provider && modelName == item.Model && effort == item.Effort && stringMapsEqual(providerOptions, item.ProviderOptions) && runtime == item.Runtime && summary == item.Summary {
		return item, nil
	}
	item.Title = title
	item.Provider, item.Model, item.Effort, item.ProviderOptions, item.Runtime, item.Summary = provider, modelName, effort, providerOptions, runtime, summary
	item.RuntimeUpdatedAt, item.UpdatedAt = timestamp(), timestamp()
	return item, s.writeCard(item)
}

func (s *Store) MarkPromptSent(ref string) (model.Card, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	if item.InitialPromptSentAt == "" {
		item.InitialPromptSentAt = timestamp()
	}
	if item.Scope == model.ConversationScopeBoard {
		item.Lane = model.LaneRunning
	}
	item.Runtime, item.PhaseChangedAt, item.UpdatedAt = "starting", timestamp(), timestamp()
	return item, s.writeCard(item)
}

func (s *Store) RenameCard(ref, title string) (model.Card, error) {
	if strings.TrimSpace(title) == "" {
		return model.Card{}, errors.New("title is required")
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	if item.LastActivityAt == "" {
		item.LastActivityAt = item.UpdatedAt
	}
	item.Title, item.UpdatedAt = strings.TrimSpace(title), timestamp()
	return item, s.writeCard(item)
}

func (s *Store) UpdateCard(ref, title, initialPrompt string) (model.Card, error) {
	title, initialPrompt = strings.TrimSpace(title), strings.TrimSpace(initialPrompt)
	if title == "" {
		return model.Card{}, errors.New("title is required")
	}
	if initialPrompt == "" {
		return model.Card{}, errors.New("agent task is required")
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	if initialPrompt != item.InitialPrompt && item.InitialPromptSentAt != "" {
		return model.Card{}, errors.New("agent task can only be edited before it is sent")
	}
	if title == item.Title && initialPrompt == item.InitialPrompt {
		return item, nil
	}
	if item.LastActivityAt == "" {
		item.LastActivityAt = item.UpdatedAt
	}
	item.Title, item.InitialPrompt, item.UpdatedAt = title, initialPrompt, timestamp()
	return item, s.writeCard(item)
}

func (s *Store) PinChat(ref string, pinned bool) (model.Card, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	if item.Scope != model.ConversationScopeChat {
		return model.Card{}, errors.New("only standalone chats can be pinned")
	}
	if item.LastActivityAt == "" {
		item.LastActivityAt = item.UpdatedAt
	}
	item.Pinned, item.UpdatedAt = pinned, timestamp()
	return item, s.writeCard(item)
}

func (s *Store) ArchiveCard(ref string, archived bool) (model.Card, error) {
	release, err := s.beginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	if archived {
		leases, leaseErr := activeRuntimeLeases(filepath.Join(s.runtimeDir(), "leases"))
		if leaseErr != nil {
			return model.Card{}, leaseErr
		}
		for _, lease := range leases {
			if lease.CardID == item.ID {
				return model.Card{}, ErrCardActive
			}
		}
	}
	item.Archived = archived
	item.DoneArchiveExempt = !archived && item.Scope == model.ConversationScopeBoard && item.Lane == model.LaneDone
	item.UpdatedAt = timestamp()
	return item, s.writeCard(item)
}

func (s *Store) ArchiveDoneCards(now time.Time) ([]model.Card, error) {
	release, err := s.beginWrite()
	if err != nil {
		return nil, err
	}
	defer release()
	projects, err := s.listProjects()
	if err != nil {
		return nil, err
	}
	activeProjects := make(map[string]bool, len(projects))
	for _, project := range projects {
		if !project.Archived {
			activeProjects[project.ID] = true
		}
	}
	boards, err := s.listBoards()
	if err != nil {
		return nil, err
	}
	delays := make(map[string]time.Duration, len(boards))
	for _, board := range boards {
		if delay, enabled := doneArchiveDelay(board.DoneArchivePolicy); enabled && activeProjects[board.ProjectID] {
			delays[board.ID] = delay
		}
	}
	if len(delays) == 0 {
		return []model.Card{}, nil
	}
	leases, err := activeRuntimeLeases(filepath.Join(s.runtimeDir(), "leases"))
	if err != nil {
		return nil, err
	}
	activeCards := make(map[string]bool, len(leases))
	for _, lease := range leases {
		activeCards[lease.CardID] = true
	}
	cards, err := s.listCards()
	if err != nil {
		return nil, err
	}
	archived := make([]model.Card, 0)
	archivedAt := now.UTC().Format(time.RFC3339Nano)
	for _, card := range cards {
		delay, enabled := delays[card.BoardID]
		if !enabled || card.Scope != model.ConversationScopeBoard || card.Lane != model.LaneDone || card.Archived || card.DoneArchiveExempt || activeCards[card.ID] || card.Runtime == "running" || card.Runtime == "starting" {
			continue
		}
		phaseChangedAt, parseErr := time.Parse(time.RFC3339Nano, card.PhaseChangedAt)
		if parseErr != nil {
			phaseChangedAt, parseErr = time.Parse(time.RFC3339Nano, card.UpdatedAt)
		}
		if parseErr != nil || now.Before(phaseChangedAt.Add(delay)) {
			continue
		}
		card.Archived, card.UpdatedAt = true, archivedAt
		if err := s.writeCard(card); err != nil {
			return archived, err
		}
		archived = append(archived, card)
	}
	return archived, nil
}

func (s *Store) CardDetail(ref string) (model.CardDetail, error) {
	card, err := s.ResolveCard(ref)
	if err != nil {
		return model.CardDetail{}, err
	}
	project, err := s.ResolveProject(card.ProjectID)
	if err != nil {
		return model.CardDetail{}, err
	}
	board := model.Board{}
	if card.Scope == model.ConversationScopeBoard {
		board, err = s.ResolveBoard(project.ID, card.BoardID)
		if err != nil {
			return model.CardDetail{}, err
		}
	}
	comments, err := s.ListComments(card.ID, 0)
	return model.CardDetail{Card: card, Project: project, Board: board, Comments: comments}, err
}

func (s *Store) AddComment(cardRef, body string, author model.Author) (model.Comment, error) {
	if strings.TrimSpace(body) == "" {
		return model.Comment{}, errors.New("comment body is required")
	}
	card, err := s.ResolveCard(cardRef)
	if err != nil {
		return model.Comment{}, err
	}
	if author.Kind == "" {
		author.Kind = "human"
	}
	if author.CardID == "" && author.Kind == "agent" {
		author.CardID, author.ProjectID = card.ID, card.ProjectID
	}
	release, err := s.beginWrite()
	if err != nil {
		return model.Comment{}, err
	}
	defer release()
	now := timestamp()
	item := model.Comment{ID: newID("m_"), CardID: card.ID, Author: author, Body: strings.TrimSpace(body), CreatedAt: now}
	path := filepath.Join(s.commentDir(), card.ID, item.ID+".md")
	return item, writeMarkdown(path, item, item.Body)
}

func (s *Store) ListComments(cardRef string, limit int) ([]model.Comment, error) {
	if cardRef == "" {
		return []model.Comment{}, nil
	}
	paths, err := listMarkdown(filepath.Join(s.commentDir(), cardRef))
	if err != nil {
		return nil, err
	}
	result := make([]model.Comment, 0, len(paths))
	for _, path := range paths {
		var item model.Comment
		body, readErr := readMarkdown(path, &item)
		if readErr != nil {
			return nil, readErr
		}
		item.Body = body
		result = append(result, item)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].CreatedAt < result[j].CreatedAt })
	if limit > 0 && len(result) > limit {
		result = result[len(result)-limit:]
	}
	return result, nil
}

func (s *Store) State(projectRef string, filter CardFilter) (model.State, error) {
	projects, err := s.ListProjects()
	if err != nil {
		return model.State{}, err
	}
	state := model.State{StorePath: s.Root, Projects: projects, Boards: []model.Board{}, Cards: []model.Card{}, Chats: []model.Card{}}
	if len(projects) == 0 {
		if strings.TrimSpace(projectRef) != "" {
			_, err = s.ResolveProject(projectRef)
			return model.State{}, err
		}
		return state, nil
	}
	project, err := s.ResolveProject(projectRef)
	if err != nil && projectRef == "" {
		project = projects[0]
	} else if err != nil {
		return model.State{}, err
	}
	state.Project = &project
	state.Boards, err = s.ListBoards(project.ID)
	if err != nil {
		return model.State{}, err
	}
	filter.Project = project.ID
	filter.Scope = model.ConversationScopeBoard
	state.Cards, err = s.ListCards(filter)
	if err != nil {
		return model.State{}, err
	}
	state.Chats, err = s.ListCards(CardFilter{Project: project.ID, Scope: model.ConversationScopeChat, Query: filter.Query, Runtime: filter.Runtime, Limit: filter.Limit})
	return state, err
}
