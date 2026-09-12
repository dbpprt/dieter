package app

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

func TestContentPresentationValidationAndPersistence(t *testing.T) {
	service, _, project, board := appSetup(t)
	card, err := service.Store.CreateCard(store.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Presentation", WorkspaceMode: model.WorkspaceModeProject})
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(project.Path, "report.md")
	if err := os.WriteFile(file, []byte("# Report\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	alias := filepath.Join(t.TempDir(), "workspace-alias")
	if err := os.Symlink(project.Path, alias); err != nil {
		t.Fatal(err)
	}
	first, err := service.PresentConversationContent(ctx, card.ID, "", model.ContentPresentation{ID: "untrusted", Path: filepath.Join(alias, "report.md"), Line: 2, Title: "Report"})
	if err != nil || first.ID == "" || first.ID == "untrusted" || first.Path != "report.md" {
		t.Fatalf("first=%#v err=%v", first, err)
	}
	outside := filepath.Join(t.TempDir(), "outside.md")
	if err := os.WriteFile(outside, []byte("private"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(project.Path, "escape")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(project.Path, ".git", "config"), []byte("private"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(project.Path, ".git", "config"), filepath.Join(project.Path, "git-alias")); err != nil {
		t.Fatal(err)
	}
	large, err := os.Create(filepath.Join(project.Path, "oversized.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if err := large.Truncate(5<<20 + 1); err != nil {
		t.Fatal(err)
	}
	if err := large.Close(); err != nil {
		t.Fatal(err)
	}
	for name, input := range map[string]model.ContentPresentation{
		"empty": {}, "both": {Path: "report.md", URL: "https://example.test"}, "parent": {Path: "../outside.md"}, "other checkout": {Path: outside},
		"symlink escape": {Path: "escape"}, "git": {Path: ".git/config"}, "git alias": {Path: "git-alias"}, "directory": {Path: "."}, "missing": {Path: "missing.md"},
		"oversized":            {Path: "oversized.bin"},
		"UTF-8 path bytes":     {Path: strings.Repeat("é", 2049)},
		"UTF-8 URL bytes":      {URL: "https://example.test/" + strings.Repeat("é", 4096)},
		"normalized URL bytes": {URL: "https://example.test/" + strings.Repeat("🧪", 1000)},
		"script":               {URL: "javascript:alert(1)"}, "relative URL": {URL: "/preview"}, "credentials": {URL: "https://user:pass@example.test"}, "URL line": {URL: "https://example.test", Line: 2},
		"negative line": {Path: "report.md", Line: -1}, "huge line": {Path: "report.md", Line: 10000001}, "huge title": {Path: "report.md", Title: strings.Repeat("a", 257)}, "control": {Path: "report.md", Title: "bad\nheader"},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := service.PresentConversationContent(ctx, card.ID, "", input); err == nil {
				t.Fatal("invalid request accepted")
			}
		})
	}
	if _, err := service.PresentConversationContent(ctx, "missing-card", "", model.ContentPresentation{URL: "https://example.test"}); err == nil {
		t.Fatal("unknown conversation accepted")
	}
	conversation, err := store.New(service.Store.Root).Conversation(card.ID)
	if err != nil || conversation.PresentedContent == nil || *conversation.PresentedContent != first || conversation.LastSeq != 1 || len(conversation.Messages) != 0 || conversation.Status != "idle" {
		t.Fatalf("stored=%#v err=%v", conversation, err)
	}
	second, err := service.PresentConversationContent(ctx, card.ID, "", model.ContentPresentation{URL: "https://example.test/result"})
	if err != nil || second.ID == first.ID {
		t.Fatalf("second=%#v err=%v", second, err)
	}
	conversation, _ = service.Store.Conversation(card.ID)
	if conversation.PresentedContent.URL != second.URL || conversation.LastSeq != 2 {
		t.Fatalf("latest=%#v", conversation)
	}
}

type presentationRunner struct{ otherCardID string }

func (r presentationRunner) Run(_ context.Context, request harness.Request, emit func(harness.Output) error) error {
	if !request.ContentPresentationEnabled {
		return context.Canceled
	}
	// Deliberately include another ID: the Go host must bind the owning turn.
	data, _ := json.Marshal(map[string]any{"path": "report.md", "cardId": r.otherCardID})
	if err := emit(harness.Output{Type: "present-content", Presentation: data}); err != nil {
		return err
	}
	for _, chunk := range []string{`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`, `{"type":"text-start","id":"text"}`, `{"type":"text-delta","id":"text","delta":"Done"}`, `{"type":"text-end","id":"text"}`, `{"type":"finish","finishReason":"stop"}`} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return nil
}

func TestHarnessPresentationBindsOwningConversation(t *testing.T) {
	service, _, project, board := appSetup(t)
	if err := os.WriteFile(filepath.Join(project.Path, "report.md"), []byte("# Report"), 0o600); err != nil {
		t.Fatal(err)
	}
	other, err := service.Store.CreateCard(store.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Other"})
	if err != nil {
		t.Fatal(err)
	}
	service.Runner = presentationRunner{otherCardID: other.ID}
	card, err := service.CreateCard(context.Background(), CardInput{Project: project.ID, Board: board.ID, Lane: model.LaneRunning, Title: "Present", Prompt: "Show report", Provider: "codex"})
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool {
		value, err := service.Store.ResolveCard(card.ID)
		return err == nil && value.Runtime == "idle" && !hasActiveTurn(service, project.ID)
	})
	current, _ := service.Store.Conversation(card.ID)
	untouched, _ := service.Store.Conversation(other.ID)
	if current.PresentedContent == nil || current.PresentedContent.Path != "report.md" || untouched.PresentedContent != nil {
		t.Fatalf("owner=%#v other=%#v", current, untouched)
	}
}
