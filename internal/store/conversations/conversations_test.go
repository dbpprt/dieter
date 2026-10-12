package conversations_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fsx"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/conversations"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestDraftAttachmentEventsReplayBeyondLegacyScannerLimit(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Large attachment", Prompt: "Inspect it"})
	if err != nil {
		t.Fatal(err)
	}
	part := model.UIMessagePart{
		Type: "file", MediaType: "application/octet-stream", Filename: "fixture.bin",
		URL: "data:application/octet-stream;base64," + strings.Repeat("A", 5<<20),
	}
	if _, err := s.Conversations.SetDraftAttachments(card.ID, []model.UIMessagePart{part}); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(s.Conversations.Path(card.ID), "snapshot.json")); err != nil {
		t.Fatal(err)
	}
	replayed, err := s.Conversations.Get(card.ID)
	if err != nil || len(replayed.DraftAttachments) != 1 || replayed.DraftAttachments[0].Filename != "fixture.bin" {
		t.Fatalf("replayed draft=%#v err=%v", replayed.DraftAttachments, err)
	}
}

func TestConversationEventDoesNotOverwriteConcurrentLaneMove(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{
		Project: project.ID, Board: board.ID, ID: "card_lane_race", Lane: model.LaneRunning,
		Title: "Preserve review lane", Prompt: "Implement it.",
	})
	if err != nil {
		t.Fatal(err)
	}

	// Simulate another Dieter process holding the central storage lock. The
	// conversation writer must acquire that lock before reading the card whose
	// activity timestamp it will update.
	lock, err := fsx.LockHome(context.Background(), s.Root)
	if err != nil {
		t.Fatal(err)
	}
	unlock := func() { _ = lock.Close() }
	lockHeld := true
	t.Cleanup(func() {
		if lockHeld {
			unlock()
		}
	})

	appended := make(chan error, 1)
	go func() {
		_, _, appendErr := s.Conversations.AppendUIChunk(card.ID, "turn_1", json.RawMessage(`{"type":"text","text":"Ready"}`))
		appended <- appendErr
	}()

	deadline := time.Now().Add(2 * time.Second)
	for !s.WriterQueued() {
		if time.Now().After(deadline) {
			t.Fatal("conversation writer did not wait on the storage lock")
		}
		time.Sleep(time.Millisecond)
	}

	// This direct write represents the mutation completed by the process that
	// owns the writer lock. Releasing the lock lets the event writer continue.
	card.Lane = model.LaneReview
	card.PhaseChangedAt = "2026-08-24T07:34:45Z"
	card.UpdatedAt = card.PhaseChangedAt
	if err := s.Kanban.WriteCard(card); err != nil {
		t.Fatal(err)
	}
	unlock()
	lockHeld = false

	select {
	case err := <-appended:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("conversation event did not finish")
	}
	stored, err := s.Kanban.ResolveCard(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if stored.Lane != model.LaneReview || stored.PhaseChangedAt != card.PhaseChangedAt {
		t.Fatalf("conversation event restored stale lane metadata: %#v", stored)
	}
}

func TestInterruptConversationReconcilesOrphanedRuntime(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, ID: "card_orphan", Title: "Recover me", Prompt: "Work"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Conversations.StartTurn(card.ID, "turn_orphan", "user_orphan", "Start working"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.UpdateCardCache(card.ID, kanban.CardCacheInput{Runtime: "running"}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Conversations.AppendCapability(card.ID, "turn_orphan", json.RawMessage(`{"id":"subagents","operation":"upsert","subagent":{"id":"child","provider":"codex","messageId":"assistant","status":"running"}}`)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Conversations.AppendCapability(card.ID, "turn_orphan", json.RawMessage(`{"id":"task-plan","operation":"replace","plan":{"id":"plan","provider":"codex","messageId":"assistant","state":"active","phases":[{"tasks":[{"content":"Inspect","status":"in_progress"}]}]}}`)); err != nil {
		t.Fatal(err)
	}

	orphans, err := s.Conversations.OrphanedTurnCards()
	if err != nil || len(orphans) != 1 || orphans[0].ID != card.ID {
		t.Fatalf("orphans=%#v err=%v", orphans, err)
	}
	interrupted, err := s.Conversations.Interrupt(card.ID)
	if err != nil || !interrupted {
		t.Fatalf("interrupted=%v err=%v", interrupted, err)
	}
	conversation, err := s.Conversations.Get(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	stored, err := s.Kanban.ResolveCard(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if conversation.Status != "interrupted" || stored.Runtime != "idle" {
		t.Fatalf("conversation status=%q card runtime=%q", conversation.Status, stored.Runtime)
	}
	if len(conversation.Subagents) != 1 || conversation.Subagents[0].Status != "aborted" {
		t.Fatalf("subagents=%#v", conversation.Subagents)
	}
	if len(conversation.TaskPlans) != 1 || conversation.TaskPlans[0].State != "interrupted" || conversation.TaskPlans[0].Phases[0].Tasks[0].Status != "abandoned" {
		t.Fatalf("task plans=%#v", conversation.TaskPlans)
	}
	if again, err := s.Conversations.Interrupt(card.ID); err != nil || again {
		t.Fatalf("second interrupt=%v err=%v", again, err)
	}
	if orphans, err := s.Conversations.OrphanedTurnCards(); err != nil || len(orphans) != 0 {
		t.Fatalf("remaining orphans=%#v err=%v", orphans, err)
	}
}

func TestOrphanedTurnCardsDoesNotRecordAChange(t *testing.T) {
	t.Parallel()
	s := store.New(t.TempDir())
	if err := s.Ensure(); err != nil {
		t.Fatal(err)
	}
	beforeChanges, beforeMetadata := testkit.ChangeCounters(t, s)
	if orphans, err := s.Conversations.OrphanedTurnCards(); err != nil || len(orphans) != 0 {
		t.Fatalf("orphans=%#v err=%v", orphans, err)
	}
	if changes, metadata := testkit.ChangeCounters(t, s); changes != beforeChanges || metadata != beforeMetadata {
		t.Fatalf("read-only orphan inspection recorded a change: %d/%d -> %d/%d", beforeChanges, beforeMetadata, changes, metadata)
	}
}

func TestInterruptConversationPreservesFailedRuntime(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, ID: "card_failed_orphan", Title: "Failed orphan", Prompt: "Work"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Conversations.StartTurn(card.ID, "turn_failed", "user_failed", "Start working"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Conversations.AppendUIChunk(card.ID, "turn_failed", json.RawMessage(`{"type":"error","errorText":"disk write failed"}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Kanban.UpdateCardCache(card.ID, kanban.CardCacheInput{Runtime: "running"}); err != nil {
		t.Fatal(err)
	}
	if reconciled, err := s.Conversations.Interrupt(card.ID); err != nil || !reconciled {
		t.Fatalf("reconciled=%v err=%v", reconciled, err)
	}
	stored, err := s.Kanban.ResolveCard(card.ID)
	if err != nil || stored.Runtime != "failed" {
		t.Fatalf("card=%#v err=%v", stored, err)
	}
}

func TestConversationEventsProjectToDurableMessages(t *testing.T) {
	t.Parallel()
	s, p, b := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, Title: "Stream"})
	if err != nil {
		t.Fatal(err)
	}
	initialRevision, err := s.Conversations.Revision(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Conversations.StartTurn(card.ID, "turn_1", "user_1", "hello"); err != nil {
		t.Fatal(err)
	}
	startedRevision, err := s.Conversations.Revision(card.ID)
	if err != nil || startedRevision == initialRevision {
		t.Fatalf("conversation revision did not advance: before=%q after=%q err=%v", initialRevision, startedRevision, err)
	}
	chunks := []string{
		`{"type":"start","messageId":"assistant_1","messageMetadata":{"createdAt":"2026-08-11T12:00:01Z"}}`,
		`{"type":"text-start","id":"text_1"}`,
		`{"type":"text-delta","id":"text_1","delta":"First sentence."}`,
		`{"type":"text-end","id":"text_1"}`,
		`{"type":"tool-input-available","toolCallId":"tool_1","toolName":"bash","input":{"command":"true"}}`,
		`{"type":"tool-output-available","toolCallId":"tool_1","output":{"exitCode":0}}`,
		`{"type":"text-start","id":"text_2"}`,
		`{"type":"text-delta","id":"text_2","delta":"Second sentence."}`,
		`{"type":"text-end","id":"text_2"}`,
		`{"type":"finish","finishReason":"stop"}`,
	}
	for _, chunk := range chunks {
		if _, _, err := s.Conversations.AppendUIChunk(card.ID, "turn_1", []byte(chunk)); err != nil {
			t.Fatal(err)
		}
	}
	capability := `{"id":"subagents","operation":"upsert","subagent":{"id":"worker_1","provider":"omp","messageId":"assistant_1","parentToolCallId":"tool_1","name":"Scout","status":"running","activity":"Reading tests","tokens":1200}}`
	if _, _, err := s.Conversations.AppendCapability(card.ID, "turn_1", []byte(capability)); err != nil {
		t.Fatal(err)
	}
	secondCapability := `{"id":"subagents","operation":"upsert","subagent":{"id":"worker_1","provider":"omp","messageId":"assistant_2","name":"Another scout","status":"completed"}}`
	if _, _, err := s.Conversations.AppendCapability(card.ID, "turn_1", []byte(secondCapability)); err != nil {
		t.Fatal(err)
	}
	taskPlan := `{"id":"task-plan","operation":"replace","plan":{"id":"omp:assistant_1","provider":"omp","messageId":"assistant_1","revision":1,"state":"active","phases":[{"name":"Delivery","tasks":[{"content":"Inspect","status":"completed"},{"content":"Implement","activeForm":"Implementing","status":"in_progress","order":1}]}]}}`
	if _, _, err := s.Conversations.AppendCapability(card.ID, "turn_1", []byte(taskPlan)); err != nil {
		t.Fatal(err)
	}
	newerTaskPlan := `{"id":"task-plan","operation":"replace","plan":{"id":"omp:assistant_1","provider":"omp","messageId":"assistant_1","revision":2,"state":"completed","phases":[{"name":"Delivery","tasks":[{"content":"Inspect","status":"completed"},{"content":"Implement","status":"completed","order":1}]}]}}`
	if _, _, err := s.Conversations.AppendCapability(card.ID, "turn_1", []byte(newerTaskPlan)); err != nil {
		t.Fatal(err)
	}
	conversation, err := s.Conversations.Get(card.ID)
	if err != nil || conversation.Status != "idle" || len(conversation.Messages) != 2 {
		t.Fatalf("conversation=%#v err=%v", conversation, err)
	}
	assistant := conversation.Messages[1]
	var metadata map[string]string
	_ = json.Unmarshal(assistant.Metadata, &metadata)
	if metadata["createdAt"] != "2026-08-11T12:00:01Z" || len(assistant.Parts) != 3 || assistant.Parts[0].Text != "First sentence." || assistant.Parts[2].Text != "Second sentence." {
		t.Fatalf("message part boundaries or metadata lost: %#v", assistant)
	}
	if assistant.Parts[1].ToolName != "bash" || assistant.Parts[1].State != "output-available" || len(assistant.Parts[1].Input) == 0 || len(assistant.Parts[1].Output) == 0 {
		t.Fatalf("tool transition lost fields: %#v", assistant.Parts[1])
	}
	if len(conversation.Subagents) != 2 || conversation.Subagents[0].Name != "Scout" || conversation.Subagents[0].Activity != "Reading tests" || conversation.Subagents[0].Tokens != 1200 || conversation.Subagents[1].MessageID != "assistant_2" {
		t.Fatalf("subagent capability was not projected: %#v", conversation.Subagents)
	}
	if len(conversation.TaskPlans) != 1 || conversation.TaskPlans[0].Revision != 2 || conversation.TaskPlans[0].State != "completed" || conversation.TaskPlans[0].Phases[0].Tasks[1].Status != "completed" {
		t.Fatalf("task plan capability was not replaced: %#v", conversation.TaskPlans)
	}
	encoded, _ := json.Marshal(conversation.Messages[0])
	if bytes.Contains(encoded, []byte(`"createdAt":`)) && !bytes.Contains(encoded, []byte(`"metadata":{"createdAt":`)) {
		t.Fatalf("timestamp escaped AI SDK metadata: %s", encoded)
	}

	// An older reducer discarded tool names on output. The event log is the
	// source of truth, so an outdated snapshot must be rebuilt rather than
	// patched heuristically.
	conversation.ProjectionVersion = 0
	conversation.Messages[1].Parts[1].ToolName = ""
	conversation.Messages[1].Parts[1].State = "tool-output-available"
	legacySnapshot, _ := json.Marshal(conversation)
	var legacyObject map[string]any
	_ = json.Unmarshal(legacySnapshot, &legacyObject)
	delete(legacyObject, "projectionVersion")
	legacySnapshot, _ = json.Marshal(legacyObject)
	if err := fsx.WriteFile(filepath.Join(s.Conversations.Path(card.ID), "snapshot.json"), legacySnapshot, 0o600); err != nil {
		t.Fatal(err)
	}
	rebuilt, err := s.Conversations.Get(card.ID)
	if err != nil || rebuilt.ProjectionVersion != conversations.ProjectionVersion || rebuilt.Messages[1].Parts[1].ToolName != "bash" || rebuilt.Messages[1].Parts[1].State != "output-available" {
		t.Fatalf("outdated projection was not rebuilt from events: %#v err=%v", rebuilt, err)
	}
}

func TestConversationCoalescesAdjacentACPContentBlocks(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Title: "OMP fragments"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Conversations.StartTurn(card.ID, "turn_1", "user_1", "inspect"); err != nil {
		t.Fatal(err)
	}
	chunks := []string{
		`{"type":"start","messageId":"assistant_1"}`,
		`{"type":"reasoning-start","id":"reasoning_before"}`,
		`{"type":"reasoning-delta","id":"reasoning_before","delta":"Before tool."}`,
		`{"type":"reasoning-end","id":"reasoning_before"}`,
		`{"type":"tool-input-available","toolCallId":"tool_1","toolName":"task","input":{}}`,
		`{"type":"tool-output-available","toolCallId":"tool_1","output":{}}`,
		`{"type":"reasoning-start","id":"reasoning_after_1"}`,
		`{"type":"reasoning-delta","id":"reasoning_after_1","delta":"After"}`,
		`{"type":"reasoning-end","id":"reasoning_after_1"}`,
		`{"type":"reasoning-start","id":"reasoning_after_2"}`,
		`{"type":"reasoning-delta","id":"reasoning_after_2","delta":" tool."}`,
		`{"type":"reasoning-end","id":"reasoning_after_2"}`,
		`{"type":"text-start","id":"text_1"}`,
		`{"type":"text-delta","id":"text_1","delta":"All"}`,
		`{"type":"text-end","id":"text_1"}`,
		`{"type":"text-start","id":"text_2"}`,
		`{"type":"text-delta","id":"text_2","delta":" done."}`,
		`{"type":"text-end","id":"text_2"}`,
	}
	for _, chunk := range chunks {
		if _, _, err := s.Conversations.AppendUIChunk(card.ID, "turn_1", []byte(chunk)); err != nil {
			t.Fatal(err)
		}
	}
	conversation, err := s.Conversations.Get(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	parts := conversation.Messages[1].Parts
	if len(parts) != 4 || parts[0].Text != "Before tool." || parts[1].ToolCallID != "tool_1" || parts[2].Text != "After tool." || parts[3].Text != "All done." {
		t.Fatalf("adjacent ACP content blocks were not coalesced around the tool boundary: %#v", parts)
	}

	// Existing snapshots can contain the same ACP fragmentation. Loading them
	// must normalize the disposable projection without altering the event log.
	conversation.Messages[1].Parts = append(conversation.Messages[1].Parts,
		model.UIMessagePart{Type: "reasoning", Text: "Existing", State: "done"},
		model.UIMessagePart{Type: "reasoning", Text: " snapshot", State: "done"},
	)
	raw, _ := json.Marshal(conversation)
	if err := fsx.WriteFile(filepath.Join(s.Conversations.Path(card.ID), "snapshot.json"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	normalized, err := s.Conversations.Get(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	normalizedParts := normalized.Messages[1].Parts
	if len(normalizedParts) != 5 || normalizedParts[4].Text != "Existing snapshot" {
		t.Fatalf("existing fragmented snapshot was not normalized: %#v", normalizedParts)
	}
}

func TestForkChatCopiesPrefixWithoutSharingSession(t *testing.T) {
	t.Parallel()
	s, project, _ := testkit.BoardStore(t, model.WorkflowReview)
	source, err := s.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "Source", Provider: "codex", Model: "gpt-5.6-sol", Effort: "high"})
	if err != nil {
		t.Fatal(err)
	}
	messages := []model.UIMessage{
		{ID: "user-1", Role: "user", Parts: []model.UIMessagePart{{Type: "text", Text: "First question"}}},
		{ID: "assistant-1", Role: "assistant", Parts: []model.UIMessagePart{{Type: "text", Text: "First answer"}}},
		{ID: "user-2", Role: "user", Parts: []model.UIMessagePart{{Type: "text", Text: "Later question"}}},
	}
	if _, err := s.Conversations.InitializeFork(source.ID, messages); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Conversations.SetSession(source.ID, "", json.RawMessage(`{"type":"resume-session","data":{"threadId":"source"}}`)); err != nil {
		t.Fatal(err)
	}
	fork, err := s.Conversations.ForkChat(source.ID, "assistant-1", "Alternative")
	if err != nil {
		t.Fatal(err)
	}
	if fork.Scope != model.ConversationScopeChat || fork.Title != "Alternative" || fork.ID == source.ID {
		t.Fatalf("fork = %#v", fork)
	}
	conversation, err := s.Conversations.Get(fork.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(conversation.Messages) != 2 || len(conversation.ForkSeed) != 2 {
		t.Fatalf("messages=%d seed=%d", len(conversation.Messages), len(conversation.ForkSeed))
	}
	if len(conversation.Session) != 0 {
		t.Fatalf("fork shared session: %s", conversation.Session)
	}
	if fork.InitialPromptSentAt == "" || fork.Provider != source.Provider || fork.Model != source.Model || fork.Effort != source.Effort {
		t.Fatalf("fork settings = %#v", fork)
	}
}

func TestRemoveQueuedConversationMessagePreservesContentAndReplay(t *testing.T) {
	t.Parallel()
	s, project, board := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{
		Project: project.ID, Board: board.ID, ID: "card_queue_edit", Title: "Queue editing",
	})
	if err != nil {
		t.Fatal(err)
	}
	parts := []model.UIMessagePart{
		{Type: "text", Text: "Revise this follow-up"},
		{Type: "file", Filename: "context.txt", MediaType: "text/plain", URL: "data:text/plain;base64,Y29udGV4dA=="},
	}
	queued, _, err := s.Conversations.QueueMessagePartsWithID(card.ID, "message_queue_edit", parts)
	if err != nil {
		t.Fatal(err)
	}
	removed, conversation, err := s.Conversations.RemoveQueuedMessage(card.ID, queued.ID)
	if err != nil {
		t.Fatal(err)
	}
	if removed.ID != queued.ID || removed.Text != "Revise this follow-up" || len(removed.Parts) != 2 || len(conversation.Queue) != 0 {
		t.Fatalf("removed=%#v conversation=%#v", removed, conversation)
	}
	replayed, err := store.New(s.Root).Conversations.Get(card.ID)
	if err != nil || len(replayed.Queue) != 0 {
		t.Fatalf("replayed queue=%#v err=%v", replayed.Queue, err)
	}
	if _, err := s.Conversations.StartQueuedTurnParts(card.ID, "turn_removed", "message_removed", queued.ID, parts); !errors.Is(err, home.ErrNotFound) {
		t.Fatalf("starting removed queued message error=%v", err)
	}
	if _, _, err := s.Conversations.RemoveQueuedMessage(card.ID, queued.ID); !errors.Is(err, home.ErrNotFound) {
		t.Fatalf("removing queued message twice error=%v", err)
	}
}
