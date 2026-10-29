package conversations_test

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func mergeFixture(t *testing.T) (*store.Store, model.Card, model.Card) {
	t.Helper()
	s := store.New(t.TempDir())
	p, err := s.Kanban.CreateProject(kanban.CreateProjectInput{Path: testkit.ProjectDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.Kanban.CreateBoard(kanban.CreateBoardInput{Project: p.ID, Name: "Merge", Workflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	a, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, Title: "Source", Prompt: "Implement the new feature"})
	if err != nil {
		t.Fatal(err)
	}
	target, err := s.Kanban.CreateCard(kanban.CreateCardInput{Project: p.ID, Board: b.ID, Title: "Target", Prompt: "Original target request"})
	if err != nil {
		t.Fatal(err)
	}
	target, err = s.Kanban.MarkPromptSent(target.ID)
	if err != nil {
		t.Fatal(err)
	}
	return s, a, target
}

func TestMergeCardPreservesRequestAttachmentsAndReceipt(t *testing.T) {
	t.Parallel()
	s, a, b := mergeFixture(t)
	file := model.UIMessagePart{Type: "file", Filename: "screen.png", MediaType: "image/png", URL: "data:image/png;base64,YQ=="}
	if _, err := s.Conversations.SetDraftAttachments(a.ID, []model.UIMessagePart{file}); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	for range 4 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := s.Conversations.MergeCard(a.ID, b.ID); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	got, err := s.Kanban.ResolveCard(a.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Lane != "done" || got.MergedIntoCardID != b.ID || got.MergePending || got.InitialPrompt != a.InitialPrompt {
		t.Fatalf("source: %#v", got)
	}
	c, err := s.Conversations.Get(b.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Queue) != 1 || len(c.Queue[0].Parts) != 2 || c.Queue[0].Parts[1].URL != file.URL || !strings.Contains(c.Queue[0].Text, a.InitialPrompt) {
		t.Fatalf("queue: %#v", c.Queue)
	}
	if _, _, err := s.Conversations.RemoveQueuedMessage(b.ID, c.Queue[0].ID); err != nil {
		t.Fatal(err)
	}
	// Simulate the crash window after delivery but before final source write.
	got.MergePending = true
	got.MergeParts = c.Queue[0].Parts
	if err := s.Kanban.WriteCard(got); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(s.Conversations.Path(b.ID), "snapshot.json")); err != nil {
		t.Fatal(err)
	}
	if _, err := store.New(s.Root).Conversations.RecoverCardMerges(); err != nil {
		t.Fatal(err)
	}
	c, err = s.Conversations.Get(b.ID)
	if err != nil || len(c.Queue) != 0 {
		t.Fatalf("retry duplicated removed request: %#v %v", c.Queue, err)
	}
	if _, err := s.Kanban.AcquireRuntimeLeaseFor(a.ProjectID, a.BoardID, a.ID, "codex"); err == nil {
		t.Fatal("merged source acquired runtime")
	}
}

func TestMergeCardRejectsUnsafeSourceAndDraftTarget(t *testing.T) {
	t.Parallel()
	s, a, b := mergeFixture(t)
	if _, err := s.Conversations.MergeCard(a.ID, a.ID); err == nil {
		t.Fatal("self merge accepted")
	}
	if _, err := s.Conversations.MergeCard(b.ID, a.ID); err == nil {
		t.Fatal("draft target accepted")
	}
	lease, err := s.Kanban.AcquireRuntimeLeaseFor(a.ProjectID, a.BoardID, a.ID, "codex")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Conversations.MergeCard(a.ID, b.ID); err == nil {
		t.Fatal("active source accepted")
	}
	if err := s.Leases.Release(lease); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Conversations.QueueMessageParts(a.ID, []model.UIMessagePart{{Type: "text", Text: "queued"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Conversations.MergeCard(a.ID, b.ID); err == nil {
		t.Fatal("queued source accepted")
	}
	source, _ := s.Kanban.ResolveCard(a.ID)
	if source.MergedIntoCardID != "" || source.Lane == "done" {
		t.Fatal("rejected merge mutated source")
	}
}

func TestMergeRecoversAcceptedIntentBeforeDelivery(t *testing.T) {
	t.Parallel()
	s, source, target := mergeFixture(t)
	source.MergedIntoCardID, source.MergePending = target.ID, true
	source.MergeParts = []model.UIMessagePart{{Type: "text", Text: source.InitialPrompt}}
	if err := s.Kanban.WriteCard(source); err != nil {
		t.Fatal(err)
	}
	recovered := store.New(s.Root)
	if _, err := recovered.Conversations.RecoverCardMerges(); err != nil {
		t.Fatal(err)
	}
	got, err := recovered.Kanban.ResolveCard(source.ID)
	if err != nil {
		t.Fatal(err)
	}
	conversation, err := recovered.Conversations.Get(target.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.MergePending || got.Lane != "done" || len(conversation.Queue) != 1 || conversation.Queue[0].Text != source.InitialPrompt {
		t.Fatalf("recovery: %#v %#v", got, conversation.Queue)
	}
}
