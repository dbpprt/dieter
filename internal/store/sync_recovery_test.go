package store

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
)

func TestGlobalStateNeverCachesPreparedDomainMutation(t *testing.T) {
	s, p, b := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, Title: "before"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.GlobalState(); err != nil {
		t.Fatal(err)
	}
	release, err := s.beginWrite()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	_, _, err = s.GlobalStateContext(ctx)
	if !errors.Is(err, context.DeadlineExceeded) {
		release()
		t.Fatalf("active writer read: %v", err)
	}
	card.Title = "after"
	err = s.writeCard(card)
	release()
	if err != nil {
		t.Fatal(err)
	}
	state, err := s.GlobalState()
	if err != nil || state.Cards[0].Title != "after" {
		t.Fatalf("stale state: %+v %v", state, err)
	}
}

func TestQueuedWriterAdmissionCancelsWithoutTakingOrLeakingTheLock(t *testing.T) {
	var gate contextMutex
	if err := gate.LockContext(context.Background()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() { result <- gate.LockContext(ctx) }()
	cancel()
	select {
	case err := <-result:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("canceled admission: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled waiter blocked behind active writer")
	}
	if gate.TryLock() {
		t.Fatal("canceled waiter released another writer's lock")
	}
	gate.Unlock()
	if !gate.TryLock() {
		t.Fatal("canceled waiter leaked admission")
	}
	gate.Unlock()
}

func TestPendingMutationRecoveredByReader(t *testing.T) {
	s, p, b := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, Title: "before"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.GlobalState(); err != nil {
		t.Fatal(err)
	}
	release, err := s.beginWriteLock()
	if err != nil {
		t.Fatal(err)
	}
	event, err := s.prepareSyncMutation("conversation_changed")
	if err != nil {
		release()
		t.Fatal(err)
	}
	card.Title = "partial crash write"
	err = s.writeCard(card)
	release()
	if err != nil {
		t.Fatal(err)
	}
	state, cursor, err := s.GlobalStateContext(context.Background())
	if err != nil || state.Cards[0].Title != card.Title || cursor.Sequence != event.Sequence {
		t.Fatalf("recovery: %+v %+v %v", state, cursor, err)
	}
	if s.SyncMutationPending() {
		t.Fatal("pending marker survived successful recovery")
	}
}

func TestWriterLockDoesNotExpireWhileOwnerAlive(t *testing.T) {
	s := New(t.TempDir())
	if err := s.Ensure(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(s.Root, ".write-lock")
	if err := os.Mkdir(path, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "owner"), []byte(strconv.Itoa(os.Getpid())), 0600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Hour)
	_ = os.Chtimes(path, old, old)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if release, err := s.beginWriteLockContext(ctx); !errors.Is(err, context.DeadlineExceeded) {
		if release != nil {
			release()
		}
		t.Fatalf("live writer stolen: %v", err)
	}
}

func TestConversationCacheReplaysOnlyAppendedTailAndInvalidatesAcrossStores(t *testing.T) {
	s, p, b := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, Title: "cache"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.StartConversationTurn(card.ID, "turn", "user", "hello"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"text-delta","delta":"one"}`)); err != nil {
		t.Fatal(err)
	}
	first, err := s.Conversation(card.ID)
	if err != nil {
		t.Fatal(err)
	}
	first.Messages[1].Parts[0].Text = "caller mutation"
	other := New(s.Root)
	if _, _, err := other.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"text-delta","delta":"two"}`)); err != nil {
		t.Fatal(err)
	}
	got, err := s.Conversation(card.ID)
	if err != nil || got.Messages[1].Parts[0].Text != "onetwo" {
		t.Fatalf("cache/replay alias: %+v %v", got, err)
	}
	// An inode replacement must invalidate even at the same length.
	eventPath := filepath.Join(s.conversationPath(card.ID), "events.ndjson")
	raw, _ := os.ReadFile(eventPath)
	raw = []byte(strings.Replace(string(raw), `"delta":"two"`, `"delta":"six"`, 1))
	if err := atomicWrite(eventPath, raw); err != nil {
		t.Fatal(err)
	}
	got, err = s.Conversation(card.ID)
	if err != nil || got.Messages[1].Parts[0].Text != "onesix" {
		t.Fatalf("replacement: %+v %v", got, err)
	}
}

func TestTextDeltaDoesNotRewriteCheckpoint(t *testing.T) {
	s, p, b := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, Title: "checkpoint"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.StartConversationTurn(card.ID, "turn", "user", strings.Repeat("history", 100000)); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(s.conversationPath(card.ID), "snapshot.json")
	before, _ := os.Stat(path)
	for range 10 {
		if _, _, err := s.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"text-delta","delta":"x"}`)); err != nil {
			t.Fatal(err)
		}
	}
	after, _ := os.Stat(path)
	if !sameFileRevision(before, after) {
		t.Fatal("text chunks rewrote the full snapshot")
	}
	fresh, err := New(s.Root).Conversation(card.ID)
	if err != nil || fresh.Messages[1].Parts[0].Text != "xxxxxxxxxx" {
		t.Fatalf("journal recovery failed: %+v %v", fresh, err)
	}
}

func TestTornConversationJournalDoesNotSwallowNextAcknowledgedEvent(t *testing.T) {
	s, p, b := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, Title: "torn"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.StartConversationTurn(card.ID, "turn", "user", "hello"); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(s.conversationPath(card.ID), "events.ndjson")
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	_, err = file.WriteString(`{"seq":2,"type":"ui-chunk","data":`)
	_ = file.Close()
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"text-delta","delta":"survived"}`)); err != nil {
		t.Fatal(err)
	}
	fresh, err := New(s.Root).Conversation(card.ID)
	if err != nil || fresh.LastSeq != 2 || fresh.Messages[1].Parts[0].Text != "survived" {
		t.Fatalf("torn suffix lost acknowledged event: %+v %v", fresh, err)
	}
}

func TestRuntimeStatusReplaysEventsNewerThanDelayedCheckpoint(t *testing.T) {
	s, p, b := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, Title: "delayed checkpoint"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.StartConversationTurn(card.ID, "turn", "user", "hello"); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(s.conversationPath(card.ID), "snapshot.json")
	older, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"finish"}`)); err != nil {
		t.Fatal(err)
	}
	// Model a checkpoint captured before finish whose rename completes later.
	if err := atomicWrite(path, older); err != nil {
		t.Fatal(err)
	}
	status, err := New(s.Root).conversationStatus(card.ID)
	if err != nil || status != "idle" {
		t.Fatalf("status=%q, error=%v; checkpoint time hid durable finish", status, err)
	}
}

func TestCompleteJSONWithoutJournalTerminatorIsNotCommitted(t *testing.T) {
	s, p, b := setup(t, model.WorkflowReview)
	card, err := s.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, Title: "unterminated record"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.StartConversationTurn(card.ID, "turn", "user", "hello"); err != nil {
		t.Fatal(err)
	}
	file, err := os.OpenFile(filepath.Join(s.conversationPath(card.ID), "events.ndjson"), os.O_APPEND|os.O_WRONLY, 0600)
	if err != nil {
		t.Fatal(err)
	}
	_, err = file.WriteString(`{"seq":2,"type":"ui-chunk","turnId":"turn","data":{"type":"text-delta","delta":"uncommitted"}}`)
	_ = file.Close()
	if err != nil {
		t.Fatal(err)
	}
	before, err := New(s.Root).Conversation(card.ID)
	if err != nil || before.LastSeq != 1 {
		t.Fatalf("unterminated event was replayed: seq=%d err=%v", before.LastSeq, err)
	}
	if _, _, err := s.AppendUIChunk(card.ID, "turn", json.RawMessage(`{"type":"text-delta","delta":"survived"}`)); err != nil {
		t.Fatal(err)
	}
	fresh, err := New(s.Root).Conversation(card.ID)
	if err != nil || fresh.LastSeq != 2 || fresh.Messages[1].Parts[0].Text != "survived" {
		t.Fatalf("repaired journal and projection diverged: %+v %v", fresh, err)
	}
}

func TestKilledWriterRecovery(t *testing.T) {
	if root := os.Getenv("DIETER_TEST_CRASH_STORE"); root != "" {
		data := New(root)
		_, err := data.beginWrite()
		if err != nil {
			os.Exit(2)
		}
		card, err := data.ResolveCard(os.Getenv("DIETER_TEST_CRASH_CARD"))
		if err != nil {
			os.Exit(3)
		}
		card.Title = "committed before process death"
		if err := data.writeCard(card); err != nil {
			os.Exit(4)
		}
		// Simulate death after the atomic domain write and before sync publication.
		// No defers run; the kernel releases admission but the owner directory stays.
		os.Exit(0)
	}
	data, p, b := setup(t, model.WorkflowReview)
	card, err := data.CreateCard(CreateCardInput{Project: p.ID, Board: b.ID, Title: "before"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := data.GlobalState(); err != nil {
		t.Fatal(err)
	}
	command := exec.Command(os.Args[0], "-test.run=^TestKilledWriterRecovery$")
	command.Env = append(os.Environ(), "DIETER_TEST_CRASH_STORE="+data.Root, "DIETER_TEST_CRASH_CARD="+card.ID)
	if raw, err := command.CombinedOutput(); err != nil {
		t.Fatalf("crash fixture: %v %s", err, raw)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	state, _, err := data.GlobalStateContext(ctx)
	if err != nil || state.Cards[0].Title != "committed before process death" {
		t.Fatalf("killed writer lost update: %+v %v", state, err)
	}
	if data.SyncMutationPending() {
		t.Fatal("recovery left pending revision")
	}
}

func TestSyncJournalCacheTracksAppendAndReplacement(t *testing.T) {
	data := New(t.TempDir())
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	for range 3 {
		release, err := data.beginWrite()
		if err != nil {
			t.Fatal(err)
		}
		release()
	}
	first, events, err := data.SyncEvents(1, 1)
	if err != nil || len(events) != 1 || events[0].Sequence != 2 {
		t.Fatalf("first: %+v %v", events, err)
	}
	offset := data.syncJournal.offset
	release, err := data.beginWrite()
	if err != nil {
		t.Fatal(err)
	}
	release()
	next, events, err := data.SyncEvents(first.Sequence, 10)
	if err != nil || len(events) != 1 || events[0].Sequence != 4 || data.syncJournal.offset <= offset {
		t.Fatalf("append: %+v %v", events, err)
	}
	if err := data.compactSyncJournal(2); err != nil {
		t.Fatal(err)
	}
	replaced, events, err := data.SyncEvents(0, 10)
	if err != nil || replaced.Epoch == next.Epoch || len(events) != 2 || events[0].Sequence != 3 {
		t.Fatalf("replacement: %+v %+v %v", replaced, events, err)
	}
}
