package app

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
)

type delayedQuickTitleRunner struct {
	actual  *fakeRunner
	entered chan struct{}
	release chan struct{}
	err     error
}

func (r *delayedQuickTitleRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	if request.ConfiguredModel != quickTaskTitleModel {
		return r.actual.Run(ctx, request, emit)
	}
	r.entered <- struct{}{}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-r.release:
	}
	if r.err != nil {
		return r.err
	}
	return emit(harness.Output{Type: "chunk", Chunk: []byte(`{"type":"text-delta","delta":"Add Keyboard Board Navigation"}`)})
}

func quickTitleJobsFinished(service *Service) bool {
	service.mu.Lock()
	defer service.mu.Unlock()
	return len(service.quickTitleJobs) == 0
}

func cleanupQuickTitleService(t *testing.T, service *Service) {
	t.Helper()
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if err := service.SuspendActiveTurns(ctx); err != nil {
			t.Errorf("suspend test service: %v", err)
		}
	})
}

func TestQuickTaskCanStartWhileTitleIsPendingAndKeepsIdentity(t *testing.T) {
	service, actual, project, board := appSetup(t)
	runner := &delayedQuickTitleRunner{actual: actual, entered: make(chan struct{}, 2), release: make(chan struct{})}
	service.Runner = runner
	cleanupQuickTitleService(t, service)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	card, err := service.CreateCard(ctx, CardInput{
		ID: "c_stable_quick_task", Project: project.ID, Board: board.ID, Lane: model.LaneTodo,
		Prompt: "Add keyboard navigation to every lane", Provider: "codex", Model: "gpt-5.5",
		WorkspaceMode: model.WorkspaceModeProject, AutoGenerateTitle: true, DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	cancel() // Returning/disconnecting from CreateCard must not cancel the rename.
	select {
	case <-runner.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("background title did not start")
	}
	updates, err := service.StartCard(card.ID, "", "", "", "")
	if err != nil {
		t.Fatalf("title generation blocked starting the saved card: %v", err)
	}
	for range updates {
	}
	before, err := service.Store.ResolveCard(card.ID)
	if err != nil || before.InitialPromptSentAt == "" || before.Title != card.Title {
		t.Fatalf("started card=%#v err=%v", before, err)
	}
	close(runner.release)
	waitFor(t, func() bool { return quickTitleJobsFinished(service) })
	after, err := service.Store.ResolveCard(card.ID)
	if err != nil || after.ID != card.ID || after.Title != "Add Keyboard Board Navigation" || after.InitialPromptSentAt != before.InitialPromptSentAt || after.Lane != before.Lane || actual.count() != 1 {
		t.Fatalf("rename changed task lifecycle: before=%#v after=%#v requests=%d err=%v", before, after, actual.count(), err)
	}
}

func TestRunQuickTaskStartsBeforeSparkReturns(t *testing.T) {
	service, actual, project, board := appSetup(t)
	runner := &delayedQuickTitleRunner{actual: actual, entered: make(chan struct{}, 2), release: make(chan struct{})}
	service.Runner = runner
	cleanupQuickTitleService(t, service)
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneRunning,
		Prompt: "Start this task immediately", Provider: "codex", Model: "gpt-5.5",
		WorkspaceMode: model.WorkspaceModeProject, AutoGenerateTitle: true,
	})
	if err != nil || card.InitialPromptSentAt == "" {
		t.Fatalf("immediate create did not start: card=%#v err=%v", card, err)
	}
	waitFor(t, func() bool { return actual.count() == 1 && !hasActiveTurn(service, project.ID) })
}

func TestQuickTaskGeneratedTitleNeverOverwritesManualChanges(t *testing.T) {
	for _, change := range []string{"rename", "rename-and-restore", "edit-task"} {
		t.Run(change, func(t *testing.T) {
			service, actual, project, board := appSetup(t)
			runner := &delayedQuickTitleRunner{actual: actual, entered: make(chan struct{}, 2), release: make(chan struct{})}
			service.Runner = runner
			cleanupQuickTitleService(t, service)
			card, err := service.CreateCard(context.Background(), CardInput{
				Project: project.ID, Board: board.ID, Lane: model.LaneTodo,
				Title: "Original title", Prompt: "Add keyboard navigation", AutoGenerateTitle: true, DeferStart: true,
			})
			if err != nil {
				t.Fatal(err)
			}
			expected := "Manual title"
			switch change {
			case "rename", "rename-and-restore":
				_, err = service.Store.RenameCard(card.ID, expected)
				if err == nil && change == "rename-and-restore" {
					expected = card.Title
					_, err = service.Store.RenameCard(card.ID, expected)
				}
			case "edit-task":
				expected = card.Title
				_, err = service.Store.UpdateCard(card.ID, expected, "Different task instructions")
			}
			if err != nil {
				t.Fatal(err)
			}
			close(runner.release)
			waitFor(t, func() bool { return quickTitleJobsFinished(service) })
			updated, err := service.Store.ResolveCard(card.ID)
			if err != nil || updated.Title != expected {
				t.Fatalf("manual change lost: %#v err=%v", updated, err)
			}
		})
	}
}

func TestQuickTaskTitleFailureLeavesSavedFallback(t *testing.T) {
	service, actual, project, board := appSetup(t)
	runner := &delayedQuickTitleRunner{actual: actual, entered: make(chan struct{}, 2), release: make(chan struct{}), err: errors.New("Spark unavailable")}
	close(runner.release)
	service.Runner = runner
	cleanupQuickTitleService(t, service)
	card, err := service.CreateCard(context.Background(), CardInput{
		Project: project.ID, Board: board.ID, Lane: model.LaneTodo,
		Prompt: "Keep this task available", AutoGenerateTitle: true, DeferStart: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, func() bool { return quickTitleJobsFinished(service) })
	updated, err := service.Store.ResolveCard(card.ID)
	if err != nil || updated.ID != card.ID || updated.Title != "Keep this task available" {
		t.Fatalf("fallback=%#v err=%v", updated, err)
	}
}

func TestQuickTaskTitleWorkersAreBoundedAndStopAtShutdown(t *testing.T) {
	service, actual, project, board := appSetup(t)
	runner := &delayedQuickTitleRunner{actual: actual, entered: make(chan struct{}, quickTaskTitleJobLimit+1), release: make(chan struct{})}
	service.Runner = runner
	cleanupQuickTitleService(t, service)
	for i := 0; i < quickTaskTitleJobLimit+1; i++ {
		if _, err := service.CreateCard(context.Background(), CardInput{
			Project: project.ID, Board: board.ID, Lane: model.LaneTodo,
			Prompt: "Keep queued title work bounded", AutoGenerateTitle: true, DeferStart: true,
		}); err != nil {
			t.Fatal(err)
		}
	}
	waitFor(t, func() bool { return len(runner.entered) == quickTaskTitleConcurrency })
	service.mu.Lock()
	jobs := len(service.quickTitleJobs)
	service.mu.Unlock()
	if jobs != quickTaskTitleJobLimit {
		t.Fatalf("queued title jobs=%d", jobs)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := service.SuspendActiveTurns(ctx); err != nil {
		t.Fatal(err)
	}
	if !quickTitleJobsFinished(service) {
		t.Fatal("title jobs survived daemon shutdown")
	}
}
