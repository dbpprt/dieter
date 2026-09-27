package app

import (
	"context"
	"errors"
	"fmt"
	"github.com/dbpprt/dieter/internal/attachments"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"path/filepath"
	"strings"
	"time"
)

// This is part of Service's single turn owner. Service.mu, durable runtime leases,
// dispatch admission and finishActive retain their existing ordering and identity checks.

var ErrInsufficientStorage = errors.New("insufficient free disk space to start an agent turn")

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
	previousConversation, err := s.Store.Conversation(detail.Card.ID)
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
	adapter, configuredModel, selection, err := resolveTurnSelection(detail.Card, provider, modelName, effort, requestedOptions)
	if err != nil {
		return nil, err
	}
	provider, modelName, effort = selection.Provider, selection.Model, selection.Effort
	providerOptions := selection.ProviderOptions
	var providerAccountKey *string
	if s.ProviderAccountKey != nil {
		resolved := strings.TrimSpace(s.ProviderAccountKey(provider))
		providerAccountKey = &resolved
	}
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
		return nil, errors.New("Dieter is shutting down")
	}
	if active := s.active[detail.Card.ID]; active != nil {
		s.mu.Unlock()
		cancel()
		return nil, store.ErrCardActive
	}
	lease, err := s.Store.AcquireRuntimeLeaseFor(detail.Project.ID, detail.Board.ID, detail.Card.ID, provider)
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
		_ = s.Store.ReleaseRuntimeLease(lease)
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
	var startErr error
	if queueID == "" {
		_, startErr = s.Store.StartConversationTurnParts(detail.Card.ID, turnID, messageID, parts)
	} else {
		_, startErr = s.Store.StartQueuedConversationTurnParts(detail.Card.ID, turnID, messageID, queueID, parts)
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
	if _, startErr = s.Store.SetConversationActiveTurn(detail.Card.ID, model.ConversationTurn{
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
		_, err = s.Store.UpdateCardCache(detail.Card.ID, store.CardCacheInput{Provider: provider, ProviderAccountKey: providerAccountKey, Model: modelName, Effort: &effort, ProviderOptions: providerOptions})
		if err == nil {
			_, err = s.Store.MarkPromptSent(detail.Card.ID)
		}
	} else {
		_, err = s.Store.UpdateCardCache(detail.Card.ID, store.CardCacheInput{Provider: provider, ProviderAccountKey: providerAccountKey, Model: modelName, Effort: &effort, ProviderOptions: providerOptions, Runtime: "running"})
		if err == nil && detail.Card.Scope == model.ConversationScopeBoard && detail.Card.Lane != model.LaneRunning {
			_, err = s.Store.MoveCard(detail.Card.ID, model.LaneRunning, nil)
		}
	}
	if err != nil {
		cancel()
		s.clearActive(detail.Card.ID, turnID)
		close(done)
		return nil, err
	}

	conversation, _ := s.Store.Conversation(detail.Card.ID)
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
		ContentPresentationEnabled: true,
	}
	request.Prompt = harnessPrompt
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
	parts, err := attachments.NormalizeMessageParts(parts)
	if err != nil {
		return false, err
	}
	if messagePartsText(parts) == "" && !messagePartsHaveFiles(parts) {
		return false, errors.New("message is required")
	}
	for {
		card, err := s.Store.ResolveCard(ref)
		if err != nil {
			return false, err
		}
		s.mu.Lock()
		active := s.active[card.ID]
		if active != nil && active.selection.Provider != "" {
			card.Provider, card.Model, card.Effort, card.ProviderOptions = active.selection.Provider, active.selection.Model, active.selection.Effort, active.selection.ProviderOptions
			card.InitialPromptSentAt = "active"
		}
		s.mu.Unlock()
		if active != nil {
			// Discovery can contact a provider. Keep it outside the service lock
			// so configuration validation cannot stall unrelated active turns.
			_, _, selection, selectionErr := resolveTurnSelection(card, provider, modelName, effort, providerOptions)
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
			_, _, err = s.Store.QueueConversationMessageWithSelection(card.ID, messageID, parts, &selection)
			s.mu.Unlock()
			return err == nil, err
		}
		updates, err := s.StartCardWithMessageParts(card.ID, parts, provider, modelName, effort, providerOptions, messageID)
		if errors.Is(err, store.ErrCardActive) {
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
