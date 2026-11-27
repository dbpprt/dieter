package engine

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"path/filepath"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/engine/accounts"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/leases"
)

// This is part of Service's single turn owner. Service.mu, durable runtime leases,
// dispatch admission and finishActive retain their existing ordering and identity checks.

var ErrInsufficientStorage = fault.New(fault.ResourceExhausted, "insufficient free disk space to start an agent turn")

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

func (s *Service) StartCard(ref, content, provider, modelName, effort string) (<-chan TurnUpdate, error) {
	return s.startCard(ref, content, nil, model.HarnessSelection{Provider: provider, Model: modelName, Effort: effort}, "", "")
}

func (s *Service) StartCardWithMessageID(ref, content, provider, modelName, effort, messageID string) (<-chan TurnUpdate, error) {
	return s.startCard(ref, content, nil, model.HarnessSelection{Provider: provider, Model: modelName, Effort: effort}, "", messageID)
}

func (s *Service) StartCardWithMessageParts(ref string, parts []model.UIMessagePart, provider, modelName, effort string, providerOptions map[string]string, messageID string) (<-chan TurnUpdate, error) {
	return s.StartCardWithSelection(ref, parts, model.HarnessSelection{Provider: provider, Model: modelName, Effort: effort, ProviderOptions: providerOptions}, messageID)
}

// StartCardWithSelection starts a turn with a full selection, including the
// provider account; empty fields keep the conversation's choice.
func (s *Service) StartCardWithSelection(ref string, parts []model.UIMessagePart, selection model.HarnessSelection, messageID string) (<-chan TurnUpdate, error) {
	return s.startCard(ref, messagePartsText(parts), parts, selection, "", messageID)
}

func (s *Service) startCard(ref, content string, parts []model.UIMessagePart, requested model.HarnessSelection, queueID, messageID string) (<-chan TurnUpdate, error) {
	detail, err := s.Store.Kanban.CardDetail(ref)
	if err != nil {
		return nil, err
	}
	previousConversation, err := s.Store.Conversations.Get(detail.Card.ID)
	if err != nil {
		return nil, err
	}
	first := detail.Card.InitialPromptSentAt == ""
	if first {
		if strings.TrimSpace(content) == "" && messagePartsText(parts) == "" {
			content = detail.Card.InitialPrompt
		}
		parts = mergeInitialMessageParts(content, parts, previousConversation.DraftAttachments)
	}
	if len(parts) > 0 {
		parts, err = model.NormalizeMessageParts(parts)
		if err != nil {
			return nil, err
		}
	}
	content = strings.TrimSpace(content)
	if text := messagePartsText(parts); text != "" {
		content = text
	}
	if content == "" && !messagePartsHaveFiles(parts) {
		return nil, fault.New(fault.Invalid, "message is required")
	}
	if len(parts) == 0 {
		parts = []model.UIMessagePart{{Type: "text", Text: content}}
	}
	adapter, configuredModel, selection, err := resolveTurnSelection(s.Catalog, detail.Card, requested)
	if err != nil {
		return nil, err
	}
	turnAuth, err := s.resolveTurnAuth(adapter.Runtime, &selection)
	if err != nil {
		return nil, err
	}
	selection.AccountID = turnAuth.AccountID
	provider, modelName, effort := selection.Provider, selection.Model, selection.Effort
	providerOptions := selection.ProviderOptions
	var strix strixTurn
	if adapter.Runtime == strixAdapter {
		if strix, err = s.prepareStrixTurn(detail.Card, configuredModel.RuntimeID(), providerOptions); err != nil {
			return nil, err
		}
	}
	providerAccountID := turnAuth.AccountID
	if err := s.ensureStartStorage(s.Store.Root, detail.Project.Path); err != nil {
		return nil, err
	}
	runtimeCtx, runtimeCancel := context.WithTimeout(context.Background(), workerStartupTimeout)
	runtimeReference, err := prepareHarnessRuntime(runtimeCtx, s.Runner, "")
	runtimeCancel()
	if err != nil {
		return nil, err
	}
	if _, err := s.retryStrandedRuntimeLeases(detail.Card.ID); err != nil {
		return nil, err
	}
	turnID, responseMessageID := newRuntimeID("turn_"), newRuntimeID("msg_")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	now := time.Now()
	s.mu.Lock()
	if s.shuttingDown {
		s.mu.Unlock()
		cancel()
		return nil, fault.New(fault.Invalid, "Dieter is shutting down")
	}
	if active := s.active[detail.Card.ID]; active != nil {
		s.mu.Unlock()
		cancel()
		return nil, leases.ErrCardActive
	}
	lease, err := s.Store.Kanban.AcquireRuntimeLeaseFor(detail.Project.ID, detail.Board.ID, detail.Card.ID, provider)
	if err != nil {
		s.mu.Unlock()
		cancel()
		return nil, err
	}
	if lease.Detail != nil {
		detail = *lease.Detail
	}
	s.active[detail.Card.ID] = &activeTurn{selection: selection, cancel: cancel, cardID: detail.Card.ID, turnID: turnID, lease: lease, done: done, startedAt: now, lastProgress: now}
	s.mu.Unlock()
	workspaceValue, err := s.Workspaces.Ensure(context.Background(), detail.Card.ID)
	if err != nil {
		cancel()
		_ = s.Store.Leases.Release(lease)
		s.clearActive(detail.Card.ID, turnID)
		close(done)
		return nil, err
	}
	resolution, err := s.resolveInstructions(detail, workspaceValue)
	if err != nil {
		cancel()
		s.clearActive(detail.Card.ID, turnID)
		close(done)
		return nil, err
	}

	if strings.TrimSpace(messageID) == "" {
		messageID = newRuntimeID("msg_")
	}
	channelPlan := s.planChannelTurn(detail, messageID)
	var startErr error
	if queueID == "" {
		_, startErr = s.Store.Conversations.StartTurnParts(detail.Card.ID, turnID, messageID, parts)
	} else {
		_, startErr = s.Store.Conversations.StartQueuedTurnParts(detail.Card.ID, turnID, messageID, queueID, parts)
	}
	if startErr != nil {
		cancel()
		s.clearActive(detail.Card.ID, turnID)
		close(done)
		return nil, startErr
	}
	labelIDs := make([]string, 0, len(resolution.AppliedLabels))
	for _, label := range resolution.AppliedLabels {
		labelIDs = append(labelIDs, label.ID)
	}
	if _, startErr = s.Store.Conversations.SetActiveTurn(detail.Card.ID, model.ConversationTurn{
		ID: turnID, UserMessageID: messageID, ResponseMessageID: responseMessageID,
		HarnessRuntimeDigest: runtimeReference.Digest, HarnessRuntimeProtocol: runtimeReference.ProtocolVersion,
		Instructions: resolution.Instructions, InstructionSource: resolution.Source, InstructionLabels: labelIDs,
		Selection: &selection, SettingsRevisions: lease.SettingsRevisions,
	}); startErr != nil {
		cancel()
		s.clearActive(detail.Card.ID, turnID)
		close(done)
		return nil, startErr
	}
	if first {
		_, err = s.Store.Kanban.UpdateCardCache(detail.Card.ID, kanban.CardCacheInput{Provider: provider, ProviderAccountID: &providerAccountID, Model: modelName, Effort: &effort, ProviderOptions: providerOptions})
		if err == nil {
			_, err = s.Store.Kanban.MarkPromptSent(detail.Card.ID)
		}
	} else {
		_, err = s.Store.Kanban.UpdateCardCache(detail.Card.ID, kanban.CardCacheInput{Provider: provider, ProviderAccountID: &providerAccountID, Model: modelName, Effort: &effort, ProviderOptions: providerOptions, Runtime: "running"})
		if err == nil && detail.Card.Scope == model.ConversationScopeBoard && detail.Card.Lane != model.LaneRunning {
			_, err = s.Store.Kanban.MoveCard(detail.Card.ID, model.LaneRunning, nil)
		}
	}
	if err != nil {
		cancel()
		s.clearActive(detail.Card.ID, turnID)
		close(done)
		return nil, err
	}

	conversation, _ := s.Store.Conversations.Get(detail.Card.ID)
	updates := make(chan TurnUpdate, 1024)
	harnessPrompt := content
	if len(conversation.ForkSeed) > 0 && len(conversation.Session) == 0 {
		harnessPrompt = forkedConversationPrompt(conversation.ForkSeed, content)
	} else if previousConversation.Status == "interrupted" {
		harnessPrompt = interruptedConversationPrompt(previousConversation, content)
	}
	request := harness.Request{
		Harness: provider, Adapter: adapter.Runtime, Model: configuredModel.RuntimeID(), ConfiguredModel: modelName, ContextWindow: configuredModel.ContextWindow, Effort: effort, Options: providerOptions, Prompt: content, ResponseMessageID: responseMessageID,
		Attachments:  messagePartsAttachments(parts),
		Instructions: resolution.Instructions, SessionID: detail.Card.ID, Session: conversation.Session,
		ProjectPath:                workspaceValue.Path,
		RuntimeRoot:                filepath.Join(s.Store.RuntimeDir(), "sessions", detail.Project.ID),
		RuntimeDigest:              runtimeReference.Digest,
		DieterExecutable:           s.CLIExecutable,
		ContentPresentationEnabled: true,
		PresentCommand:             s.CLIWord() + " " + conversationGroup(detail.Card) + " present " + detail.Card.ID,
		Environment:                s.agentEnvironment(detail.Card.ID, turnID),
	}
	applyTurnAuth(turnAuth, &request)
	if adapter.Runtime == strixAdapter {
		// Strix gets the submitted instruction directly: no channel
		// digest, steering or coding-agent context.
		strix.apply(s, detail.Card.ID, workspaceValue, &request)
	} else {
		request.Prompt = channelPlan.prompt(harnessPrompt)
		s.commitChannelTurn(detail.Card.ID, channelPlan, &request)
	}
	go s.runTurn(ctx, detail, turnID, request, updates, done)
	return updates, nil
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
	return s.SubmitCardPartsWithSelection(ref, parts, model.HarnessSelection{Provider: provider, Model: modelName, Effort: effort, ProviderOptions: providerOptions}, messageID)
}

// SubmitCardPartsWithSelection starts or queues a message with a full
// selection, including the provider account.
func (s *Service) SubmitCardPartsWithSelection(ref string, parts []model.UIMessagePart, requested model.HarnessSelection, messageID string) (bool, error) {
	parts, err := model.NormalizeMessageParts(parts)
	if err != nil {
		return false, err
	}
	if messagePartsText(parts) == "" && !messagePartsHaveFiles(parts) {
		return false, fault.New(fault.Invalid, "message is required")
	}
	for {
		card, err := s.Store.Kanban.ResolveCard(ref)
		if err != nil {
			return false, err
		}
		s.mu.Lock()
		active := s.active[card.ID]
		if active != nil && active.selection.Provider != "" {
			card.Provider, card.Model, card.Effort, card.ProviderOptions = active.selection.Provider, active.selection.Model, active.selection.Effort, active.selection.ProviderOptions
			card.ProviderAccountID = active.selection.AccountID
			card.InitialPromptSentAt = "active"
		}
		s.mu.Unlock()
		if active != nil {
			// Discovery can contact a provider. Keep it outside the service lock
			// so configuration validation cannot stall unrelated active turns.
			_, _, selection, selectionErr := resolveTurnSelection(s.Catalog, card, requested)
			if selectionErr != nil {
				return false, selectionErr
			}
			s.mu.Lock()
			if s.active[card.ID] != active {
				s.mu.Unlock()
				continue
			}
			// Each message owns its selection; never change the active turn's
			// card configuration when admitting a future turn.
			_, _, err = s.Store.Conversations.QueueMessageWithSelection(card.ID, messageID, parts, &selection)
			s.mu.Unlock()
			return err == nil, err
		}
		updates, err := s.StartCardWithSelection(card.ID, parts, requested, messageID)
		if errors.Is(err, leases.ErrCardActive) {
			s.mu.Lock()
			started := s.active[card.ID] != nil
			s.mu.Unlock()
			if started {
				continue
			}
		}
		if err != nil {
			return false, err
		}
		go drainTurnUpdates(updates)
		return false, nil
	}
}

// resolveTurnAuth resolves the provider accounts a Claude Code, Codex or Oh
// My Pi turn runs on. An Oh My Pi turn also records its advisor's account in
// the selection's advisor_account option. Without an accounts engine (tests
// with injected runners, tools) turns keep the adapters' own credentials;
// other adapters have no accounts.
func (s *Service) resolveTurnAuth(adapterRuntime string, selection *model.HarnessSelection) (accounts.TurnAuth, error) {
	switch adapterRuntime {
	case "claude-code", "codex", ompAdapter:
	default:
		return accounts.TurnAuth{}, nil
	}
	if s.Accounts == nil {
		return accounts.TurnAuth{AccountID: selection.AccountID}, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), turnAuthTimeout)
	defer cancel()
	if adapterRuntime != ompAdapter {
		return s.Accounts.ResolveTurn(ctx, adapterRuntime, selection.AccountID)
	}
	options := selection.ProviderOptions
	turn, err := s.Accounts.ResolveOMPTurn(ctx, selection.Model, selection.AccountID, options[ompAdvisorModelOption], options[ompAdvisorAccountOption])
	if err != nil {
		return accounts.TurnAuth{}, err
	}
	selection.ProviderOptions = withOMPAdvisorAccount(options, turn.AdvisorAccountID)
	return accounts.TurnAuth{AccountID: turn.AccountID}, nil
}

// withOMPAdvisorAccount returns options with the resolved advisor account,
// or without one when the turn has no advisor on another provider's account.
func withOMPAdvisorAccount(options map[string]string, accountID string) map[string]string {
	if options[ompAdvisorAccountOption] == accountID {
		return options
	}
	next := maps.Clone(options)
	if next == nil {
		next = map[string]string{}
	}
	if accountID == "" {
		delete(next, ompAdvisorAccountOption)
	} else {
		next[ompAdvisorAccountOption] = accountID
	}
	return next
}

// Oh My Pi's adapter and its advisor options (harnesses.yaml).
const (
	ompAdapter              = "omp-acp"
	ompAdvisorModelOption   = "advisor_model"
	ompAdvisorAccountOption = "advisor_account"
)

// turnAuthTimeout bounds account resolution, which may refresh a Codex token.
const turnAuthTimeout = 45 * time.Second

// applyTurnAuth hands a turn its account: environment additions (the
// account's config directory or Codex home, masked host keys) and the
// adapter's auth object.
func applyTurnAuth(auth accounts.TurnAuth, request *harness.Request) {
	request.ProviderAccountID = auth.AccountID
	request.Auth = auth.Auth
	if len(auth.Env) == 0 {
		return
	}
	if request.Environment == nil {
		request.Environment = make(map[string]string, len(auth.Env))
	}
	for key, value := range auth.Env {
		request.Environment[key] = value
	}
}
