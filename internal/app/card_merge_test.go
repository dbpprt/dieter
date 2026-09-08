package app

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
)

func TestMergeQueuesBehindRunningTargetAndDeliversInitialRequest(t *testing.T) {
	service, _, project, board := appSetup(t)
	runner := &interruptQueueRunner{started: make(chan int, 2)}
	service.Runner = runner
	target, err := service.CreateCard(context.Background(), CardInput{Project: project.ID, Board: board.ID, Title: "Target", Prompt: "Keep working", Provider: "omp", Model: "box/qwen3_6_27b", DeferStart: true})
	if err != nil {
		t.Fatal(err)
	}
	source, err := service.CreateCard(context.Background(), CardInput{Project: project.ID, Board: board.ID, Title: "Source", Prompt: "Add the missing feature", Provider: "omp", Model: "box/qwen3_6_27b", DeferStart: true})
	if err != nil {
		t.Fatal(err)
	}
	_, err = service.Store.SetConversationDraftAttachments(source.ID, []model.UIMessagePart{{Type: "file", MediaType: "image/png", Filename: "request.png", URL: "data:image/png;base64,iVBORw0KGgo="}})
	if err != nil {
		t.Fatal(err)
	}
	updates, err := service.StartCard(target.ID, "", target.Provider, target.Model, "")
	if err != nil {
		t.Fatal(err)
	}
	go drainTurnUpdates(updates)
	select {
	case <-runner.started:
	case <-time.After(5 * time.Second):
		t.Fatal("target did not start")
	}
	merged, err := service.MergeCard(source.ID, target.ID)
	if err != nil {
		t.Fatal(err)
	}
	if merged.Lane != "done" || merged.MergedIntoCardID != target.ID {
		t.Fatalf("source: %#v", merged)
	}
	if len(runner.prompts()) != 1 {
		t.Fatal("merge interrupted/replaced active turn")
	}
	if err := service.CancelCard(target.ID); err != nil {
		t.Fatal(err)
	}
	select {
	case turn := <-runner.started:
		if turn != 2 {
			t.Fatalf("turn=%d", turn)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("merge request did not start")
	}
	service.mu.Lock()
	active := service.active[target.ID]
	service.mu.Unlock()
	if active != nil {
		select {
		case <-active.done:
		case <-time.After(10 * time.Second):
			t.Fatal("merged turn did not settle")
		}
	}
	prompts := runner.prompts()
	if len(prompts) != 2 || !strings.Contains(prompts[1], source.InitialPrompt) {
		t.Fatalf("requests: %#v", prompts)
	}
	runner.mu.Lock()
	defer runner.mu.Unlock()
	if len(runner.requests[1].Attachments) != 1 || runner.requests[1].Attachments[0].Filename != "request.png" {
		t.Fatal("merge attachment missing")
	}
}
