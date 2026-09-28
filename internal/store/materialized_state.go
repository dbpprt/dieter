package store

import (
	"context"
	"errors"
	"github.com/dbpprt/dieter/internal/model"
	"os"
	"sort"
	"strings"
	"time"
)

// Public mutations retain the central Store write lock and journal transaction.
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
	allBoards, err := s.sharedBoards()
	if err != nil {
		return model.State{}, err
	}
	for _, board := range allBoards {
		if board.ProjectID == project.ID && board.Retired {
			state.RetiredBoards = append(state.RetiredBoards, board)
		}
	}
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
// each domain directory. WatchSync previously called State once per project;
// every call rescanned every project, board, and card, making one
// daemon-wide delta quadratic in the number of projects.
func (s *Store) GlobalState() (model.State, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	state, _, err := s.GlobalStateContext(ctx)
	return state, err
}

// GlobalStateContext captures a committed workspace revision. A bounded lock
// acquisition replaces the unbounded "scan until the cursor stops moving"
// loop. Conversation-only commits reuse the immutable metadata projection.
func (s *Store) GlobalStateContext(ctx context.Context) (model.State, SyncCursor, error) {
	if err := s.globalStateMu.LockContext(ctx); err != nil {
		return model.State{}, SyncCursor{}, err
	}
	defer s.globalStateMu.Unlock()
	release, err := s.beginWriteLockContext(ctx)
	if err != nil {
		return model.State{}, SyncCursor{}, err
	}
	defer release()
	if err := s.recoverSyncMutation(); err != nil {
		return model.State{}, SyncCursor{}, err
	}
	cursor, _, err := s.SyncEvents(^uint64(0), 1)
	if err != nil {
		return model.State{}, SyncCursor{}, err
	}
	metadata, err := os.ReadFile(s.syncMetadataPath())
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return model.State{}, SyncCursor{}, err
	}
	key := cursor.Epoch + ":" + string(metadata)
	// Old writers do not publish metadata-highwater; their newer highwater must
	// invalidate instead of accidentally reusing a new writer's cache.
	if s.globalStateSnapshot != nil && s.globalStateMetadataKey == key && s.globalStateCursor.Sequence <= cursor.Sequence {
		eventsCursor, events, err := s.SyncEvents(s.globalStateCursor.Sequence, 256)
		if err != nil {
			return model.State{}, SyncCursor{}, err
		}
		reusable := len(events) == 0 || events[len(events)-1].Sequence == eventsCursor.Sequence
		for _, event := range events {
			if event.Kind != "conversation_changed" {
				reusable = false
			}
		}
		if reusable {
			s.globalStateCursor = cursor
			return cloneState(*s.globalStateSnapshot), cursor, nil
		}
	}
	if err := ctx.Err(); err != nil {
		return model.State{}, SyncCursor{}, err
	}
	result, err := s.materializeGlobalStateContext(ctx)
	if err != nil {
		return model.State{}, SyncCursor{}, err
	}
	if err := ctx.Err(); err != nil {
		return model.State{}, SyncCursor{}, err
	}
	cached := cloneState(result)
	s.globalStateSnapshot = &cached
	s.globalStateCursor = cursor
	s.globalStateMetadataKey = key
	return result, cursor, nil
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
		if board.Retired {
			result.RetiredBoards = append(result.RetiredBoards, board)
			continue
		}
		boardsByProject[board.ProjectID] = append(boardsByProject[board.ProjectID], board)
	}
	cardsByProject := make(map[string][]model.Card, len(projects))
	chatsByProject := make(map[string][]model.Card, len(projects))
	for _, card := range cards {
		if card.Archived {
			result.ArchivedItemIDs = append(result.ArchivedItemIDs, card.ID)
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
			result.ArchivedProjectIDs = append(result.ArchivedProjectIDs, project.ID)
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
	sort.Strings(result.ArchivedItemIDs)
	sort.Strings(result.ArchivedProjectIDs)
	return result, nil
}

func cloneState(value model.State) model.State {
	result := value
	result.RetiredBoards = append([]model.Board(nil), value.RetiredBoards...)
	result.ArchivedProjectIDs = append([]string(nil), value.ArchivedProjectIDs...)
	result.ArchivedItemIDs = append([]string(nil), value.ArchivedItemIDs...)
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
