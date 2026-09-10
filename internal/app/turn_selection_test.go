package app

import (
	"context"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

func TestSameProviderTurnSelectionPreservesCardAndChatSessions(t *testing.T) {
	for _, scope := range []string{"card", "chat"} {
		for _, provider := range []struct{ id, first, second, effort string }{
			{"codex", "gpt-5.5", "gpt-5.6-sol", "medium"},
			{"claude-code", "sonnet", "opus", "high"},
			{"pi", "default", "box/qwen3_6_27b", "high"},
		} {
			t.Run(scope+"/"+provider.id, func(t *testing.T) {
				service, runner, project, board := appSetup(t)
				input := CardInput{Project: project.ID, Board: board.ID, Title: "Selections", Prompt: "First", Provider: provider.id, Model: provider.first, Effort: "low", DeferStart: true}
				var card model.Card
				var err error
				if scope == "chat" {
					card, err = service.CreateChat(t.Context(), input)
				} else {
					card, err = service.CreateCard(t.Context(), input)
				}
				if err != nil {
					t.Fatal(err)
				}
				if err := service.SendCard(t.Context(), card.ID, "First", provider.id, provider.first, "low"); err != nil {
					t.Fatal(err)
				}
				before, err := service.Store.Conversation(card.ID)
				if err != nil {
					t.Fatal(err)
				}
				if err := service.SendCard(t.Context(), card.ID, "Next", provider.id, provider.second, provider.effort); err != nil {
					t.Fatal(err)
				}
				request := runner.request(1)
				if request.SessionID != card.ID || request.ConfiguredModel != provider.second || request.Effort != provider.effort || string(request.Session) != string(before.Session) {
					t.Fatalf("resumed with incorrect selection/session: %#v", request)
				}
				after, err := service.Store.Conversation(card.ID)
				if err != nil || len(after.Messages) < len(before.Messages) || !reflect.DeepEqual(after.Messages[:len(before.Messages)], before.Messages) {
					t.Fatalf("prior history changed: %#v, %v", after.Messages, err)
				}
			})
		}
	}
}

func TestTurnSelectionDefaultsAndUnsupportedChanges(t *testing.T) {
	card := model.Card{Provider: "codex", Model: "gpt-5.5", Effort: "high", InitialPromptSentAt: "sent", ProviderOptions: map[string]string{"fast_mode": "true"}}
	_, _, selection, err := resolveTurnSelection(card, "", "gpt-5.3-codex-spark", "", nil)
	if err != nil || selection.ProviderOptions["fast_mode"] != "" || selection.Effort != "high" {
		t.Fatalf("Spark selection=%#v err=%v", selection, err)
	}
	_, _, selection, err = resolveTurnSelection(card, "", "", "default", nil)
	if err != nil || selection.Effort != "" {
		t.Fatalf("default effort=%#v err=%v", selection, err)
	}
	if _, _, _, err := resolveTurnSelection(card, "", "gpt-5.3-codex-spark", "", map[string]string{"fast_mode": "true"}); err == nil {
		t.Fatal("accepted unsupported Fast mode")
	}
	if _, _, _, err := resolveTurnSelection(card, "", "", "invalid-effort", nil); err == nil {
		t.Fatal("accepted unsupported effort")
	}
	omp := model.Card{Provider: "omp", Model: "default", Effort: "high", InitialPromptSentAt: "sent"}
	if _, _, _, err := resolveTurnSelection(omp, "", "", "low", nil); err == nil || !strings.Contains(err.Error(), "effort is locked") {
		t.Fatalf("OMP effort change=%v", err)
	}
	if _, _, _, err := resolveTurnSelection(omp, "", "box/qwen3_6_27b", "", nil); err != nil {
		t.Fatalf("OMP model change=%v", err)
	}
}

type selectionQueueRunner struct {
	started chan harness.Request
	release chan struct{}
}

func (r *selectionQueueRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	r.started <- request
	select {
	case <-r.release:
	case <-ctx.Done():
		return ctx.Err()
	}
	return (&fakeRunner{}).Run(ctx, request, emit)
}

func TestQueuedMessagesKeepIndependentDurableTurnSelections(t *testing.T) {
	service, _, project, board := appSetup(t)
	runner := &selectionQueueRunner{started: make(chan harness.Request, 3), release: make(chan struct{}, 3)}
	service.Runner = runner
	card, err := service.CreateCard(t.Context(), CardInput{Project: project.ID, Board: board.ID, Title: "Queue", Prompt: "First", Provider: "codex", Model: "gpt-5.5", Effort: "low", DeferStart: true})
	if err != nil {
		t.Fatal(err)
	}
	updates, err := service.StartCard(card.ID, "First", "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	go drainTurnUpdates(updates)
	defer func() {
		for i := 0; i < 3; i++ {
			select {
			case runner.release <- struct{}{}:
			default:
			}
		}
		waitFor(t, func() bool { return !hasActiveTurn(service, project.ID) })
	}()
	first := <-runner.started
	for index, next := range []model.HarnessSelection{
		{Provider: "codex", Model: "gpt-5.6-sol", Effort: "high", ProviderOptions: map[string]string{"fast_mode": "true"}},
		{Provider: "codex", Model: "gpt-5.5", Effort: "", ProviderOptions: map[string]string{"fast_mode": "false"}},
	} {
		queued, err := service.SubmitCardPartsWithMessageID(card.ID, []model.UIMessagePart{{Type: "text", Text: "Next"}}, next.Provider, next.Model, selectionEffort(next), next.ProviderOptions, []string{"queued-one", "queued-two"}[index])
		if err != nil || !queued {
			t.Fatalf("queue %d admitted=%v err=%v", index, queued, err)
		}
	}
	durable, err := store.New(service.Store.Root).Conversation(card.ID)
	if err != nil || len(durable.Queue) != 2 || durable.Queue[0].Selection.Model != "gpt-5.6-sol" || durable.Queue[1].Selection.Effort != "" {
		t.Fatalf("durable queue=%#v err=%v", durable.Queue, err)
	}
	active, err := service.Store.ResolveCard(card.ID)
	if err != nil || active.Model != first.ConfiguredModel || active.Effort != first.Effort || active.ProviderOptions["fast_mode"] != "false" {
		t.Fatalf("queued changes altered active config=%#v err=%v", active, err)
	}
	for _, next := range durable.Queue {
		runner.release <- struct{}{}
		select {
		case request := <-runner.started:
			if request.ConfiguredModel != next.Selection.Model || request.Effort != next.Selection.Effort || !reflect.DeepEqual(request.Options, next.Selection.ProviderOptions) || request.SessionID != card.ID || len(request.Session) == 0 {
				t.Fatalf("queue selection lost: request=%#v wanted=%#v", request, next.Selection)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("queued message did not start")
		}
	}
	runner.release <- struct{}{}
	waitFor(t, func() bool { return !hasActiveTurn(service, project.ID) })
}
