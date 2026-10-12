package kanban

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/leases"
	"github.com/dbpprt/dieter/internal/store/replica"
)

// Public mutations retain the central Store write lock and change-count transaction.
// Unexported projection helpers run within their caller's existing lock boundary.

type CreateCardInput struct {
	Project, Board, ID, Lane, Title, Prompt, Provider, Model, Effort string
	CheckoutID                                                       string
	WorkspaceMode, WorkspaceBranch, WorkspaceBaseBranch              string
	WorkspaceBaseRemote, RemotePublishMode                           string
	LabelIDs                                                         []string
	ProviderOptions                                                  map[string]string
	Origin                                                           *model.CardOrigin
	VaultAccess                                                      bool
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

func ValidLane(board model.Board, lane string) bool {
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
		input.ID = home.NewID("c_")
	}
	if !home.ValidFileID(input.ID) {
		return model.Card{}, fault.New(fault.Invalid, "card ID is invalid")
	}
	project, err := s.ProjectForCheckout(input.Project, input.CheckoutID)
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
	if !ValidLane(board, lane) {
		return model.Card{}, fault.Invalidf("lane %q is not part of the %s workflow", lane, board.Workflow)
	}
	if strings.TrimSpace(input.Title) == "" {
		return model.Card{}, fault.New(fault.Invalid, "card title is required")
	}
	labelIDs, err := ValidateCardLabels(board, input.LabelIDs)
	if err != nil {
		return model.Card{}, err
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	if _, err := s.ResolveBoard(project.ID, board.ID); err != nil {
		return model.Card{}, err
	}

	if s.cardExists(input.ID) {
		return model.Card{}, fault.Invalidf("card already exists")
	}
	existing, _ := s.ListCards(CardFilter{Board: board.ID, Lane: canonicalLane(board, lane)})
	workspaceMode, err := NormalizeWorkspaceMode(input.WorkspaceMode)
	if err != nil {
		return model.Card{}, err
	}
	if workspaceMode == model.WorkspaceModeProject {
		input.WorkspaceBranch, input.WorkspaceBaseBranch = "", ""
	}
	baseRemote := strings.TrimSpace(input.WorkspaceBaseRemote)
	if baseRemote == "" {
		baseRemote = strings.TrimSpace(board.BaseRemote)
	}
	if baseRemote == "" {
		baseRemote = strings.TrimSpace(project.BaseRemote)
	}
	remotePublishMode, err := normalizeRemotePublishMode(input.RemotePublishMode)
	if err != nil {
		return model.Card{}, err
	}
	if strings.TrimSpace(input.RemotePublishMode) == "" {
		remotePublishMode = board.RemotePublishMode
	}
	checkout, err := s.LocalCheckout(project.ID, input.CheckoutID)
	if err != nil {
		return model.Card{}, err
	}
	now := home.Timestamp()
	item := model.Card{ID: input.ID, OwnerDaemonID: checkout.DaemonID, CheckoutID: checkout.ID, Scope: model.ConversationScopeBoard, ProjectID: project.ID, BoardID: board.ID, Lane: canonicalLane(board, lane), Position: int64(len(existing)+1) * 1024, Title: strings.TrimSpace(input.Title), InitialPrompt: strings.TrimSpace(input.Prompt), Provider: input.Provider, Model: input.Model, Effort: input.Effort, ProviderOptions: home.CloneStringMap(input.ProviderOptions), Runtime: "idle", RuntimeUpdatedAt: now, LastActivityAt: now, PhaseChangedAt: now, CreatedAt: now, UpdatedAt: now, LabelIDs: labelIDs, Origin: input.Origin, WorkspaceMode: workspaceMode, WorkspaceBranch: strings.TrimSpace(input.WorkspaceBranch), WorkspaceBaseBranch: strings.TrimSpace(input.WorkspaceBaseBranch), WorkspaceBaseRemote: baseRemote, RemotePublishMode: remotePublishMode, VaultAccess: input.VaultAccess}
	item.OrderKey, err = s.MoveOrderKey(item, nil)
	if err != nil {
		return model.Card{}, err
	}
	return s.SaveCard(item)
}

func (s *Store) CreateChat(input CreateCardInput) (model.Card, error) {
	if strings.TrimSpace(input.ID) == "" {
		input.ID = home.NewID("c_")
	}
	if !home.ValidFileID(input.ID) {
		return model.Card{}, fault.New(fault.Invalid, "chat ID is invalid")
	}
	project, err := s.ProjectForCheckout(input.Project, input.CheckoutID)
	if err != nil {
		return model.Card{}, err
	}
	title := strings.TrimSpace(input.Title)
	if title == "" {
		return model.Card{}, fault.New(fault.Invalid, "chat title is required")
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	if s.cardExists(input.ID) {
		return model.Card{}, fault.New(fault.Invalid, "chat already exists")
	}
	existing, _ := s.ListCards(CardFilter{Project: project.ID, Scope: model.ConversationScopeChat})
	workspaceMode, err := NormalizeWorkspaceMode(input.WorkspaceMode)
	if err != nil {
		return model.Card{}, err
	}
	if workspaceMode == model.WorkspaceModeProject {
		input.WorkspaceBranch, input.WorkspaceBaseBranch = "", ""
	}
	baseRemote := strings.TrimSpace(input.WorkspaceBaseRemote)
	if baseRemote == "" {
		baseRemote = strings.TrimSpace(project.BaseRemote)
	}
	remotePublishMode, err := normalizeRemotePublishMode(input.RemotePublishMode)
	if err != nil {
		return model.Card{}, err
	}
	checkout, err := s.LocalCheckout(project.ID, input.CheckoutID)
	if err != nil {
		return model.Card{}, err
	}
	now := home.Timestamp()
	item := model.Card{ID: input.ID, OwnerDaemonID: checkout.DaemonID, CheckoutID: checkout.ID, Scope: model.ConversationScopeChat, ProjectID: project.ID, Position: int64(len(existing)+1) * 1024, Title: title, InitialPrompt: strings.TrimSpace(input.Prompt), Provider: input.Provider, Model: input.Model, Effort: input.Effort, ProviderOptions: home.CloneStringMap(input.ProviderOptions), Runtime: "idle", RuntimeUpdatedAt: now, LastActivityAt: now, PhaseChangedAt: now, CreatedAt: now, UpdatedAt: now, WorkspaceMode: workspaceMode, WorkspaceBranch: strings.TrimSpace(input.WorkspaceBranch), WorkspaceBaseBranch: strings.TrimSpace(input.WorkspaceBaseBranch), WorkspaceBaseRemote: baseRemote, RemotePublishMode: remotePublishMode, VaultAccess: input.VaultAccess}
	item.OrderKey, err = s.MoveOrderKey(item, nil)
	if err != nil {
		return model.Card{}, err
	}
	return s.SaveCard(item)
}

func (s *Store) cardExists(id string) bool {
	for _, dir := range []string{s.home.CardDir(), s.home.ArchivedCardDir()} {
		if _, err := os.Stat(filepath.Join(dir, id+".md")); err == nil {
			return true
		}
	}
	return false
}

func (s *Store) ListAllCards(includeArchived bool) ([]model.Card, error) {
	return s.listCardsContext(context.Background(), includeArchived)
}

func (s *Store) listCardsContext(ctx context.Context, includeArchived bool) ([]model.Card, error) {
	paths, err := home.ListMarkdown(s.home.CardDir())
	if err != nil {
		return nil, err
	}
	if includeArchived {
		archived, archivedErr := home.ListMarkdown(s.home.ArchivedCardDir())
		if archivedErr != nil {
			return nil, archivedErr
		}
		paths = append(paths, archived...)
	}
	result := make([]model.Card, 0, len(paths))
	for _, path := range paths {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		item, err := s.readCard(path)
		if errors.Is(err, home.ErrNotFound) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if includeArchived || !item.Archived {
			result = append(result, item)
		}
	}
	_, data, err := s.replica.Snapshot()
	defer data.Close()
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	for _, card := range result {
		seen[card.ID] = true
	}
	for _, id := range replica.EntityIDs(data, "item", "identity") {
		if !seen[id] {
			card, ready, err := SharedCard(data, id, model.Card{})
			if err != nil {
				return nil, err
			}
			if ready && (includeArchived || !card.Archived) {
				result = append(result, card)
			}
		}
	}
	materializeCardPositions(result)
	return result, data.Err()
}

func (s *Store) readCard(path string) (model.Card, error) {
	item, err := s.readLocalCard(path)
	if err != nil {
		return model.Card{}, err
	}
	return s.overlayCard(item)
}

// readLocalCard reads a card file and its owner-only details without the
// shared overlay: placement, title and runtime may lag the peer store.
func (s *Store) readLocalCard(path string) (model.Card, error) {
	var item model.Card
	body, readErr := home.ReadMarkdown(path, &item)
	if readErr != nil {
		return model.Card{}, readErr
	}
	item.InitialPrompt = body
	if item.Scope == "" {
		if item.BoardID == "" {
			item.Scope = model.ConversationScopeChat
		} else {
			item.Scope = model.ConversationScopeBoard
		}
	}
	item.WorkspaceMode, readErr = NormalizeWorkspaceMode(item.WorkspaceMode)
	if readErr != nil {
		return model.Card{}, readErr
	}
	// Owner-only details live in other aggregates (workspace, pull request,
	// transcript), which the composition root connects.
	if summary := s.hooks.WorkspaceSummary; summary != nil {
		if workspace := summary(item.ID); workspace != nil {
			item.Workspace = workspace
		}
	}
	if summary := s.hooks.PullRequestSummary; summary != nil {
		if pullRequest := summary(item.ID); pullRequest != nil {
			item.PullRequest = pullRequest
		}
	}
	if usage := s.hooks.TokenUsage; usage != nil {
		item.TokenUsage = usage(item.ID)
	}
	return item, nil
}

// OwnedCards returns the live cards and chats this machine runs, read from
// their local files without the shared overlay. Owner-only details (prompt,
// workspace, pull request, token usage, agent options) are exact; shared
// fields come from the peer store instead.
func (s *Store) OwnedCards(ctx context.Context) ([]model.Card, error) {
	identity, err := s.replica.PeerIdentity()
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	paths, err := home.ListMarkdown(s.home.CardDir())
	if err != nil {
		return nil, err
	}
	result := make([]model.Card, 0, len(paths))
	for _, path := range paths {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		item, err := s.readLocalCard(path)
		if errors.Is(err, home.ErrNotFound) || errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if item.OwnerDaemonID == identity.DaemonID && !item.Archived {
			result = append(result, item)
		}
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
	items, err := s.ListAllCards(filter.IncludeArchived)
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

func (s *Store) ResolveCard(ref string) (model.Card, error) {
	if home.ValidFileID(ref) {
		for _, dir := range []string{s.home.CardDir(), s.home.ArchivedCardDir()} {
			item, err := s.readCard(filepath.Join(dir, ref+".md"))
			if err == nil {
				return item, nil
			}
			if !errors.Is(err, home.ErrNotFound) {
				return model.Card{}, err
			}
		}
	}
	_, data, err := s.replica.Snapshot()
	defer data.Close()
	if err != nil {
		return model.Card{}, err
	}
	if card, ok, err := SharedCard(data, ref, model.Card{}); err != nil {
		return model.Card{}, err
	} else if ok {
		return card, nil
	}
	return model.Card{}, fmt.Errorf("card %q: %w", ref, home.ErrNotFound)
}

type CardCacheInput struct {
	Title, Provider, Model, Runtime, Summary string
	Effort                                   *string
	ProviderOptions                          map[string]string
	ProviderAccountKey                       *string
}

func (s *Store) UpdateCardCache(ref string, input CardCacheInput) (model.Card, error) {
	write, err := s.home.BeginConditionalWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer write.Finish()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	if err = s.RequireLocalCard(item); err != nil {
		return model.Card{}, err
	}
	title := item.Title
	if input.Title != "" {
		title = input.Title
	}
	provider, modelName, effort, runtime, summary := item.Provider, item.Model, item.Effort, item.Runtime, item.Summary
	providerAccountKey := item.ProviderAccountKey
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
		providerOptions = home.CloneStringMap(input.ProviderOptions)
	}
	if input.ProviderAccountKey != nil {
		providerAccountKey = strings.TrimSpace(*input.ProviderAccountKey)
	}
	if input.Runtime != "" {
		runtime = input.Runtime
	}
	if input.Summary != "" {
		summary = input.Summary
	}
	if title == item.Title && provider == item.Provider && providerAccountKey == item.ProviderAccountKey && modelName == item.Model && effort == item.Effort && stringMapsEqual(providerOptions, item.ProviderOptions) && runtime == item.Runtime && summary == item.Summary {
		return item, nil
	}
	if err := write.Prepare(home.MetadataChange); err != nil {
		return model.Card{}, err
	}
	if item.Title != title {
		item.TitleRevision++
	}
	item.UpdatedAt = home.Timestamp()
	if runtime != item.Runtime {
		item.RuntimeUpdatedAt = item.UpdatedAt
	}
	item.Title = title
	item.Provider, item.ProviderAccountKey, item.Model, item.Effort, item.ProviderOptions, item.Runtime, item.Summary = provider, providerAccountKey, modelName, effort, providerOptions, runtime, summary
	return s.SaveCard(item)
}

func (s *Store) MarkPromptSent(ref string) (model.Card, error) {
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	if err = s.RequireLocalCard(item); err != nil {
		return model.Card{}, err
	}
	if item.InitialPromptSentAt == "" {
		item.InitialPromptSentAt = home.Timestamp()
	}
	if item.Scope == model.ConversationScopeBoard && item.Lane != model.LaneRunning {
		item.Lane = model.LaneRunning
		item.OrderKey, err = s.MoveOrderKey(item, nil)
		if err != nil {
			return model.Card{}, err
		}
	}
	item.Runtime, item.PhaseChangedAt, item.UpdatedAt = "starting", home.Timestamp(), home.Timestamp()
	item.RuntimeUpdatedAt = item.UpdatedAt
	return s.SaveCard(item)
}

func (s *Store) RenameCard(ref, title string) (model.Card, error) {
	if strings.TrimSpace(title) == "" {
		return model.Card{}, fault.New(fault.Invalid, "title is required")
	}
	release, err := s.home.BeginWrite()
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
	item.Title, item.UpdatedAt = strings.TrimSpace(title), home.Timestamp()
	item.TitleRevision++
	return s.SaveCard(item)
}

type DraftAgentSettings struct {
	Provider, Model, Effort string
	ProviderOptions         map[string]string
}

func (s *Store) UpdateCard(ref, title, initialPrompt string, settings ...DraftAgentSettings) (model.Card, error) {
	title, initialPrompt = strings.TrimSpace(title), strings.TrimSpace(initialPrompt)
	if title == "" {
		return model.Card{}, fault.New(fault.Invalid, "title is required")
	}
	if initialPrompt == "" {
		return model.Card{}, fault.New(fault.Invalid, "agent task is required")
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	if err = s.RequireLocalCard(item); err != nil {
		return model.Card{}, err
	}
	if initialPrompt != item.InitialPrompt && item.InitialPromptSentAt != "" {
		return model.Card{}, fault.New(fault.Invalid, "agent task can only be edited before it is sent")
	}
	if item.MergePending {
		return model.Card{}, fault.New(fault.Invalid, "card merge is pending")
	}
	if len(settings) > 0 {
		active, leaseErr := s.leases.CardActive(item.ID)
		if leaseErr != nil {
			return model.Card{}, leaseErr
		}
		if item.InitialPromptSentAt != "" || active {
			return model.Card{}, fault.New(fault.Invalid, "agent settings can only be edited before the initial task is sent")
		}
		config := settings[0]
		item.Provider, item.Model, item.Effort, item.ProviderOptions = config.Provider, config.Model, config.Effort, config.ProviderOptions
	}
	if len(settings) == 0 && title == item.Title && initialPrompt == item.InitialPrompt {
		return item, nil
	}
	if item.LastActivityAt == "" {
		item.LastActivityAt = item.UpdatedAt
	}
	item.Title, item.InitialPrompt, item.UpdatedAt = title, initialPrompt, home.Timestamp()
	item.TitleRevision++
	return s.SaveCard(item)
}

func (s *Store) PinChat(ref string, pinned bool) (model.Card, error) {
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	if item.Scope != model.ConversationScopeChat {
		return model.Card{}, fault.New(fault.Invalid, "only standalone chats can be pinned")
	}
	if item.LastActivityAt == "" {
		item.LastActivityAt = item.UpdatedAt
	}
	item.Pinned, item.UpdatedAt = pinned, home.Timestamp()
	return s.SaveCard(item)
}

func (s *Store) UpdateCardWorkspaceSelection(ref, mode, branch, baseBranch, baseRemote, remotePublishMode string, allowStarted bool) (model.Card, error) {
	mode, err := NormalizeWorkspaceMode(mode)
	if err != nil {
		return model.Card{}, err
	}
	remotePublishMode, err = normalizeRemotePublishMode(remotePublishMode)
	if err != nil {
		return model.Card{}, err
	}
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	if err = s.RequireLocalCard(item); err != nil {
		return model.Card{}, err
	}
	if !allowStarted && item.InitialPromptSentAt != "" {
		return model.Card{}, fault.New(fault.Invalid, "workspace mode is locked after the first agent turn")
	}
	item.WorkspaceMode = mode
	if mode == model.WorkspaceModeWorktree {
		item.WorkspaceBranch = strings.TrimSpace(branch)
		item.WorkspaceBaseBranch = strings.TrimSpace(baseBranch)
	} else {
		item.WorkspaceBranch, item.WorkspaceBaseBranch = "", ""
	}
	item.WorkspaceBaseRemote = strings.TrimSpace(baseRemote)
	item.RemotePublishMode = remotePublishMode
	item.UpdatedAt = home.Timestamp()
	return s.SaveCard(item)
}

func (s *Store) ArchiveCard(ref string, archived bool) (model.Card, error) {
	release, err := s.home.BeginWrite()
	if err != nil {
		return model.Card{}, err
	}
	defer release()
	item, err := s.ResolveCard(ref)
	if err != nil {
		return model.Card{}, err
	}
	if archived {
		activeLeases, leaseErr := s.leases.Active()
		if leaseErr != nil {
			return model.Card{}, leaseErr
		}
		for _, lease := range activeLeases {
			if lease.CardID == item.ID {
				return model.Card{}, leases.ErrCardActive
			}
		}
	}
	item.Archived = archived
	item.DoneArchiveExempt = !archived && item.Scope == model.ConversationScopeBoard && item.Lane == model.LaneDone
	item.UpdatedAt = home.Timestamp()
	return s.SaveCard(item)
}

func (s *Store) ArchiveDoneCards(now time.Time) ([]model.Card, error) {
	possible, err := s.doneCardsPossiblyDueForArchive(now)
	if err != nil || len(possible) == 0 {
		return possible, err
	}
	release, err := s.home.BeginWriteLock()
	if err != nil {
		return nil, err
	}
	defer release()
	due, err := s.doneCardsDueForArchive(now)
	if err != nil || len(due) == 0 {
		return due, err
	}
	pending, err := s.home.PrepareMutation(home.MetadataChange)
	if err != nil {
		return nil, err
	}
	// Readers learn about the sweep like any other write.
	defer func() {
		_ = s.home.CommitMutation(pending)
		s.home.NotifyChanges()
	}()
	archived := make([]model.Card, 0, len(due))
	archivedAt := now.UTC().Format(time.RFC3339Nano)
	for _, card := range due {
		card.Archived, card.UpdatedAt = true, archivedAt
		if err := s.WriteCard(card); err != nil {
			return archived, err
		}
		archived = append(archived, card)
	}
	return archived, nil
}

func (s *Store) doneCardsPossiblyDueForArchive(now time.Time) ([]model.Card, error) {
	return s.doneCardsEligibleForArchive(now, nil)
}

func (s *Store) doneCardsDueForArchive(now time.Time) ([]model.Card, error) {
	activeLeases, err := s.leases.Active()
	if err != nil {
		return nil, err
	}
	activeCards := make(map[string]bool, len(activeLeases))
	for _, lease := range activeLeases {
		activeCards[lease.CardID] = true
	}
	return s.doneCardsEligibleForArchive(now, activeCards)
}

func (s *Store) doneCardsEligibleForArchive(now time.Time, activeCards map[string]bool) ([]model.Card, error) {
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
	cards, err := s.ListAllCards(false)
	if err != nil {
		return nil, err
	}
	due := make([]model.Card, 0)
	for _, card := range cards {
		if s.RequireLocalCard(card) != nil {
			continue
		}
		delay, enabled := delays[card.BoardID]
		if !enabled || card.Scope != model.ConversationScopeBoard || card.Lane != model.LaneDone || card.Archived || card.DoneArchiveExempt || activeCards[card.ID] || model.RuntimeHoldsTurn(card.Runtime) {
			continue
		}
		phaseChangedAt, parseErr := time.Parse(time.RFC3339Nano, card.PhaseChangedAt)
		if parseErr != nil {
			phaseChangedAt, parseErr = time.Parse(time.RFC3339Nano, card.UpdatedAt)
		}
		if parseErr != nil || now.Before(phaseChangedAt.Add(delay)) {
			continue
		}
		due = append(due, card)
	}
	return due, nil
}

func (s *Store) CardDetail(ref string) (model.CardDetail, error) {
	owner, err := s.ResolveCard(ref)
	if err != nil {
		return model.CardDetail{}, err
	}
	if err = s.RequireLocalCard(owner); err != nil {
		return model.CardDetail{}, err
	}

	card, err := s.ResolveCard(ref)
	if err != nil {
		return model.CardDetail{}, err
	}
	project, err := s.ProjectForCheckout(card.ProjectID, card.CheckoutID)
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
	return model.CardDetail{Card: card, Project: project, Board: board}, nil
}

func containsFold(value, query string) bool {
	return strings.Contains(strings.ToLower(value), strings.ToLower(query))
}
