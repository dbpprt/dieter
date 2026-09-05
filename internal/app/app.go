package app

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dbpprt/dieter/internal/attachments"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/workspace"
)

type Service struct {
	Store      *store.Store
	Runner     harness.Runner
	Workspaces *workspace.Manager

	mu               sync.Mutex
	active           map[string]*activeTurn
	shuttingDown     bool
	minimumFreeBytes uint64
	diskAvailable    func(string) (uint64, error)
}

type activeTurn struct {
	cancel         context.CancelFunc
	cardID         string
	turnID         string
	lease          store.RuntimeLease
	done           chan struct{}
	suspend        bool
	startedAt      time.Time
	lastProgress   time.Time
	workerObserved bool
	recoveryErr    error
	finishing      bool
}

type TurnUpdate struct {
	Chunk json.RawMessage
	Done  bool
	Err   error
}

func New(data *store.Store, runner harness.Runner) *Service {
	if runner == nil {
		runner = harness.NewSubprocessRunner(data.Root)
	}
	minimumFreeBytes := uint64(2 << 30)
	if raw := strings.TrimSpace(os.Getenv("DIETER_MIN_FREE_BYTES")); raw != "" {
		if configured, err := strconv.ParseUint(raw, 10, 64); err == nil {
			minimumFreeBytes = configured
		}
	}
	return &Service{
		Store: data, Runner: runner, Workspaces: workspace.New(data, nil), active: map[string]*activeTurn{},
		minimumFreeBytes: minimumFreeBytes, diskAvailable: availableDiskBytes,
	}
}

var ErrInsufficientStorage = errors.New("insufficient free disk space to start an agent turn")

const (
	workerStartupTimeout   = 5 * time.Minute
	workerHeartbeatTimeout = 30 * time.Second
)

func (s *Service) ensureStartStorage(paths ...string) error {
	if s.minimumFreeBytes == 0 || s.diskAvailable == nil {
		return nil
	}
	checked := map[string]bool{}
	for _, path := range paths {
		path = filepath.Clean(path)
		if path == "." || checked[path] {
			continue
		}
		checked[path] = true
		available, err := s.diskAvailable(path)
		if err != nil {
			return fmt.Errorf("check free disk space for %s: %w", path, err)
		}
		if available < s.minimumFreeBytes {
			return fmt.Errorf("%w: %s has %d MiB available; %d MiB required", ErrInsufficientStorage, path, available>>20, s.minimumFreeBytes>>20)
		}
	}
	return nil
}

// ReconcileOrphanedTurns resumes turns that were cleanly suspended by a
// previous Dieter process. A turn without a provider continuation is closed as
// interrupted; its prompt is never replayed because that could duplicate file
// edits or external side effects.
func (s *Service) ReconcileOrphanedTurns() ([]string, error) {
	cards, err := s.Store.OrphanedTurnCards()
	if err != nil {
		return nil, err
	}
	recovered := make([]string, 0, len(cards))
	var recoveryErrors []error
	for _, card := range cards {
		s.mu.Lock()
		ownedHere := s.active[card.ID] != nil
		s.mu.Unlock()
		if ownedHere {
			continue
		}
		if resumeErr := s.resumeOrphanedTurn(card.ID); resumeErr == nil {
			recovered = append(recovered, card.ID)
			continue
		} else if !errors.Is(resumeErr, errNoTurnContinuation) {
			recoveryErrors = append(recoveryErrors, fmt.Errorf("resume orphaned turn %s: %w", card.ID, resumeErr))
		}
		if canceller, ok := s.Runner.(harness.Canceller); ok {
			cancelErr := canceller.Cancel(card.ID, filepath.Join(s.Store.RuntimeDir(), "sessions", card.ProjectID))
			if cancelErr != nil && !errors.Is(cancelErr, os.ErrProcessDone) && !errors.Is(cancelErr, harness.ErrNoActiveTurn) {
				recoveryErrors = append(recoveryErrors, fmt.Errorf("stop orphaned turn %s: %w", card.ID, cancelErr))
			}
		}
		interrupted, interruptErr := s.Store.InterruptConversation(card.ID)
		if interruptErr != nil {
			recoveryErrors = append(recoveryErrors, fmt.Errorf("reconcile orphaned turn %s: %w", card.ID, interruptErr))
			continue
		}
		if interrupted {
			recovered = append(recovered, card.ID)
			s.startNextQueued(card.ID)
		}
	}
	return recovered, errors.Join(recoveryErrors...)
}

var errNoTurnContinuation = errors.New("conversation has no suspended turn continuation")

func hasTurnContinuation(state json.RawMessage) bool {
	var envelope struct {
		ContinueFrom json.RawMessage `json:"continueFrom"`
	}
	return json.Unmarshal(state, &envelope) == nil && len(envelope.ContinueFrom) > 0 && string(envelope.ContinueFrom) != "null"
}

func (s *Service) resumeOrphanedTurn(ref string) error {
	detail, err := s.Store.CardDetail(ref)
	if err != nil {
		return err
	}
	if err := s.ensureStartStorage(s.Store.Root, detail.Project.Path); err != nil {
		return err
	}
	conversation, err := s.Store.Conversation(detail.Card.ID)
	if err != nil {
		return err
	}
	if !hasTurnContinuation(conversation.Session) {
		return errNoTurnContinuation
	}
	adapter, configuredModel, err := resolvePersistedSelection(detail.Card.Provider, detail.Card.Model, os.Getenv("DIETER_ENABLE_MOCK_HARNESS") == "1")
	if err != nil {
		return err
	}
	// Provider discovery may not have run yet in a freshly restarted Dieter
	// process. The locked model and effort were validated when the conversation
	// was created, so recovery must trust those persisted values rather than
	// rejecting a live continuation against the smaller release fallback list.
	effort := detail.Card.Effort
	providerOptions, err := harness.ResolveOptions(adapter, detail.Card.ProviderOptions)
	if err != nil {
		return err
	}
	resolution := dieterprompt.Resolution{}
	lease, err := s.Store.AcquireRuntimeLeaseFor(detail.Project.ID, detail.Board.ID, detail.Card.ID, adapter.ID)
	if err != nil {
		return err
	}
	turnID, responseMessageID := newRuntimeID("turn_"), newRuntimeID("msg_")
	if conversation.ActiveTurn != nil {
		if conversation.ActiveTurn.ID != "" {
			turnID = conversation.ActiveTurn.ID
		}
		if conversation.ActiveTurn.ResponseMessageID != "" {
			responseMessageID = conversation.ActiveTurn.ResponseMessageID
		}
	} else if len(conversation.Messages) > 0 {
		last := conversation.Messages[len(conversation.Messages)-1]
		if last.Role == "assistant" && last.ID != "" {
			responseMessageID = last.ID
		}
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	s.mu.Lock()
	if s.shuttingDown {
		s.mu.Unlock()
		cancel()
		_ = s.Store.ReleaseRuntimeLease(lease)
		return errors.New("Dieter is shutting down")
	}
	if active := s.active[detail.Card.ID]; active != nil {
		s.mu.Unlock()
		cancel()
		_ = s.Store.ReleaseRuntimeLease(lease)
		return store.ErrCardActive
	}
	now := time.Now()
	s.active[detail.Card.ID] = &activeTurn{cancel: cancel, cardID: detail.Card.ID, turnID: turnID, lease: lease, done: done, startedAt: now, lastProgress: now}
	s.mu.Unlock()
	updates := make(chan TurnUpdate, 1024)
	workspaceValue, err := s.Workspaces.Ensure(context.Background(), detail.Card.ID)
	if err != nil {
		cancel()
		_ = s.Store.ReleaseRuntimeLease(lease)
		s.clearActive(detail.Card.ID, turnID)
		close(done)
		return err
	}
	if conversation.ActiveTurn != nil && conversation.ActiveTurn.Instructions != "" {
		resolution.Instructions = conversation.ActiveTurn.Instructions
		resolution.Source = conversation.ActiveTurn.InstructionSource
		resolution.Instructions = dieterprompt.BindWorkspace(resolution.Instructions, detail.Project.Path, workspaceValue)
	} else {
		resolution, err = s.resolveInstructions(detail, workspaceValue)
		if err != nil {
			cancel()
			_ = s.Store.ReleaseRuntimeLease(lease)
			s.clearActive(detail.Card.ID, turnID)
			close(done)
			return err
		}
	}
	request := harness.Request{
		Harness: adapter.ID, Adapter: adapter.Runtime, Model: configuredModel.RuntimeID(), ConfiguredModel: configuredModel.ID,
		ContextWindow: configuredModel.ContextWindow, Effort: effort, Options: providerOptions, ResponseMessageID: responseMessageID,
		Instructions: resolution.Instructions, SessionID: detail.Card.ID, Session: conversation.Session,
		ProjectPath: workspaceValue.Path, RuntimeRoot: filepath.Join(s.Store.RuntimeDir(), "sessions", detail.Project.ID), Continue: true,
	}
	go s.runTurn(ctx, detail, turnID, request, updates, done)
	go drainTurnUpdates(updates)
	return nil
}

func resolvePersistedSelection(providerID, modelID string, includeMock bool) (harness.Adapter, harness.Model, error) {
	adapter, ok := harness.ResolveAdapter(strings.TrimSpace(providerID), includeMock)
	if !ok {
		return harness.Adapter{}, harness.Model{}, fmt.Errorf("unsupported harness %q", providerID)
	}
	modelID = strings.TrimSpace(modelID)
	if modelID == "" {
		modelID = adapter.DefaultModel
	}
	for _, configuredModel := range adapter.Models {
		if configuredModel.ID == modelID {
			return adapter, configuredModel, nil
		}
	}
	if modelID == "" {
		return adapter, harness.Model{}, nil
	}
	return adapter, harness.Model{ID: modelID, Name: modelID}, nil
}

// SuspendActiveTurns freezes every in-flight provider turn at a resumable SDK
// boundary. It is used only during graceful process shutdown; normal user
// cancellation remains an interruption.
func (s *Service) SuspendActiveTurns(ctx context.Context) error {
	s.mu.Lock()
	s.shuttingDown = true
	turns := make([]*activeTurn, 0, len(s.active))
	for _, turn := range s.active {
		turn.suspend = true
		turns = append(turns, turn)
	}
	s.mu.Unlock()
	type suspendResult struct {
		turn *activeTurn
		err  error
	}
	results := make(chan suspendResult, len(turns))
	for _, turn := range turns {
		go func(turn *activeTurn) {
			if suspender, ok := s.Runner.(harness.Suspender); ok {
				detail, detailErr := s.Store.CardDetail(turn.cardID)
				if detailErr == nil {
					detailErr = suspender.Suspend(turn.cardID, filepath.Join(s.Store.RuntimeDir(), "sessions", detail.Project.ID))
				}
				if detailErr == nil {
					results <- suspendResult{turn: turn}
					return
				}
				turn.cancel()
				results <- suspendResult{turn: turn, err: detailErr}
				return
			}
			turn.cancel()
			results <- suspendResult{turn: turn}
		}(turn)
	}
	var suspensionErrors []error
	for range turns {
		var result suspendResult
		select {
		case result = <-results:
			if result.err != nil {
				suspensionErrors = append(suspensionErrors, fmt.Errorf("signal suspend %s: %w", result.turn.cardID, result.err))
			}
		case <-ctx.Done():
			return errors.Join(append(suspensionErrors, ctx.Err())...)
		}
		select {
		case <-result.turn.done:
			conversation, err := s.Store.Conversation(result.turn.cardID)
			if err != nil {
				suspensionErrors = append(suspensionErrors, err)
			} else if !hasTurnContinuation(conversation.Session) {
				suspensionErrors = append(suspensionErrors, fmt.Errorf("suspend %s: %w", result.turn.cardID, errNoTurnContinuation))
			}
		case <-ctx.Done():
			return errors.Join(append(suspensionErrors, ctx.Err())...)
		}
	}
	return errors.Join(suspensionErrors...)
}

type ProjectInput struct {
	Path, Name, Summary, Prompt, BaseRemote, BaseBranch string
	ValidationCommands                                  []model.ValidationCommand
	Create                                              bool
}

func (s *Service) RegisterProject(ctx context.Context, input ProjectInput) (model.Project, error) {
	path := strings.TrimSpace(input.Path)
	if path == "" {
		return model.Project{}, errors.New("project path is required")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return model.Project{}, err
	}
	if input.Create {
		if err := os.MkdirAll(abs, 0o755); err != nil {
			return model.Project{}, err
		}
		if _, err := os.Stat(filepath.Join(abs, ".git")); errors.Is(err, os.ErrNotExist) {
			command := exec.CommandContext(ctx, "git", "init", abs)
			if output, initErr := command.CombinedOutput(); initErr != nil {
				return model.Project{}, fmt.Errorf("initialize Git project: %s: %w", strings.TrimSpace(string(output)), initErr)
			}
		}
	}
	if _, err := os.Stat(filepath.Join(abs, ".git")); err != nil {
		return model.Project{}, errors.New("project path must be an existing Git working tree")
	}
	return s.Store.CreateProject(store.CreateProjectInput{
		Name: input.Name, Path: abs, Summary: input.Summary, Prompt: input.Prompt,
		BaseRemote: input.BaseRemote, BaseBranch: input.BaseBranch, ValidationCommands: input.ValidationCommands,
	})
}

type CardInput struct {
	Project, Board, Lane, Title, Prompt, Provider, Model, Effort string
	WorkspaceMode, WorkspaceBranch, WorkspaceBaseBranch          string
	LabelIDs                                                     []string
	ProviderOptions                                              map[string]string
	DeferStart                                                   bool
	ID                                                           string
	Origin                                                       *model.CardOrigin
	Attachments                                                  []model.UIMessagePart
}

func (s *Service) CreateCard(ctx context.Context, input CardInput) (model.Card, error) {
	return s.createConversation(ctx, input, model.ConversationScopeBoard)
}

func (s *Service) CreateChat(ctx context.Context, input CardInput) (model.Card, error) {
	return s.createConversation(ctx, input, model.ConversationScopeChat)
}

// ForkChat creates an independent standalone chat from a stable transcript
// boundary. Provider lifecycle state and workspace state are intentionally not
// shared with the source conversation.
func (s *Service) ForkChat(sourceRef, messageID, title string) (model.Card, error) {
	return s.Store.ForkChat(sourceRef, messageID, title)
}

func (s *Service) createConversation(ctx context.Context, input CardInput, scope string) (model.Card, error) {
	project, err := s.Store.ResolveProject(input.Project)
	if err != nil {
		return model.Card{}, err
	}
	input.Title = strings.TrimSpace(input.Title)
	input.Prompt = strings.TrimSpace(input.Prompt)
	if input.Prompt == "" {
		input.Prompt = input.Title
	}
	provider := strings.TrimSpace(input.Provider)
	if provider == "" {
		provider = "codex"
	}
	adapter, configuredModel, err := harness.ResolveSelection(provider, input.Model, os.Getenv("DIETER_ENABLE_MOCK_HARNESS") == "1")
	if err != nil {
		return model.Card{}, err
	}
	provider, input.Model = adapter.ID, configuredModel.ID
	input.Effort, err = harness.ResolveEffort(adapter, configuredModel, input.Effort)
	if err != nil {
		return model.Card{}, err
	}
	input.ProviderOptions, err = harness.ResolveOptions(adapter, input.ProviderOptions)
	if err != nil {
		return model.Card{}, err
	}
	if len(input.Attachments) > 0 {
		input.Attachments, err = normalizeAttachmentParts(input.Attachments)
		if err != nil {
			return model.Card{}, err
		}
	}
	createInput := store.CreateCardInput{Project: project.ID, Board: input.Board, ID: input.ID, Lane: input.Lane, Title: input.Title, Prompt: input.Prompt, Provider: provider, Model: input.Model, Effort: input.Effort, ProviderOptions: input.ProviderOptions, LabelIDs: input.LabelIDs, Origin: input.Origin, WorkspaceMode: input.WorkspaceMode, WorkspaceBranch: input.WorkspaceBranch, WorkspaceBaseBranch: input.WorkspaceBaseBranch}
	var card model.Card
	if scope == model.ConversationScopeChat {
		card, err = s.Store.CreateChat(createInput)
	} else {
		card, err = s.Store.CreateCard(createInput)
	}
	if err != nil {
		return model.Card{}, err
	}
	if len(input.Attachments) > 0 {
		if _, err = s.Store.SetConversationDraftAttachments(card.ID, input.Attachments); err != nil {
			return card, err
		}
	}
	shouldStart := scope == model.ConversationScopeChat || strings.EqualFold(input.Lane, model.LaneRunning)
	if shouldStart && !input.DeferStart {
		parts := initialMessageParts(input.Prompt, input.Attachments)
		updates, startErr := s.StartCardWithMessageParts(card.ID, parts, provider, input.Model, input.Effort, input.ProviderOptions, "")
		if startErr != nil {
			if scope == model.ConversationScopeBoard {
				_, _ = s.Store.MoveCard(card.ID, model.LaneTodo, nil)
			}
			return card, startErr
		}
		go drainTurnUpdates(updates)
	}
	return s.Store.ResolveCard(card.ID)
}

func (s *Service) resolveInstructions(detail model.CardDetail, workspaceValue model.Workspace) (dieterprompt.Resolution, error) {
	settings, err := s.Store.Settings()
	if err != nil {
		return dieterprompt.Resolution{}, err
	}
	return dieterprompt.ResolveForWorkspace(settings, detail, detail.Card.LabelIDs, workspaceValue)
}

func (s *Service) StartCard(ref, content, provider, modelName, effort string) (<-chan TurnUpdate, error) {
	return s.startCard(ref, content, nil, provider, modelName, effort, nil, "", "")
}

func (s *Service) StartCardWithMessageID(ref, content, provider, modelName, effort, messageID string) (<-chan TurnUpdate, error) {
	return s.startCard(ref, content, nil, provider, modelName, effort, nil, "", messageID)
}

func (s *Service) StartCardWithMessageParts(ref string, parts []model.UIMessagePart, provider, modelName, effort string, providerOptions map[string]string, messageID string) (<-chan TurnUpdate, error) {
	return s.startCard(ref, messagePartsText(parts), parts, provider, modelName, effort, providerOptions, "", messageID)
}

func (s *Service) startCard(ref, content string, parts []model.UIMessagePart, provider, modelName, effort string, requestedOptions map[string]string, queueID, messageID string) (<-chan TurnUpdate, error) {
	detail, err := s.Store.CardDetail(ref)
	if err != nil {
		return nil, err
	}
	first := detail.Card.InitialPromptSentAt == ""
	if first {
		conversation, conversationErr := s.Store.Conversation(detail.Card.ID)
		if conversationErr != nil {
			return nil, conversationErr
		}
		if strings.TrimSpace(content) == "" && messagePartsText(parts) == "" {
			content = detail.Card.InitialPrompt
		}
		parts = mergeInitialMessageParts(content, parts, conversation.DraftAttachments)
	}
	if len(parts) > 0 {
		parts, err = attachments.NormalizeMessageParts(parts)
		if err != nil {
			return nil, err
		}
	}
	content = strings.TrimSpace(content)
	if text := messagePartsText(parts); text != "" {
		content = text
	}
	if content == "" && !messagePartsHaveFiles(parts) {
		return nil, errors.New("message is required")
	}
	if len(parts) == 0 {
		parts = []model.UIMessagePart{{Type: "text", Text: content}}
	}
	requestedProvider, requestedModel, requestedEffort := strings.TrimSpace(provider), strings.TrimSpace(modelName), strings.TrimSpace(effort)
	explicitDefaultEffort := requestedEffort == "default"
	if !first {
		if requestedProvider != "" && requestedProvider != detail.Card.Provider {
			return nil, fmt.Errorf("conversation harness is locked to %q", detail.Card.Provider)
		}
		if requestedModel != "" && requestedModel != detail.Card.Model {
			return nil, fmt.Errorf("conversation model is locked to %q", detail.Card.Model)
		}
		comparisonEffort := requestedEffort
		if explicitDefaultEffort {
			comparisonEffort = ""
		}
		if (requestedEffort != "" || explicitDefaultEffort) && comparisonEffort != detail.Card.Effort {
			locked := detail.Card.Effort
			if locked == "" {
				locked = "default"
			}
			return nil, fmt.Errorf("conversation effort is locked to %q", locked)
		}
		provider, modelName, effort = detail.Card.Provider, detail.Card.Model, detail.Card.Effort
	}
	if provider == "" {
		provider = detail.Card.Provider
	}
	if provider == "" {
		provider = "codex"
	}
	if modelName == "" {
		modelName = detail.Card.Model
	}
	if effort == "" && !explicitDefaultEffort {
		effort = detail.Card.Effort
	}
	adapter, configuredModel, err := harness.ResolveSelection(provider, modelName, os.Getenv("DIETER_ENABLE_MOCK_HARNESS") == "1")
	if err != nil {
		return nil, err
	}
	provider, modelName = adapter.ID, configuredModel.ID
	effort, err = harness.ResolveEffort(adapter, configuredModel, effort)
	if err != nil {
		return nil, err
	}
	if requestedOptions == nil {
		requestedOptions = detail.Card.ProviderOptions
	}
	providerOptions, err := harness.ResolveOptions(adapter, requestedOptions)
	if err != nil {
		return nil, err
	}
	if !first && requestedOptions != nil {
		lockedOptions, resolveErr := harness.ResolveOptions(adapter, detail.Card.ProviderOptions)
		if resolveErr != nil {
			return nil, resolveErr
		}
		if !providerOptionsEqual(providerOptions, lockedOptions) {
			return nil, errors.New("conversation provider options are locked")
		}
	}
	if err := s.ensureStartStorage(s.Store.Root, detail.Project.Path); err != nil {
		return nil, err
	}
	s.mu.Lock()
	if s.shuttingDown {
		s.mu.Unlock()
		return nil, errors.New("Dieter is shutting down")
	}
	if active := s.active[detail.Card.ID]; active != nil {
		s.mu.Unlock()
		return nil, store.ErrCardActive
	}
	s.mu.Unlock()
	lease, err := s.Store.AcquireRuntimeLeaseFor(detail.Project.ID, detail.Board.ID, detail.Card.ID, provider)
	if err != nil {
		return nil, err
	}
	turnID, responseMessageID := newRuntimeID("turn_"), newRuntimeID("msg_")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	s.mu.Lock()
	now := time.Now()
	s.active[detail.Card.ID] = &activeTurn{cancel: cancel, cardID: detail.Card.ID, turnID: turnID, lease: lease, done: done, startedAt: now, lastProgress: now}
	s.mu.Unlock()
	workspaceValue, err := s.Workspaces.Ensure(context.Background(), detail.Card.ID)
	if err != nil {
		cancel()
		_ = s.Store.ReleaseRuntimeLease(lease)
		s.clearActive(detail.Card.ID, turnID)
		close(done)
		return nil, err
	}
	resolution, err := s.resolveInstructions(detail, workspaceValue)
	if err != nil {
		cancel()
		_ = s.Store.ReleaseRuntimeLease(lease)
		s.clearActive(detail.Card.ID, turnID)
		close(done)
		return nil, err
	}

	if strings.TrimSpace(messageID) == "" {
		messageID = newRuntimeID("msg_")
	}
	var startErr error
	if queueID == "" {
		_, startErr = s.Store.StartConversationTurnParts(detail.Card.ID, turnID, messageID, parts)
	} else {
		_, startErr = s.Store.StartQueuedConversationTurnParts(detail.Card.ID, turnID, messageID, queueID, parts)
	}
	if startErr != nil {
		cancel()
		_ = s.Store.ReleaseRuntimeLease(lease)
		s.clearActive(detail.Card.ID, turnID)
		close(done)
		return nil, startErr
	}
	labelIDs := make([]string, 0, len(resolution.AppliedLabels))
	for _, label := range resolution.AppliedLabels {
		labelIDs = append(labelIDs, label.ID)
	}
	if _, startErr = s.Store.SetConversationActiveTurn(detail.Card.ID, model.ConversationTurn{ID: turnID, UserMessageID: messageID, ResponseMessageID: responseMessageID, Instructions: resolution.Instructions, InstructionSource: resolution.Source, InstructionLabels: labelIDs}); startErr != nil {
		cancel()
		_ = s.Store.ReleaseRuntimeLease(lease)
		s.clearActive(detail.Card.ID, turnID)
		close(done)
		return nil, startErr
	}
	if first {
		_, err = s.Store.UpdateCardCache(detail.Card.ID, store.CardCacheInput{Provider: provider, Model: modelName, Effort: &effort, ProviderOptions: providerOptions})
		if err == nil {
			_, err = s.Store.MarkPromptSent(detail.Card.ID)
		}
	} else {
		_, err = s.Store.UpdateCardCache(detail.Card.ID, store.CardCacheInput{Provider: provider, Model: modelName, Effort: &effort, Runtime: "running"})
		if err == nil && detail.Card.Scope == model.ConversationScopeBoard && detail.Card.Lane != model.LaneRunning {
			_, err = s.Store.MoveCard(detail.Card.ID, model.LaneRunning, nil)
		}
	}
	if err != nil {
		cancel()
		_ = s.Store.ReleaseRuntimeLease(lease)
		s.clearActive(detail.Card.ID, turnID)
		close(done)
		return nil, err
	}

	conversation, _ := s.Store.Conversation(detail.Card.ID)
	updates := make(chan TurnUpdate, 1024)
	harnessPrompt := content
	if len(conversation.ForkSeed) > 0 && len(conversation.Session) == 0 {
		harnessPrompt = forkedConversationPrompt(conversation.ForkSeed, content)
	}
	request := harness.Request{
		Harness: provider, Adapter: adapter.Runtime, Model: configuredModel.RuntimeID(), ConfiguredModel: modelName, ContextWindow: configuredModel.ContextWindow, Effort: effort, Options: providerOptions, Prompt: content, ResponseMessageID: responseMessageID,
		Attachments:  messagePartsAttachments(parts),
		Instructions: resolution.Instructions, SessionID: detail.Card.ID, Session: conversation.Session,
		ProjectPath: workspaceValue.Path,
		RuntimeRoot: filepath.Join(s.Store.RuntimeDir(), "sessions", detail.Project.ID),
	}
	request.Prompt = harnessPrompt
	go s.runTurn(ctx, detail, turnID, request, updates, done)
	return updates, nil
}

func forkedConversationPrompt(messages []model.UIMessage, prompt string) string {
	var transcript strings.Builder
	for _, message := range messages {
		role := strings.ToUpper(strings.TrimSpace(message.Role))
		if role != "USER" && role != "ASSISTANT" {
			continue
		}
		var text strings.Builder
		for _, part := range message.Parts {
			if part.Type == "text" && strings.TrimSpace(part.Text) != "" {
				if text.Len() > 0 {
					text.WriteString("\n")
				}
				text.WriteString(strings.TrimSpace(part.Text))
			}
		}
		if text.Len() > 0 {
			fmt.Fprintf(&transcript, "%s:\n%s\n\n", role, text.String())
		}
	}
	return "This is a fork of an earlier Dieter chat. Treat the transcript below as prior conversation context. Do not repeat or summarize it unless the user asks. Continue independently from it.\n\n<forked_transcript>\n" + transcript.String() + "</forked_transcript>\n\nUSER:\n" + strings.TrimSpace(prompt)
}

func messagePartsText(parts []model.UIMessagePart) string {
	var text strings.Builder
	for _, part := range parts {
		if part.Type == "text" {
			text.WriteString(part.Text)
		}
	}
	return strings.TrimSpace(text.String())
}

func messagePartsHaveFiles(parts []model.UIMessagePart) bool {
	for _, part := range parts {
		if part.Type == "file" && part.URL != "" {
			return true
		}
	}
	return false
}

func providerOptionsEqual(left, right map[string]string) bool {
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

func messagePartsAttachments(parts []model.UIMessagePart) []harness.Attachment {
	attachments := make([]harness.Attachment, 0, len(parts))
	for _, part := range parts {
		if part.Type == "file" {
			attachments = append(attachments, harness.Attachment{MediaType: part.MediaType, Filename: part.Filename, URL: part.URL})
		}
	}
	return attachments
}

func normalizeAttachmentParts(parts []model.UIMessagePart) ([]model.UIMessagePart, error) {
	normalized, err := attachments.NormalizeMessageParts(parts)
	if err != nil {
		return nil, err
	}
	for _, part := range normalized {
		if part.Type != "file" {
			return nil, errors.New("card attachments must be images or files")
		}
	}
	return normalized, nil
}

func initialMessageParts(prompt string, attachmentParts []model.UIMessagePart) []model.UIMessagePart {
	parts := make([]model.UIMessagePart, 0, len(attachmentParts)+1)
	if prompt = strings.TrimSpace(prompt); prompt != "" {
		parts = append(parts, model.UIMessagePart{Type: "text", Text: prompt})
	}
	return append(parts, attachmentParts...)
}

func mergeInitialMessageParts(content string, explicit, draft []model.UIMessagePart) []model.UIMessagePart {
	parts := append([]model.UIMessagePart(nil), explicit...)
	if len(parts) == 0 {
		parts = initialMessageParts(content, nil)
	}
	for _, candidate := range draft {
		duplicate := false
		for _, existing := range parts {
			if existing.Type == "file" && existing.URL == candidate.URL && existing.Filename == candidate.Filename {
				duplicate = true
				break
			}
		}
		if !duplicate {
			parts = append(parts, candidate)
		}
	}
	return parts
}

type capabilityProgressFilter struct {
	fingerprints map[string]string
}

func newCapabilityProgressFilter() *capabilityProgressFilter {
	return &capabilityProgressFilter{fingerprints: map[string]string{}}
}

// shouldPersist is a second line of defense around third-party runtimes. A
// subagent heartbeat that only advances wall-clock fields does not change the
// durable conversation projection and must not trigger an event fsync plus a
// full snapshot rewrite.
func (filter *capabilityProgressFilter) shouldPersist(capability json.RawMessage) bool {
	var envelope struct {
		ID        string         `json:"id"`
		Operation string         `json:"operation"`
		Subagent  map[string]any `json:"subagent"`
	}
	if json.Unmarshal(capability, &envelope) != nil || envelope.ID != "subagents" || envelope.Operation != "upsert" || len(envelope.Subagent) == 0 {
		return true
	}
	id, ok := envelope.Subagent["id"].(string)
	if !ok || strings.TrimSpace(id) == "" {
		return true
	}
	durationMinute := int64(0)
	if duration, ok := envelope.Subagent["durationMs"].(float64); ok && duration > 0 {
		durationMinute = int64(duration) / int64(time.Minute/time.Millisecond)
	}
	delete(envelope.Subagent, "updatedAt")
	delete(envelope.Subagent, "durationMs")
	delete(envelope.Subagent, "recentOutput")
	material, err := json.Marshal(envelope.Subagent)
	if err != nil {
		return true
	}
	fingerprint := fmt.Sprintf("%s:%d", material, durationMinute)
	if filter.fingerprints[id] == fingerprint {
		return false
	}
	filter.fingerprints[id] = fingerprint
	return true
}

func (s *Service) noteTurnProgress(cardID, turnID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	current := s.active[cardID]
	if current == nil || current.turnID != turnID || current.recoveryErr != nil {
		return false
	}
	current.workerObserved = true
	current.lastProgress = time.Now()
	return true
}

func (s *Service) turnRecoveryFailure(cardID, turnID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	current := s.active[cardID]
	if current == nil || current.turnID != turnID {
		return nil
	}
	return current.recoveryErr
}

// ReconcileStalledTurns cancels workers whose independent protocol heartbeat
// has stopped. The owning runTurn goroutine durably records the failure before
// releasing the runtime lease, so a new message can resume the same
// conversation without replaying the prompt or losing its worktree.
func (s *Service) ReconcileStalledTurns(now time.Time) []string {
	if now.IsZero() {
		now = time.Now()
	}
	s.mu.Lock()
	stalled := make([]*activeTurn, 0)
	for _, turn := range s.active {
		if turn.suspend || turn.recoveryErr != nil {
			continue
		}
		limit := workerStartupTimeout
		last := turn.startedAt
		message := "agent worker did not start reporting progress"
		if turn.workerObserved {
			limit = workerHeartbeatTimeout
			last = turn.lastProgress
			message = "agent worker stopped reporting progress"
		}
		if last.IsZero() || now.Sub(last) <= limit {
			continue
		}
		turn.recoveryErr = errors.New(message + "; its workspace and durable conversation were preserved and can be resumed")
		stalled = append(stalled, turn)
	}
	s.mu.Unlock()
	result := make([]string, 0, len(stalled))
	for _, turn := range stalled {
		result = append(result, turn.cardID)
		turn.cancel()
	}
	return result
}

func (s *Service) runTurn(ctx context.Context, detail model.CardDetail, turnID string, request harness.Request, updates chan TurnUpdate, done chan struct{}) {
	finished := false
	finish := func(startQueued bool, finalCache store.CardCacheInput) error {
		if finished {
			return nil
		}
		finished = true
		refreshCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		_, _ = s.Workspaces.Refresh(refreshCtx, detail.Card.ID, false)
		updateErr := s.finishActive(detail.Card.ID, turnID, func() error {
			if finalCache.Runtime == "" {
				return nil
			}
			_, err := s.Store.UpdateCardCache(detail.Card.ID, finalCache)
			return err
		})
		if startQueued {
			s.startNextQueued(detail.Card.ID)
		}
		return updateErr
	}
	defer func() {
		_ = finish(false, store.CardCacheInput{})
		close(done)
		close(updates)
	}()
	streamFailed := false
	var reportedFailure error
	capabilityFilter := newCapabilityProgressFilter()
	err := s.Runner.Run(ctx, request, func(output harness.Output) error {
		if !s.noteTurnProgress(detail.Card.ID, turnID) {
			return context.Canceled
		}
		switch output.Type {
		case "heartbeat":
			return nil
		case "chunk":
			_, conversation, err := s.Store.AppendUIChunk(detail.Card.ID, turnID, output.Chunk)
			if err != nil {
				return err
			}
			if conversation.Status == "failed" {
				streamFailed = true
			}
			runtimeStatus := conversation.Status
			if runtimeStatus == "idle" {
				// A harness may emit its durable session and capability state after
				// the terminal UI chunk. Keep the card active until Runner.Run has
				// returned so clients cannot observe an idle card before those
				// trailing outputs are persisted.
				runtimeStatus = "running"
			}
			_, _ = s.Store.UpdateCardCache(detail.Card.ID, store.CardCacheInput{Provider: request.Harness, Model: request.ConfiguredModel, Runtime: runtimeStatus})
			select {
			case updates <- TurnUpdate{Chunk: output.Chunk}:
				return nil
			case <-ctx.Done():
				return ctx.Err()
			}
		case "session":
			_, err := s.Store.SetConversationSession(detail.Card.ID, turnID, output.State)
			return err
		case "capability":
			if !capabilityFilter.shouldPersist(output.Capability) {
				return nil
			}
			_, _, err := s.Store.AppendCapability(detail.Card.ID, turnID, output.Capability)
			return err
		case "error":
			// Keep consuming the worker protocol after its structured error frame.
			// SubprocessRunner appends stderr and non-protocol stdout diagnostics
			// only after the child exits; returning here used to kill the child and
			// discard the logs that explain the failure.
			if message := strings.TrimSpace(output.Message); message != "" {
				reportedFailure = errors.New(message)
			}
			return nil
		}
		return nil
	})
	if err == nil && reportedFailure != nil {
		err = reportedFailure
	}
	if recoveryErr := s.turnRecoveryFailure(detail.Card.ID, turnID); recoveryErr != nil {
		chunk, _ := json.Marshal(map[string]any{"type": "error", "errorText": recoveryErr.Error()})
		if _, _, appendErr := s.Store.AppendUIChunk(detail.Card.ID, turnID, chunk); appendErr != nil {
			recoveryErr = errors.Join(recoveryErr, appendErr)
		}
		if updateErr := finish(true, store.CardCacheInput{Runtime: "failed"}); updateErr != nil {
			recoveryErr = errors.Join(recoveryErr, updateErr)
		}
		select {
		case updates <- TurnUpdate{Chunk: chunk, Err: recoveryErr, Done: true}:
		default:
		}
		return
	}
	if s.turnIsSuspending(detail.Card.ID, turnID) {
		conversation, conversationErr := s.Store.Conversation(detail.Card.ID)
		if conversationErr == nil && hasTurnContinuation(conversation.Session) {
			conversation, _ = s.Store.SetConversationStatus(detail.Card.ID, turnID, "running")
			if conversation.ActiveTurn == nil {
				userMessageID := ""
				for index := len(conversation.Messages) - 1; index >= 0; index-- {
					if conversation.Messages[index].Role == "user" {
						userMessageID = conversation.Messages[index].ID
						break
					}
				}
				conversation, _ = s.Store.SetConversationActiveTurn(detail.Card.ID, model.ConversationTurn{ID: turnID, UserMessageID: userMessageID, ResponseMessageID: request.ResponseMessageID, Instructions: request.Instructions})
			}
			_, _ = s.Store.UpdateCardCache(detail.Card.ID, store.CardCacheInput{Provider: request.Harness, Model: request.ConfiguredModel, Runtime: "running"})
			_ = finish(false, store.CardCacheInput{})
			select {
			case updates <- TurnUpdate{Done: true}:
			default:
			}
			return
		}
	}
	if err == nil && !streamFailed {
		conversation, conversationErr := s.Store.Conversation(detail.Card.ID)
		if conversationErr == nil && assistantResponseEmpty(conversation) {
			message := emptyHarnessResponseMessage(request)
			chunk, _ := json.Marshal(map[string]any{"type": "error", "errorText": message})
			_, _, _ = s.Store.AppendUIChunk(detail.Card.ID, turnID, chunk)
			streamFailed = true
			select {
			case updates <- TurnUpdate{Chunk: chunk}:
			case <-ctx.Done():
			}
		}
	}
	if ctx.Err() != nil {
		chunk, _ := json.Marshal(map[string]any{"type": "abort"})
		_, _, _ = s.Store.AppendUIChunk(detail.Card.ID, turnID, chunk)
		// ACP implementations can persist the interrupted prompt inside their
		// own session even when the Harness continuation envelope is discarded.
		// A queued message must replace that prompt, so restart ACP cleanly.
		if request.Adapter == "omp-acp" || request.Adapter == "dsh-acp" {
			_, _ = s.Store.SetConversationSession(detail.Card.ID, turnID, json.RawMessage("null"))
		}
		_ = finish(true, store.CardCacheInput{Provider: request.Harness, Model: request.ConfiguredModel, Runtime: "idle"})
		select {
		case updates <- TurnUpdate{Chunk: chunk, Done: true}:
		default:
		}
		return
	}
	if err != nil {
		chunk, _ := json.Marshal(map[string]any{"type": "error", "errorText": err.Error()})
		_, _, _ = s.Store.AppendUIChunk(detail.Card.ID, turnID, chunk)
		_ = finish(true, store.CardCacheInput{Runtime: "failed"})
		select {
		case updates <- TurnUpdate{Chunk: chunk, Err: err, Done: true}:
		case <-ctx.Done():
		}
		return
	}
	finalRuntime := "idle"
	if streamFailed {
		finalRuntime = "failed"
	}
	_ = finish(true, store.CardCacheInput{Provider: request.Harness, Model: request.ConfiguredModel, Runtime: finalRuntime})
	select {
	case updates <- TurnUpdate{Done: true}:
	case <-ctx.Done():
	}
}

func emptyHarnessResponseMessage(request harness.Request) string {
	if request.Adapter == "claude-code" || request.Harness == "claude-code" {
		return "Claude Code completed without producing output; the durable session is preserved and can be resumed with another message"
	}
	return fmt.Sprintf("%s completed without a response; verify that the local harness is authenticated and that model %q is available", request.Harness, request.ConfiguredModel)
}

func (s *Service) turnIsSuspending(cardID, turnID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	current := s.active[cardID]
	return current != nil && current.cardID == cardID && current.turnID == turnID && current.suspend
}

func (s *Service) startNextQueued(cardID string) {
	conversation, err := s.Store.Conversation(cardID)
	if err != nil || len(conversation.Queue) == 0 {
		return
	}
	next := conversation.Queue[0]
	parts := next.Parts
	if len(parts) == 0 {
		parts = []model.UIMessagePart{{Type: "text", Text: next.Text}}
	}
	updates, err := s.startCard(cardID, next.Text, parts, "", "", "", nil, next.ID, "")
	if err == nil {
		go drainTurnUpdates(updates)
	}
}

func assistantResponseEmpty(conversation model.Conversation) bool {
	if len(conversation.Messages) == 0 {
		return true
	}
	last := conversation.Messages[len(conversation.Messages)-1]
	return last.Role == "assistant" && len(last.Parts) == 0
}

func drainTurnUpdates(updates <-chan TurnUpdate) {
	for range updates {
	}
}

func (s *Service) SendCard(ctx context.Context, ref, content, provider, modelName, effort string) error {
	updates, err := s.StartCard(ref, content, provider, modelName, effort)
	return s.waitForTurn(ctx, ref, updates, err)
}

func (s *Service) SendCardParts(ctx context.Context, ref string, parts []model.UIMessagePart, provider, modelName, effort string) error {
	updates, err := s.StartCardWithMessageParts(ref, parts, provider, modelName, effort, nil, "")
	return s.waitForTurn(ctx, ref, updates, err)
}

func (s *Service) waitForTurn(ctx context.Context, ref string, updates <-chan TurnUpdate, err error) error {
	if err != nil {
		return err
	}
	for {
		select {
		case <-ctx.Done():
			_ = s.CancelCard(ref)
			return ctx.Err()
		case update, ok := <-updates:
			if !ok {
				return nil
			}
			if update.Err != nil {
				return update.Err
			}
		}
	}
}

// SubmitCard starts a turn immediately or durably queues it behind the active
// turn on the same card. Queued turns are started in order when the current
// turn finishes or is interrupted.
func (s *Service) SubmitCard(ref, content, provider, modelName, effort string) (bool, error) {
	return s.SubmitCardParts(ref, []model.UIMessagePart{{Type: "text", Text: content}}, provider, modelName, effort, nil)
}

func (s *Service) SubmitCardParts(ref string, parts []model.UIMessagePart, provider, modelName, effort string, providerOptions map[string]string) (bool, error) {
	return s.SubmitCardPartsWithMessageID(ref, parts, provider, modelName, effort, providerOptions, "")
}

func (s *Service) SubmitCardPartsWithMessageID(ref string, parts []model.UIMessagePart, provider, modelName, effort string, providerOptions map[string]string, messageID string) (bool, error) {
	var err error
	parts, err = attachments.NormalizeMessageParts(parts)
	if err != nil {
		return false, err
	}
	card, err := s.Store.ResolveCard(ref)
	if err != nil {
		return false, err
	}
	content := messagePartsText(parts)
	if content == "" && !messagePartsHaveFiles(parts) {
		return false, errors.New("message is required")
	}
	s.mu.Lock()
	active := s.active[card.ID]
	if active != nil {
		if requested := strings.TrimSpace(provider); requested != "" && requested != card.Provider {
			s.mu.Unlock()
			return false, fmt.Errorf("conversation harness is locked to %q", card.Provider)
		}
		if requested := strings.TrimSpace(modelName); requested != "" && requested != card.Model {
			s.mu.Unlock()
			return false, fmt.Errorf("conversation model is locked to %q", card.Model)
		}
		requestedEffort := strings.TrimSpace(effort)
		comparisonEffort := requestedEffort
		if requestedEffort == "default" {
			comparisonEffort = ""
		}
		if requestedEffort != "" && comparisonEffort != card.Effort {
			s.mu.Unlock()
			locked := card.Effort
			if locked == "" {
				locked = "default"
			}
			return false, fmt.Errorf("conversation effort is locked to %q", locked)
		}
		if providerOptions != nil && !providerOptionsEqual(providerOptions, card.ProviderOptions) {
			adapter, valid := harness.ResolveAdapter(card.Provider, os.Getenv("DIETER_ENABLE_MOCK_HARNESS") == "1")
			if !valid {
				s.mu.Unlock()
				return false, fmt.Errorf("unsupported harness %q", card.Provider)
			}
			requestedOptions, resolveErr := harness.ResolveOptions(adapter, providerOptions)
			if resolveErr != nil {
				s.mu.Unlock()
				return false, resolveErr
			}
			lockedOptions, resolveErr := harness.ResolveOptions(adapter, card.ProviderOptions)
			if resolveErr != nil {
				s.mu.Unlock()
				return false, resolveErr
			}
			if !providerOptionsEqual(requestedOptions, lockedOptions) {
				s.mu.Unlock()
				return false, errors.New("conversation provider options are locked")
			}
		}
		_, _, err = s.Store.QueueConversationMessagePartsWithID(card.ID, messageID, parts)
		s.mu.Unlock()
		return err == nil, err
	}
	s.mu.Unlock()
	updates, err := s.StartCardWithMessageParts(card.ID, parts, provider, modelName, effort, providerOptions, messageID)
	if err != nil {
		return false, err
	}
	go drainTurnUpdates(updates)
	return false, nil
}

func (s *Service) CancelCard(ref string) error {
	card, err := s.Store.ResolveCard(ref)
	if err != nil {
		return err
	}
	s.mu.Lock()
	active := s.active[card.ID]
	s.mu.Unlock()
	if active == nil || active.cardID != card.ID {
		if canceller, ok := s.Runner.(harness.Canceller); ok {
			err = canceller.Cancel(card.ID, filepath.Join(s.Store.RuntimeDir(), "sessions", card.ProjectID))
			if err != nil && !errors.Is(err, os.ErrProcessDone) && !errors.Is(err, harness.ErrNoActiveTurn) {
				return err
			}
		}
		interrupted, err := s.Store.InterruptConversation(card.ID)
		if err != nil {
			return err
		}
		if interrupted {
			s.startNextQueued(card.ID)
		}
		return nil
	}
	active.cancel()
	select {
	case <-active.done:
		return nil
	case <-time.After(10 * time.Second):
		return errors.New("timed out waiting for the agent turn to stop")
	}
}

func (s *Service) clearActive(cardID, turnID string) {
	_ = s.finishActive(cardID, turnID, nil)
}

// finishActive keeps the in-process turn visible until its runtime lease is
// released and its last durable update is complete. Callers can therefore use
// the active map as a teardown barrier without racing the final store write.
func (s *Service) finishActive(cardID, turnID string, finalize func() error) error {
	s.mu.Lock()
	var lease store.RuntimeLease
	claimed := false
	current := s.active[cardID]
	if current != nil && current.cardID == cardID && current.turnID == turnID && !current.finishing {
		current.finishing = true
		lease = current.lease
		claimed = true
	}
	s.mu.Unlock()
	if !claimed {
		return nil
	}
	var releaseErr error
	if lease.Token != "" {
		releaseErr = s.Store.ReleaseRuntimeLease(lease)
	}
	var finalizeErr error
	if finalize != nil {
		finalizeErr = finalize()
	}
	s.mu.Lock()
	if s.active[cardID] == current {
		delete(s.active, cardID)
	}
	s.mu.Unlock()
	return errors.Join(releaseErr, finalizeErr)
}

func newRuntimeID(prefix string) string {
	buffer := make([]byte, 9)
	if _, err := rand.Read(buffer); err == nil {
		return prefix + hex.EncodeToString(buffer)
	}
	return fmt.Sprintf("%s%x%x", prefix, os.Getpid(), time.Now().UnixNano())
}
