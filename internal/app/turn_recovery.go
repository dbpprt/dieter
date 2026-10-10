package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/dbpprt/dieter/internal/harness"
	dieterprompt "github.com/dbpprt/dieter/internal/prompt"
	"github.com/dbpprt/dieter/internal/store"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// This is part of Service's single turn owner. Service.mu, durable runtime leases,
// dispatch admission and finishActive retain their existing ordering and identity checks.

// ReconcileOrphanedTurns resumes turns that were cleanly suspended by a
// previous Dieter process. A turn without a provider continuation is closed as
// interrupted; its prompt is never replayed because that could duplicate file
// edits or external side effects.
func (s *Service) ReconcileOrphanedTurns() ([]string, error) {
	targets, mergeErr := s.Store.RecoverCardMerges()
	if mergeErr != nil {
		return nil, mergeErr
	}
	recovered, strandedErr := s.retryStrandedRuntimeLeases("")
	cards, err := s.Store.OrphanedTurnCards()
	if err != nil {
		return recovered, errors.Join(strandedErr, err)
	}
	var recoveryErrors []error
	if strandedErr != nil {
		recoveryErrors = append(recoveryErrors, strandedErr)
	}
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
	for _, target := range targets {
		s.startNextQueued(target)
	}
	return uniqueStrings(recovered), errors.Join(recoveryErrors...)
}

// WaitForRecoveredTurns confirms that every resumed worker has crossed the
// process protocol boundary. A terminal turn is also ready: it completed
// durably before the readiness observer saw its first heartbeat. This is used
// only while qualifying a newly activated daemon binary, before the service
// runtime discards its rollback candidate.
func (s *Service) WaitForRecoveredTurns(ctx context.Context, cards []string) error {
	pending := make(map[string]struct{}, len(cards))
	for _, cardID := range uniqueStrings(cards) {
		if cardID != "" {
			pending[cardID] = struct{}{}
		}
	}
	if len(pending) == 0 {
		return nil
	}
	ticker := time.NewTicker(25 * time.Millisecond)
	defer ticker.Stop()
	for len(pending) > 0 {
		inactive := make([]string, 0)
		s.mu.Lock()
		for cardID := range pending {
			turn := s.active[cardID]
			if turn == nil {
				inactive = append(inactive, cardID)
				continue
			}
			if turn.recoveryErr != nil {
				err := turn.recoveryErr
				s.mu.Unlock()
				return fmt.Errorf("recovered turn %s failed before readiness: %w", cardID, err)
			}
			if turn.workerObserved {
				delete(pending, cardID)
			}
		}
		s.mu.Unlock()
		for _, cardID := range inactive {
			conversation, err := s.Store.Conversation(cardID)
			if err != nil {
				return fmt.Errorf("inspect recovered turn %s: %w", cardID, err)
			}
			switch conversation.Status {
			case "running":
				return fmt.Errorf("recovered turn %s has no owning worker", cardID)
			case "failed":
				return fmt.Errorf("recovered turn %s failed before readiness", cardID)
			default:
				delete(pending, cardID)
			}
		}
		if len(pending) == 0 {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("wait for recovered agent workers: %w", ctx.Err())
		case <-ticker.C:
		}
	}
	return nil
}

// CleanupInactiveProviderBridges removes detached provider bridges left by a
// previous worker failure. It runs once during daemon startup, after resumable
// turns have been reacquired into s.active, so clean restart continuations are
// preserved while idle, failed, interrupted, and archived conversations cannot
// retain an unowned SDK thread writer.
func (s *Service) CleanupInactiveProviderBridges() ([]string, error) {
	cleaner, ok := s.Runner.(harness.Cleaner)
	if !ok {
		return nil, nil
	}
	projects, err := s.Store.ListProjects()
	if err != nil {
		return nil, err
	}
	cleaned := make([]string, 0)
	var cleanupErrors []error
	for _, project := range projects {
		cards, listErr := s.Store.ListCards(store.CardFilter{Project: project.ID, IncludeArchived: true})
		if listErr != nil {
			cleanupErrors = append(cleanupErrors, fmt.Errorf("list provider bridges for project %s: %w", project.ID, listErr))
			continue
		}
		for _, card := range cards {
			s.mu.Lock()
			active := s.active[card.ID] != nil
			s.mu.Unlock()
			if active {
				continue
			}
			runtimeRoot := filepath.Join(s.Store.RuntimeDir(), "sessions", project.ID)
			stateDirs, stateErr := harness.ProviderBridgeStateDirs(card.ID, runtimeRoot)
			if stateErr != nil {
				cleanupErrors = append(cleanupErrors, fmt.Errorf("inspect provider bridge %s: %w", card.ID, stateErr))
				continue
			}
			found := false
			for _, stateDir := range stateDirs {
				if _, statErr := os.Stat(filepath.Join(stateDir, "bridge-meta.json")); statErr == nil {
					found = true
					break
				} else if !errors.Is(statErr, os.ErrNotExist) {
					cleanupErrors = append(cleanupErrors, fmt.Errorf("inspect provider bridge %s: %w", card.ID, statErr))
				}
			}
			if !found {
				continue
			}
			if cleanupErr := cleaner.Cleanup(card.ID, runtimeRoot); cleanupErr != nil {
				cleanupErrors = append(cleanupErrors, fmt.Errorf("clean inactive provider bridge %s: %w", card.ID, cleanupErr))
				continue
			}
			cleaned = append(cleaned, card.ID)
		}
	}
	return cleaned, errors.Join(cleanupErrors...)
}

func uniqueStrings(values []string) []string {
	seen := make(map[string]struct{}, len(values))
	unique := make([]string, 0, len(values))
	for _, value := range values {
		if _, ok := seen[value]; ok {
			continue
		}
		seen[value] = struct{}{}
		unique = append(unique, value)
	}
	return unique
}

// retryStrandedRuntimeLeases repairs leases whose owning turn already finished
// in this process but whose durable release failed, typically because the disk
// was full. Token-matched release cannot remove a newer turn's lease.
func (s *Service) retryStrandedRuntimeLeases(cardID string) ([]string, error) {
	s.mu.Lock()
	leases := make([]store.RuntimeLease, 0, len(s.strandedLeases))
	for id, lease := range s.strandedLeases {
		if cardID == "" || id == cardID {
			leases = append(leases, lease)
		}
	}
	s.mu.Unlock()
	released := make([]string, 0, len(leases))
	var releaseErrors []error
	for _, lease := range leases {
		if err := s.releaseLease(lease); err != nil {
			releaseErrors = append(releaseErrors, fmt.Errorf("release stranded turn %s: %w", lease.CardID, err))
			continue
		}
		s.mu.Lock()
		if current, ok := s.strandedLeases[lease.CardID]; ok && current.Token == lease.Token {
			delete(s.strandedLeases, lease.CardID)
			released = append(released, lease.CardID)
		}
		s.mu.Unlock()
	}
	return released, errors.Join(releaseErrors...)
}

var errNoTurnContinuation = errors.New("conversation has no suspended turn continuation")

func hasTurnContinuation(state json.RawMessage) bool {
	var envelope struct {
		ContinueFrom json.RawMessage `json:"continueFrom"`
	}
	return json.Unmarshal(state, &envelope) == nil && len(envelope.ContinueFrom) > 0 && string(envelope.ContinueFrom) != "null"
}

func prepareHarnessRuntime(ctx context.Context, runner harness.Runner, digest string) (harness.RuntimeReference, error) {
	provider, ok := runner.(harness.RuntimeProvider)
	if !ok {
		return harness.RuntimeReference{Digest: digest}, nil
	}
	return provider.PrepareRuntime(ctx, digest)
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
	selection := selectionFromCard(detail.Card)
	if conversation.ActiveTurn != nil && conversation.ActiveTurn.Selection != nil {
		selection = *conversation.ActiveTurn.Selection
	}
	adapter, configuredModel, err := resolvePersistedSelection(selection.Provider, selection.Model, os.Getenv("DIETER_ENABLE_MOCK_HARNESS") == "1")
	if err != nil {
		return err
	}
	// Provider discovery may not have run yet in a freshly restarted Dieter
	// process. The locked model and effort were validated when the conversation
	// was created, so recovery must trust those persisted values rather than
	// rejecting a live continuation against the smaller release fallback list.
	effort := selection.Effort
	providerOptions, err := harness.ResolveOptionsForModel(adapter, configuredModel.ID, selection.ProviderOptions)
	if err != nil {
		return err
	}
	pinnedDigest := ""
	if conversation.ActiveTurn != nil {
		pinnedDigest = conversation.ActiveTurn.HarnessRuntimeDigest
		if protocol := conversation.ActiveTurn.HarnessRuntimeProtocol; protocol != "" && protocol != harness.RuntimeProtocolVersion {
			return fmt.Errorf("active turn requires harness runtime protocol %s; this daemon supports %s", protocol, harness.RuntimeProtocolVersion)
		}
	}
	runtimeCtx, runtimeCancel := context.WithTimeout(context.Background(), workerStartupTimeout)
	runtimeReference, err := prepareHarnessRuntime(runtimeCtx, s.Runner, pinnedDigest)
	runtimeCancel()
	if err != nil {
		return err
	}
	resolution := dieterprompt.Resolution{}
	lease, err := s.Store.AcquireRuntimeLeaseFor(detail.Project.ID, detail.Board.ID, detail.Card.ID, adapter.ID)
	if err != nil {
		return err
	}
	if lease.Detail != nil {
		detail = *lease.Detail
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
	if lease.Detail != nil {
		detail = *lease.Detail
	}
	s.active[detail.Card.ID] = &activeTurn{selection: selection, cancel: cancel, cardID: detail.Card.ID, turnID: turnID, lease: lease, done: done, startedAt: now, lastProgress: now}
	s.mu.Unlock()
	updates := make(chan TurnUpdate, 1024)
	workspaceValue, err := s.Workspaces.Ensure(context.Background(), detail.Card.ID)
	if err != nil {
		cancel()
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
		ContentPresentationEnabled: true, RuntimeDigest: runtimeReference.Digest,
		Environment: s.agentEnvironment(detail.Card.ID, turnID),
	}
	// The card is the active/last-admitted selection shown by clients. Restore
	// every field from the same snapshot used by the recovered request.
	if _, err := s.Store.UpdateCardCache(detail.Card.ID, store.CardCacheInput{Provider: adapter.ID, Model: configuredModel.ID, Effort: &effort, ProviderOptions: providerOptions, Runtime: "running"}); err != nil {
		cancel()
		_ = s.Store.ReleaseRuntimeLease(lease)
		s.clearActive(detail.Card.ID, turnID)
		close(done)
		return err
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
	titleJobs := make([]*quickTitleJob, 0, len(s.quickTitleJobs))
	for _, job := range s.quickTitleJobs {
		job.cancel()
		titleJobs = append(titleJobs, job)
	}
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
				s.mu.Lock()
				if current := s.active[turn.cardID]; current == turn {
					current.suspend = false
				}
				s.mu.Unlock()
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
				if cleaner, ok := s.Runner.(harness.Cleaner); ok {
					detail, detailErr := s.Store.CardDetail(result.turn.cardID)
					if detailErr != nil {
						suspensionErrors = append(suspensionErrors, detailErr)
					} else if cleanupErr := cleaner.Cleanup(result.turn.cardID, filepath.Join(s.Store.RuntimeDir(), "sessions", detail.Project.ID)); cleanupErr != nil {
						suspensionErrors = append(suspensionErrors, fmt.Errorf("clean failed suspension %s: %w", result.turn.cardID, cleanupErr))
					}
				}
			}
		case <-ctx.Done():
			return errors.Join(append(suspensionErrors, ctx.Err())...)
		}
	}
	for _, job := range titleJobs {
		select {
		case <-job.done:
		case <-ctx.Done():
			return errors.Join(append(suspensionErrors, ctx.Err())...)
		}
	}
	return errors.Join(suspensionErrors...)
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
		if turn.suspend || turn.recoveryErr != nil || turn.hostWork > 0 {
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
