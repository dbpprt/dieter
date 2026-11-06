package conversations_test

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
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/conversations"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestOrphanScanIgnoresReplicatedRemoteTurns(t *testing.T) {
	t.Parallel()
	local, remote := testkit.PeerStore(t, "local"), testkit.PeerStore(t, "remote")
	for _, replica := range []*store.Store{local, remote} {
		project, err := replica.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Orphan fixture", Path: testkit.ProjectDir(t)})
		if err != nil {
			t.Fatal(err)
		}
		card, err := replica.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "Running"})
		if err != nil {
			t.Fatal(err)
		}
		if _, err = replica.Kanban.UpdateCardCache(card.ID, kanban.CardCacheInput{Runtime: "running"}); err != nil {
			t.Fatal(err)
		}
	}
	testkit.JoinPeers(t, remote, local)
	for range 2 {
		cards, err := local.Conversations.OrphanedTurnCards()
		if err != nil || len(cards) != 1 || cards[0].OwnerDaemonID != "local" {
			t.Fatalf("orphan scan must keep local candidates and skip remote transcripts: %+v %v", cards, err)
		}
	}
}

// The production daemon has more histories than the transcript cache can hold.
// Its periodic orphan scan must not cycle those histories through that cache
// while message admission waits for the same central writer lock.
func TestOrphanScanDoesNotReloadHistoriesBeyondTranscriptCacheCapacity(t *testing.T) {
	t.Parallel()
	s, project, _ := testkit.BoardStore(t, model.WorkflowReview)
	for i := range 80 {
		card, err := s.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: fmt.Sprint(i)})
		if err != nil {
			t.Fatal(err)
		}
		dir := s.Conversations.Path(card.ID)
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
		conversation := model.Conversation{ProjectionVersion: conversations.ProjectionVersion, CardID: card.ID, Status: "idle", LastSeq: 1,
			Messages: []model.UIMessage{{ID: "message", Role: "user", Parts: []model.UIMessagePart{{Type: "text", Text: strings.Repeat("history", 10000)}}}}}
		raw, _ := json.Marshal(conversation)
		if err := os.WriteFile(filepath.Join(dir, "snapshot.json"), raw, 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "events.ndjson"), []byte("{\"seq\":1,\"type\":\"status\",\"data\":\"idle\"}\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if cards, err := s.Conversations.OrphanedTurnCards(); err != nil || len(cards) != 0 {
		t.Fatalf("cold scan: %d %v", len(cards), err)
	}
	before := s.Conversations.ProjectionCacheClock()
	for range 2 {
		if cards, err := s.Conversations.OrphanedTurnCards(); err != nil || len(cards) != 0 {
			t.Fatalf("warm scan: %d %v", len(cards), err)
		}
	}
	after := s.Conversations.ProjectionCacheClock()
	if after != before {
		t.Fatalf("idle maintenance reloaded transcript projections: cache activity %d -> %d", before, after)
	}
}

func TestColdOrphanDirectoryReadDoesNotHoldWriterAdmission(t *testing.T) {
	t.Parallel()
	s, project, _ := testkit.BoardStore(t, model.WorkflowReview)
	card, err := s.Kanban.CreateChat(kanban.CreateCardInput{Project: project.ID, Title: "blocked history"})
	if err != nil {
		t.Fatal(err)
	}
	dir := s.Conversations.Path(card.ID)
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
	go func() { _, err := s.Conversations.OrphanedTurnCards(); done <- err }()
	select {
	case err := <-opened:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("orphan scan did not begin the cold read")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	release, admissionErr := s.BeginWriteLockContext(ctx)
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
