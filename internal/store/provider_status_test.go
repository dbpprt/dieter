package store

import (
	"encoding/json"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func TestProviderStatusDescribesOnlyTheRunningResponse(t *testing.T) {
	s, project, board := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, Title: "Flaky provider"})
	if err != nil {
		t.Fatal(err)
	}
	startTurn := func(turnID, responseID string) {
		t.Helper()
		if _, err := s.SetConversationActiveTurn(card.ID, model.ConversationTurn{ID: turnID, UserMessageID: "user-" + turnID, ResponseMessageID: responseID}); err != nil {
			t.Fatal(err)
		}
		if _, err := s.StartConversationTurn(card.ID, turnID, "user-"+turnID, "Continue"); err != nil {
			t.Fatal(err)
		}
	}
	report := func(turnID, capability string) model.Conversation {
		t.Helper()
		_, conversation, err := s.AppendCapability(card.ID, turnID, json.RawMessage(capability))
		if err != nil {
			t.Fatal(err)
		}
		return conversation
	}
	reconnecting := func(messageID string, attempt int) string {
		raw, _ := json.Marshal(map[string]any{"id": "provider-status", "operation": "replace", "status": map[string]any{
			"state": "reconnecting", "attempt": attempt, "maxAttempts": 5, "message": "Reconnecting... 1/5 (stream disconnected)",
			"provider": "codex", "messageId": messageID, "updatedAt": "2026-09-29T13:08:05Z",
		}})
		return string(raw)
	}

	startTurn("turn-1", "response-1")
	conversation := report("turn-1", reconnecting("response-1", 1))
	if status := conversation.ProviderStatus; status == nil || status.State != "reconnecting" || status.Attempt != 1 || status.MaxAttempts != 5 || status.Provider != "codex" {
		t.Fatalf("reconnecting status=%+v", conversation.ProviderStatus)
	}
	if conversation := report("turn-1", reconnecting("another-response", 2)); conversation.ProviderStatus.Attempt != 1 {
		t.Fatalf("a report for another response replaced the status: %+v", conversation.ProviderStatus)
	}
	if conversation := report("turn-1", `{"id":"provider-status","operation":"clear"}`); conversation.ProviderStatus != nil {
		t.Fatalf("recovered stream retained status: %+v", conversation.ProviderStatus)
	}

	report("turn-1", reconnecting("response-1", 3))
	_, conversation, err = s.AppendUIChunk(card.ID, "turn-1", json.RawMessage(`{"type":"error","errorText":"stream disconnected before completion"}`))
	if err != nil {
		t.Fatal(err)
	}
	if conversation.Status != "failed" || conversation.ProviderStatus != nil {
		t.Fatalf("failed turn retained provider status: status=%s provider=%+v", conversation.Status, conversation.ProviderStatus)
	}
	// The worker tails notices beside its stream; a late report is stale.
	if conversation := report("turn-1", reconnecting("response-1", 4)); conversation.ProviderStatus != nil {
		t.Fatalf("late report revived a settled turn: %+v", conversation.ProviderStatus)
	}

	startTurn("turn-2", "response-2")
	report("turn-2", reconnecting("response-2", 1))
	_, conversation, err = s.AppendUIChunk(card.ID, "turn-2", json.RawMessage(`{"type":"finish"}`))
	if err != nil {
		t.Fatal(err)
	}
	if conversation.Status != "idle" || conversation.ProviderStatus != nil {
		t.Fatalf("finished turn retained provider status: status=%s provider=%+v", conversation.Status, conversation.ProviderStatus)
	}

	startTurn("turn-3", "response-3")
	report("turn-3", reconnecting("response-3", 2))
	// A cold read replays the journal to the same projection.
	cold, err := New(s.Root).Conversation(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if status := cold.ProviderStatus; status == nil || status.Attempt != 2 || status.MessageID != "response-3" {
		t.Fatalf("cold provider status=%+v", cold.ProviderStatus)
	}
}
