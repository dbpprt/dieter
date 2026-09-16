package store

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
)

// The production daemon has more histories than the transcript cache can hold.
// Its periodic orphan scan must not cycle those histories through that cache
// while message admission waits for the same central writer lock.
func TestOrphanScanDoesNotReloadHistoriesBeyondTranscriptCacheCapacity(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowReview)
	for i := range 80 {
		card, err := s.CreateChat(CreateCardInput{Project: project.ID, Title: fmt.Sprint(i)})
		if err != nil {
			t.Fatal(err)
		}
		dir := s.conversationPath(card.ID)
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
		conversation := model.Conversation{ProjectionVersion: conversationProjectionVersion, CardID: card.ID, Status: "idle", LastSeq: 1,
			Messages: []model.UIMessage{{ID: "message", Role: "user", Parts: []model.UIMessagePart{{Type: "text", Text: strings.Repeat("history", 10000)}}}}}
		raw, _ := json.Marshal(conversation)
		if err := os.WriteFile(filepath.Join(dir, "snapshot.json"), raw, 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "events.ndjson"), []byte("{\"seq\":1,\"type\":\"status\",\"data\":\"idle\"}\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if cards, err := s.OrphanedTurnCards(); err != nil || len(cards) != 0 {
		t.Fatalf("cold scan: %d %v", len(cards), err)
	}
	s.conversations.mu.Lock()
	before := s.conversations.clock
	s.conversations.mu.Unlock()
	for range 2 {
		if cards, err := s.OrphanedTurnCards(); err != nil || len(cards) != 0 {
			t.Fatalf("warm scan: %d %v", len(cards), err)
		}
	}
	s.conversations.mu.Lock()
	after := s.conversations.clock
	s.conversations.mu.Unlock()
	if after != before {
		t.Fatalf("idle maintenance reloaded transcript projections: cache activity %d -> %d", before, after)
	}
}

func TestColdOrphanDirectoryReadDoesNotHoldWriterAdmission(t *testing.T) {
	s, project, _ := setup(t, model.WorkflowReview)
	card, err := s.CreateChat(CreateCardInput{Project: project.ID, Title: "blocked history"})
	if err != nil {
		t.Fatal(err)
	}
	dir := s.conversationPath(card.ID)
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "snapshot.json")
	if err := syscall.Mkfifo(path, 0600); err != nil {
		t.Fatal(err)
	}
	opened := make(chan error, 1)
	finishRead := make(chan struct{})
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		file, err := os.OpenFile(path, os.O_WRONLY, 0600)
		opened <- err
		if err != nil {
			return
		}
		defer file.Close()
		<-finishRead
		_, _ = file.Write([]byte(`{"projectionVersion":5,"status":"idle"}`))
	}()
	done := make(chan error, 1)
	go func() { _, err := s.OrphanedTurnCards(); done <- err }()
	select {
	case err := <-opened:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("orphan scan did not begin the cold read")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	release, admissionErr := s.beginWriteLockContext(ctx)
	if release != nil {
		release()
	}
	cancel()
	// Replace the fixture path so later status reads use a regular file, then
	// finish the already-open FIFO read. No production service is involved.
	_ = os.Remove(path)
	if err := os.WriteFile(path, []byte(`{"projectionVersion":5,"status":"idle"}`), 0600); err != nil {
		t.Error(err)
	}
	close(finishRead)
	<-writerDone
	select {
	case err := <-done:
		if err != nil {
			t.Error(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("orphan scan failed to finish")
	}
	if admissionErr != nil {
		t.Fatalf("a cold history read blocked message writer admission: %v", admissionErr)
	}
}

func TestConversationStatusSummaryCacheIsBounded(t *testing.T) {
	s := New(t.TempDir())
	for i := range maxConversationStatuses + 1 {
		s.rememberConversationStatus(fmt.Sprint(i), "idle", nil, nil)
	}
	if len(s.statuses.entries) != maxConversationStatuses {
		t.Fatalf("status entries: %d", len(s.statuses.entries))
	}
	if _, found := s.statuses.entries["0"]; found {
		t.Fatal("oldest status was not evicted")
	}
}
