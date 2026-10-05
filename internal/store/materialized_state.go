package store

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/model"
)

// Public mutations retain the central Store write lock and change-count transaction.
// Unexported projection helpers run within their caller's existing lock boundary.

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

// GlobalState materializes the active workspace projection in one pass over
// each domain directory.
func (s *Store) GlobalState() (model.State, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return s.GlobalStateContext(ctx)
}

// GlobalStateContext captures a committed workspace revision under the writer
// lock. Conversation text never changes the metadata revision, so streamed
// turns reuse the cached projection.
func (s *Store) GlobalStateContext(ctx context.Context) (model.State, error) {
	if err := s.globalStateMu.LockContext(ctx); err != nil {
		return model.State{}, err
	}
	defer s.globalStateMu.Unlock()
	release, err := s.beginWriteLockContext(ctx)
	if err != nil {
		return model.State{}, err
	}
	defer release()
	if err := s.recoverSyncMutation(); err != nil {
		return model.State{}, err
	}
	revision, err := s.MetadataRevision()
	if err != nil {
		return model.State{}, err
	}
	if s.globalStateSnapshot != nil && s.globalStateRevision == revision {
		return cloneState(*s.globalStateSnapshot), nil
	}
	result, err := s.materializeGlobalStateContext(ctx)
	if err != nil {
		return model.State{}, err
	}
	if err := ctx.Err(); err != nil {
		return model.State{}, err
	}
	cached := cloneState(result)
	s.globalStateSnapshot = &cached
	s.globalStateRevision = revision
	return result, nil
}

func (s *Store) materializeGlobalStateContext(ctx context.Context) (model.State, error) {
	projects, err := s.listProjects()
	if err != nil {
		return model.State{}, err
	}
	boards, err := s.sharedBoards()
	if err != nil {
		return model.State{}, err
	}
	cards, err := s.listCardsContext(ctx, true)
	if err != nil {
		return model.State{}, err
	}

	result := model.State{
		StorePath: s.Root,
		Projects:  []model.Project{},
		Boards:    []model.Board{},
		Cards:     []model.Card{},
		Chats:     []model.Card{},
	}
	boardsByProject := make(map[string][]model.Board, len(projects))
	for _, board := range boards {
		if !board.Retired {
			boardsByProject[board.ProjectID] = append(boardsByProject[board.ProjectID], board)
		}
	}
	cardsByProject := make(map[string][]model.Card, len(projects))
	chatsByProject := make(map[string][]model.Card, len(projects))
	for _, card := range cards {
		if card.Archived {
			continue
		}
		if card.Scope == model.ConversationScopeChat {
			chatsByProject[card.ProjectID] = append(chatsByProject[card.ProjectID], card)
		} else {
			cardsByProject[card.ProjectID] = append(cardsByProject[card.ProjectID], card)
		}
	}
	sortCards := func(items []model.Card) {
		sort.SliceStable(items, func(i, j int) bool {
			if items[i].Lane != items[j].Lane {
				return items[i].Lane < items[j].Lane
			}
			return cardOrderLess(items[i], items[j])
		})
	}
	for projectID := range cardsByProject {
		sortCards(cardsByProject[projectID])
	}
	for projectID := range chatsByProject {
		sortCards(chatsByProject[projectID])
	}
	for _, project := range projects {
		if project.Archived {
			continue
		}
		projectBoards := boardsByProject[project.ID]
		projectCards := cardsByProject[project.ID]
		projectChats := chatsByProject[project.ID]
		project.BoardCount = len(projectBoards)
		project.CardCount = len(projectCards)
		project.ChatCount = len(projectChats)
		result.Projects = append(result.Projects, project)
		result.Boards = append(result.Boards, projectBoards...)
		result.Cards = append(result.Cards, projectCards...)
		result.Chats = append(result.Chats, projectChats...)
	}
	return result, nil
}

func cloneState(value model.State) model.State {
	result := value
	result.Projects = append([]model.Project(nil), value.Projects...)
	result.Boards = append([]model.Board(nil), value.Boards...)
	result.Cards = append([]model.Card(nil), value.Cards...)
	result.Chats = append([]model.Card(nil), value.Chats...)
	if value.Project != nil {
		project := *value.Project
		result.Project = &project
	}
	return result
}
