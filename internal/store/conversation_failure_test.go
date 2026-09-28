package store

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func TestFailedWorkerCapabilitiesReplayFromOldCheckpoint(t *testing.T) {
	s, project, board := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: project.ID, Board: board.ID, Title: "Failed worker"})
	if err != nil {
		t.Fatal(err)
	}
	// A v5 checkpoint could retain running children after a worker decode error.
	// Retain its authoritative events and verify a cold read rebuilds the state.
	events := []model.ConversationEvent{
		{Seq: 1, Type: "capability", Data: json.RawMessage(`{"id":"subagents","operation":"upsert","subagent":{"id":"research","provider":"claude-code","messageId":"response","status":"running"}}`)},
		{Seq: 2, Type: "capability", Data: json.RawMessage(`{"id":"subagents","operation":"upsert","subagent":{"id":"completed","provider":"claude-code","messageId":"response","status":"completed","recentOutput":["saved report"]}}`)},
		{Seq: 3, Type: "ui-chunk", CreatedAt: "2026-09-28T10:57:26Z", Data: json.RawMessage(`{"type":"error","errorText":"decode harness worker output: unexpected end of JSON input"}`)},
	}
	legacy := model.Conversation{ProjectionVersion: 5, CardID: card.ID, Status: "failed", LastSeq: 3,
		Subagents: []model.Subagent{{ID: "research", Provider: "claude-code", MessageID: "response", Status: "running"}}}
	dir := s.conversationPath(card.ID)
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	var journal []byte
	for _, event := range events {
		raw, err := json.Marshal(event)
		if err != nil {
			t.Fatal(err)
		}
		journal = append(journal, append(raw, '\n')...)
	}
	if err := os.WriteFile(filepath.Join(dir, "events.ndjson"), journal, 0600); err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(legacy)
	if err := os.WriteFile(filepath.Join(dir, "snapshot.json"), raw, 0600); err != nil {
		t.Fatal(err)
	}
	conversation, err := New(s.Root).Conversation(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if conversation.ProjectionVersion != conversationProjectionVersion || conversation.Status != "failed" || len(conversation.Subagents) != 2 {
		t.Fatalf("replayed conversation=%+v", conversation)
	}
	if agent := conversation.Subagents[0]; agent.Status != "failed" || agent.EndedAt != events[2].CreatedAt {
		t.Fatalf("replayed running child=%+v", agent)
	}
	if agent := conversation.Subagents[1]; agent.Status != "completed" || len(agent.RecentOutput) != 1 || agent.RecentOutput[0] != "saved report" {
		t.Fatalf("replayed completed child=%+v", agent)
	}
}
