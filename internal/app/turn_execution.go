package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// This is part of Service's single turn owner. Service.mu, durable runtime leases,
// dispatch admission and finishActive retain their existing ordering and identity checks.

const (
	workerStartupTimeout   = 5 * time.Minute
	workerHeartbeatTimeout = 30 * time.Second
)

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

func (s *Service) runTurn(ctx context.Context, detail model.CardDetail, turnID string, request harness.Request, updates chan TurnUpdate, done chan struct{}) {
	if s.BackgroundProcesses != nil {
		request.BackgroundProcessesEnabled = true
		request.BackgroundProcess = func(ctx context.Context, call harness.ProcessCall) (json.RawMessage, error) {
			return s.BackgroundProcesses(ctx, detail.Card.ID, call)
		}
	}
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
		case "present-content":
			var presentation model.ContentPresentation
			if err := json.Unmarshal(output.Presentation, &presentation); err != nil {
				return err
			}
			_, err := s.PresentConversationContent(ctx, detail.Card.ID, turnID, presentation)
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
	suspending := s.turnIsSuspending(detail.Card.ID, turnID)
	if !suspending {
		if cleaner, ok := s.Runner.(harness.Cleaner); ok {
			if cleanupErr := cleaner.Cleanup(detail.Card.ID, request.RuntimeRoot); cleanupErr != nil {
				if err == nil {
					err = fmt.Errorf("clean provider bridge: %w", cleanupErr)
				} else {
					err = errors.Join(err, fmt.Errorf("clean provider bridge: %w", cleanupErr))
				}
			}
		}
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
	if suspending {
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
				conversation, _ = s.Store.SetConversationActiveTurn(detail.Card.ID, model.ConversationTurn{
					ID: turnID, UserMessageID: userMessageID, ResponseMessageID: request.ResponseMessageID,
					HarnessRuntimeDigest: request.RuntimeDigest, HarnessRuntimeProtocol: harness.RuntimeProtocolVersion,
					Instructions: request.Instructions,
					Selection:    &model.HarnessSelection{Provider: request.Harness, Model: request.ConfiguredModel, Effort: request.Effort, ProviderOptions: request.Options},
				})
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

func (s *Service) MergeCard(source, target string) (model.Card, error) {
	card, err := s.Store.MergeCard(source, target)
	if err == nil {
		s.startNextQueued(card.MergedIntoCardID)
	}
	return card, err
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
	var selection model.HarnessSelection
	if next.Selection != nil {
		selection = *next.Selection
	}
	effort := selection.Effort
	if next.Selection != nil {
		effort = selectionEffort(selection)
	}
	updates, err := s.startCard(cardID, next.Text, parts, selection.Provider, selection.Model, effort, selection.ProviderOptions, next.ID, next.ID)
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

func (s *Service) CancelCard(ref string) error {
	card, err := s.Store.ResolveCard(ref)
	if err != nil {
		return err
	}
	s.mu.Lock()
	active := s.active[card.ID]
	s.mu.Unlock()
	if active == nil || active.cardID != card.ID {
		lease, hasLease, leaseErr := s.Store.RuntimeLeaseForCard(card.ID)
		if leaseErr != nil {
			return leaseErr
		}
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
		if hasLease {
			if err := s.releaseLease(lease); err != nil {
				return err
			}
			s.mu.Lock()
			if current, ok := s.strandedLeases[card.ID]; ok && current.Token == lease.Token {
				delete(s.strandedLeases, card.ID)
			}
			s.mu.Unlock()
		}
		if interrupted {
			s.startNextQueued(card.ID)
		}
		return nil
	}
	active.cancel()
	// Cancellation is an admission command, not a join. Some providers only
	// return from an in-flight tool call after their own bounded cleanup. The
	// owning runTurn goroutine keeps the active-turn barrier in place and starts
	// the next queued message once that cleanup actually finishes.
	return nil
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
		releaseErr = s.releaseLease(lease)
	}
	var finalizeErr error
	if finalize != nil {
		finalizeErr = finalize()
	}
	s.mu.Lock()
	if releaseErr != nil {
		s.strandedLeases[cardID] = lease
	}
	if s.active[cardID] == current {
		delete(s.active, cardID)
	}
	s.mu.Unlock()
	return errors.Join(releaseErr, finalizeErr)
}
