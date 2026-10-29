package conversations_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fsx"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/conversations"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestConversationCacheReplaysOnlyAppendedTailAndInvalidatesAcrossStores(t *testing.T) {
	t.Parallel()
	s, p, b := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, Title: "cache"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Conversations.StartTurn(card.ID, "turn", "user", "hello"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Conversations.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"text-delta","delta":"one"}`)); err != nil {
		t.Fatal(err)
	}
	first, err := s.Conversations.Get(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	first.Messages[1].Parts[0].Text = "caller mutation"
	other := store.New(s.Root)
	if _, _, err := other.Conversations.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"text-delta","delta":"two"}`)); err != nil {
		t.Fatal(err)
	}
	got, err := s.Conversations.Get(card.ID)
	if err != nil || got.Messages[1].Parts[0].Text != "onetwo" {
		t.Fatalf("cache/replay alias: %+v %v", got, err)
	}
	// An inode replacement must invalidate even at the same length.
	eventPath := filepath.Join(s.Conversations.Path(card.ID), "events.ndjson")
	raw, _ := os.ReadFile(eventPath)
	raw = []byte(strings.Replace(string(raw), `"delta":"two"`, `"delta":"six"`, 1))
	if err := fsx.WriteFile(eventPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	got, err = s.Conversations.Get(card.ID)
	if err != nil || got.Messages[1].Parts[0].Text != "onesix" {
		t.Fatalf("replacement: %+v %v", got, err)
	}
}

func TestTextDeltaDoesNotRewriteCheckpoint(t *testing.T) {
	t.Parallel()
	s, p, b := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, Title: "checkpoint"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Conversations.StartTurn(card.ID, "turn", "user", strings.Repeat("history", 100000)); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(s.Conversations.Path(card.ID), "snapshot.json")
	before, _ := os.Stat(path)
	for range 10 {
		if _, _, err := s.Conversations.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"text-delta","delta":"x"}`)); err != nil {
			t.Fatal(err)
		}
	}
	after, _ := os.Stat(path)
	if !conversations.SameFileRevision(before, after) {
		t.Fatal("text chunks rewrote the full snapshot")
	}
	fresh, err := store.New(s.Root).Conversations.Get(card.ID)
	if err != nil || fresh.Messages[1].Parts[0].Text != "xxxxxxxxxx" {
		t.Fatalf("journal recovery failed: %+v %v", fresh, err)
	}
}

func TestTornConversationJournalDoesNotSwallowNextAcknowledgedEvent(t *testing.T) {
	t.Parallel()
	s, p, b := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, Title: "torn"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Conversations.StartTurn(card.ID, "turn", "user", "hello"); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(s.Conversations.Path(card.ID), "events.ndjson")
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	_, err = file.WriteString(`{"seq":2,"type":"ui-chunk","data":`)
	_ = file.Close()
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Conversations.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"text-delta","delta":"survived"}`)); err != nil {
		t.Fatal(err)
	}
	fresh, err := store.New(s.Root).Conversations.Get(card.ID)
	if err != nil || fresh.LastSeq != 2 || fresh.Messages[1].Parts[0].Text != "survived" {
		t.Fatalf("torn suffix lost acknowledged event: %+v %v", fresh, err)
	}
}

func TestRuntimeStatusReplaysEventsNewerThanDelayedCheckpoint(t *testing.T) {
	t.Parallel()
	s, p, b := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, Title: "delayed checkpoint"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Conversations.StartTurn(card.ID, "turn", "user", "hello"); err != nil {
		t.Fatal(err)
	}
	reader := store.New(s.Root)
	if status, err := reader.Conversations.Status(card.ID); err != nil || status != "running" {
		t.Fatalf("initial status=%q, error=%v", status, err)
	}
	path := filepath.Join(s.Conversations.Path(card.ID), "snapshot.json")
	older, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Conversations.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"finish"}`)); err != nil {
		t.Fatal(err)
	}
	// Model a checkpoint captured before finish whose rename completes later.
	if err := fsx.WriteFile(path, older, 0o600); err != nil {
		t.Fatal(err)
	}
	for name, view := range map[string]*store.Store{"cached reader": reader, "cold reader": store.New(s.Root)} {
		status, err := view.Conversations.Status(card.ID)
		if err != nil || status != "idle" {
			t.Fatalf("%s: status=%q, error=%v; checkpoint time hid durable finish", name, status, err)
		}
	}
}

func TestCompleteJSONWithoutJournalTerminatorIsNotCommitted(t *testing.T) {
	t.Parallel()
	s, p, b := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, Title: "unterminated record"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Conversations.StartTurn(card.ID, "turn", "user", "hello"); err != nil {
		t.Fatal(err)
	}
	file, err := os.OpenFile(filepath.Join(s.Conversations.Path(card.ID), "events.ndjson"), os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	_, err = file.WriteString(`{"seq":2,"type":"ui-chunk","turnId":"turn","data":{"type":"text-delta","delta":"uncommitted"}}`)
	_ = file.Close()
	if err != nil {
		t.Fatal(err)
	}
	before, err := store.New(s.Root).Conversations.Get(card.ID)
	if err != nil || before.LastSeq != 1 {
		t.Fatalf("unterminated event was replayed: seq=%d err=%v", before.LastSeq, err)
	}
	if _, _, err := s.Conversations.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"text-delta","delta":"survived"}`)); err != nil {
		t.Fatal(err)
	}
	fresh, err := store.New(s.Root).Conversations.Get(card.ID)
	if err != nil || fresh.LastSeq != 2 || fresh.Messages[1].Parts[0].Text != "survived" {
		t.Fatalf("repaired journal and projection diverged: %+v %v", fresh, err)
	}
}
