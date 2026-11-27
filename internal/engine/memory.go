package engine

import (
	"context"
	"encoding/json"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
)

// MemoryRoleDreamer marks a dream conversation: its agent may change the
// project's saved memories with memory_apply. Only Dieter sets it, at
// creation.
const MemoryRoleDreamer = "dreamer"

// MemoryHooks connects agent memory (internal/host/memory) to turns. The
// engine tells it when a memory-enabled turn has finished and forwards the
// agent's memory host calls, bound to the conversation.
type MemoryHooks interface {
	// TurnFinished asks for the conversation's latest turn to be indexed.
	TurnFinished(cardID string)
	// ToolCall answers a memory host call (recall, save, apply) of a turn of
	// card on harness.
	ToolCall(ctx context.Context, card model.Card, harnessID string, call harness.ProcessCall) (json.RawMessage, error)
}

// MemoryActive reports whether a conversation's turns use agent memory: the
// project has memory on, the conversation's switch is on, and it is not a
// Strix scan.
func MemoryActive(project model.Project, card model.Card, adapterRuntime string) bool {
	return project.MemoryEnabled && card.Memory && adapterRuntime != strixAdapter
}

// SetCardMemory switches a local conversation's agent memory; the next turn
// gets (or loses) the memory tools and is (or is not) indexed.
func (s *Service) SetCardMemory(cardRef string, enabled bool) (model.Card, error) {
	card, err := s.Store.Kanban.ResolveCard(cardRef)
	if err != nil {
		return model.Card{}, err
	}
	if card.MemoryRole == MemoryRoleDreamer && !enabled {
		return model.Card{}, fault.New(fault.FailedPrecondition, "a dream conversation always has memory")
	}
	return s.Store.Kanban.SetMemory(cardRef, enabled)
}

// enableMemory gives a turn the memory tools, answered by the memory hooks
// with the conversation and its project bound.
func (s *Service) enableMemory(detail model.CardDetail, turnID string, request *harness.Request) {
	card, harnessID := detail.Card, request.Harness
	request.MemoryEnabled = true
	request.MemoryRole = card.MemoryRole
	request.MemoryCommand = s.CLIWord() + " memory search --project " + detail.Project.ID
	request.Memory = func(ctx context.Context, call harness.ProcessCall) (json.RawMessage, error) {
		endHostWork, _ := s.beginTurnHostWork(card.ID, turnID)
		defer endHostWork()
		return s.Memory.ToolCall(ctx, card, harnessID, call)
	}
}

// memoryTurnFinished hands a finished memory-enabled turn to the indexer.
func (s *Service) memoryTurnFinished(detail model.CardDetail, adapterRuntime string) {
	if s.Memory == nil {
		return
	}
	project, err := s.Store.Kanban.ResolveProject(detail.Project.ID)
	if err != nil {
		project = detail.Project
	}
	card, err := s.Store.Kanban.ResolveCard(detail.Card.ID)
	if err != nil {
		card = detail.Card
	}
	if MemoryActive(project, card, adapterRuntime) {
		s.Memory.TurnFinished(card.ID)
	}
}
