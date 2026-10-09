package store

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func batchFixture(t *testing.T) (*Store, model.Card) {
	t.Helper()
	s, project, _ := setup(t, model.WorkflowReview)
	card, err := s.CreateChat(CreateCardInput{Project: project.ID, Title: "batch"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.StartConversationTurn(card.ID, "turn", "user", "hello"); err != nil {
		t.Fatal(err)
	}
	return s, card
}

func tokenBatch(n int, token string) []json.RawMessage {
	chunks := make([]json.RawMessage, n)
	for i := range chunks {
		chunks[i] = json.RawMessage(fmt.Sprintf(`{"type":"text-delta","id":"text","delta":%q}`, token))
	}
	return chunks
}

func TestUIChunkBatchDurabilitySequencesAndCheckpoints(t *testing.T) {
	s, card := batchFixture(t)
	beforeChanges, _ := changeCounters(t, s)
	metadata, err := os.ReadFile(s.syncMetadataPath())
	if err != nil {
		t.Fatal(err)
	}
	for batch := range 4 {
		events, conversation, err := s.AppendUIChunks(card.ID, "turn", tokenBatch(32, "x"))
		if err != nil || len(events) != 32 || conversation.LastSeq != int64(1+(batch+1)*32) {
			t.Fatalf("batch=%d events=%d seq=%d err=%v", batch, len(events), conversation.LastSeq, err)
		}
		for i, event := range events {
			if event.Seq != int64(2+batch*32+i) || event.TurnID != "turn" {
				t.Fatalf("unordered batch: %+v", event)
			}
		}
	}
	if changes, _ := changeCounters(t, s); changes != beforeChanges+4 {
		t.Fatalf("128 deltas must use four transactions: %d changes after %d", changes, beforeChanges)
	}
	currentMetadata, _ := os.ReadFile(s.syncMetadataPath())
	if !bytes.Equal(metadata, currentMetadata) {
		t.Fatal("text-only batches invalidated whole-store metadata")
	}
	// The last batch crossed sequence 128 and must checkpoint its complete end.
	raw, err := os.ReadFile(filepath.Join(s.conversationPath(card.ID), "snapshot.json"))
	var snapshot conversationCheckpointWire
	if err != nil || json.Unmarshal(raw, &snapshot) != nil || snapshot.LastSeq != 129 {
		t.Fatalf("missed checkpoint boundary: seq=%d err=%v", snapshot.LastSeq, err)
	}
	reader := New(s.Root)
	defer reader.Close()
	fresh, err := reader.Conversation(card.ID)
	if err != nil || fresh.LastSeq != 129 || fresh.Messages[1].Parts[0].Text != strings.Repeat("x", 128) {
		t.Fatalf("cold batch replay: %+v %v", fresh, err)
	}
	_, _, err = s.AppendUIChunks(card.ID, "turn", []json.RawMessage{json.RawMessage(`{"type":"finish","messageMetadata":{"totalUsage":{"inputTokens":3,"outputTokens":128}}}`)})
	if err != nil {
		t.Fatal(err)
	}
	updated, err := s.ResolveCard(card.ID)
	if err != nil || updated.ResponseSeq != 130 || updated.ResponseMessageID == "" {
		t.Fatalf("batch finish lost response receipt: %+v %v", updated, err)
	}
	currentMetadata, _ = os.ReadFile(s.syncMetadataPath())
	if bytes.Equal(metadata, currentMetadata) {
		t.Fatal("finish did not invalidate metadata")
	}
}

func TestUIChunkBatchRejectsInvalidInputBeforeAnyAppend(t *testing.T) {
	s, card := batchFixture(t)
	beforeChanges, beforeMetadata := changeCounters(t, s)
	for _, chunks := range [][]json.RawMessage{
		nil, tokenBatch(MaxUIChunkBatchEvents+1, "x"), tokenBatch(2, strings.Repeat("x", MaxUIChunkBatchBytes)),
		{json.RawMessage(`{"type":"text-delta","delta":"valid"}`), json.RawMessage(`{"type":`)},
	} {
		if _, _, err := s.AppendUIChunks(card.ID, "turn", chunks); err == nil {
			t.Fatal("invalid batch accepted")
		}
	}
	changes, metadata := changeCounters(t, s)
	conversation, err := s.Conversation(card.ID)
	if err != nil || changes != beforeChanges || metadata != beforeMetadata || conversation.LastSeq != 1 {
		t.Fatalf("invalid batch partially published: %d/%d seq=%d err=%v", changes, metadata, conversation.LastSeq, err)
	}
}

func TestUIChunkBatchCrossProcessAndCrashRecovery(t *testing.T) {
	if root := os.Getenv("DIETER_TEST_BATCH_ROOT"); root != "" {
		s := New(root)
		id, token := os.Getenv("DIETER_TEST_BATCH_CARD"), os.Getenv("DIETER_TEST_BATCH_TOKEN")
		if token == "crash" {
			if _, err := s.beginWriteKind("conversation_changed"); err != nil {
				os.Exit(2)
			}
			card, err := s.ResolveCard(id)
			if err != nil {
				os.Exit(3)
			}
			conversation, err := s.loadConversation(id)
			if err != nil {
				os.Exit(4)
			}
			events := make([]model.ConversationEvent, 8)
			for i, chunk := range tokenBatch(8, "c") {
				events[i] = model.ConversationEvent{Type: "ui-chunk", TurnID: "turn", Data: chunk}
			}
			if _, _, err := s.appendConversationEvents(card, conversation, events); err != nil {
				os.Exit(5)
			}
			// Exit with no defers: journal durable, sync still pending, checkpoint
			// only in memory. The kernel must release the central lock.
			os.Exit(0)
		}
		for range 4 {
			if _, _, err := s.AppendUIChunks(id, "turn", tokenBatch(16, token)); err != nil {
				t.Fatal(err)
			}
		}
		_ = s.Close()
		return
	}
	s, card := batchFixture(t)
	command := func(token string) *exec.Cmd {
		cmd := exec.CommandContext(t.Context(), os.Args[0], "-test.run=^TestUIChunkBatchCrossProcessAndCrashRecovery$")
		cmd.Env = append(os.Environ(), "DIETER_TEST_BATCH_ROOT="+s.Root, "DIETER_TEST_BATCH_CARD="+card.ID, "DIETER_TEST_BATCH_TOKEN="+token)
		return cmd
	}
	var outputs [2]bytes.Buffer
	processes := []*exec.Cmd{command("a"), command("b")}
	for i, cmd := range processes {
		cmd.Stdout, cmd.Stderr = &outputs[i], &outputs[i]
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
	}
	for i, cmd := range processes {
		if err := cmd.Wait(); err != nil {
			t.Fatalf("concurrent writer: %v %s", err, &outputs[i])
		}
	}
	if out, err := command("crash").CombinedOutput(); err != nil {
		t.Fatalf("crash fixture: %v %s", err, out)
	}
	// Also model a short batch Write: one complete record and a torn suffix.
	path := filepath.Join(s.conversationPath(card.ID), "events.ndjson")
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	_, err = file.WriteString("{\"seq\":138,\"type\":\"ui-chunk\",\"data\":{\"type\":\"text-delta\",\"delta\":\"p\"}}\n{\"seq\":139,\"data\":")
	_ = file.Close()
	if err != nil {
		t.Fatal(err)
	}
	reader := New(s.Root)
	defer reader.Close()
	if _, _, err := reader.AppendUIChunks(card.ID, "turn", tokenBatch(2, "z")); err != nil {
		t.Fatal(err)
	}
	conversation, err := reader.Conversation(card.ID)
	if err != nil || conversation.LastSeq != 140 {
		t.Fatalf("recovery sequence=%d err=%v", conversation.LastSeq, err)
	}
	text := conversation.Messages[1].Parts[0].Text
	if strings.Count(text, "a") != 64 || strings.Count(text, "b") != 64 || !strings.HasSuffix(text, "ccccccccpzz") || reader.SyncMutationPending() {
		t.Fatalf("recovery lost/reordered durable tokens: %q", text)
	}
}
