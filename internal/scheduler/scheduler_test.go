package scheduler

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/app"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

type testRunner struct{}

func (testRunner) Run(_ context.Context, request harness.Request, emit func(harness.Output) error) error {
	for _, chunk := range []string{
		`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`,
		`{"type":"text-start","id":"answer"}`,
		`{"type":"text-delta","id":"answer","delta":"scheduled response"}`,
		`{"type":"text-end","id":"answer"}`,
		`{"type":"finish","finishReason":"stop"}`,
	} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return nil
}

func setup(t *testing.T) (*Manager, *store.Store, model.Project, model.Board) {
	t.Helper()
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	repo := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(repo, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Atlas", Path: repo})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Delivery", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	service := app.New(data, testRunner{})
	return New(data, service), data, project, board
}

func waitRun(t *testing.T, data *store.Store, id, status string) model.ScheduleRun {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		run, err := data.ResolveScheduleRun(id)
		if err == nil && run.Status == status {
			return run
		}
		if time.Now().After(deadline) {
			t.Fatalf("run %s did not reach %s: %#v %v", id, status, run, err)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestRunNowCreatesOneTemplatedDraftWithOrigin(t *testing.T) {
	manager, data, project, board := setup(t)
	fixed := time.Date(2026, 8, 13, 7, 30, 0, 0, time.UTC)
	manager.now = func() time.Time { return fixed }
	schedule, err := manager.Create(store.ScheduleInput{
		Project: project.ID, Board: board.ID, Name: "Daily work", Cron: "0 9 * * 1-5", Timezone: "Europe/Berlin", Enabled: true,
		Action: model.ScheduleActionDraft, TitleTemplate: "Daily · {{date}}", PromptTemplate: "Work in {{project}} on {{scheduled_at}}", Provider: "mock", Model: "mock",
	})
	if err != nil {
		t.Fatal(err)
	}
	run, err := manager.RunNow(schedule.ID)
	if err != nil {
		t.Fatal(err)
	}
	if run.Status != model.ScheduleRunCompleted {
		t.Fatalf("run=%#v", run)
	}
	card, err := data.ResolveCard(run.CardID)
	if err != nil {
		t.Fatal(err)
	}
	if card.Title != "Daily · 2026-08-13" || card.Lane != model.LaneTodo || card.Origin == nil || card.Origin.ScheduleRunID != run.ID || card.InitialPrompt != "Work in Atlas on 2026-08-13T07:30:00Z" {
		t.Fatalf("card=%#v", card)
	}
	second, err := data.ClaimScheduleRun(schedule.ID, run.ScheduledFor, "", true)
	if err != nil || second.ID != run.ID {
		t.Fatalf("duplicate claim=%#v err=%v", second, err)
	}
	cards, _ := data.ListCards(store.CardFilter{})
	if len(cards) != 1 {
		t.Fatalf("cards=%#v", cards)
	}
}

func TestSchedulePersistsValidatedEffortOnCreatedCard(t *testing.T) {
	manager, data, project, board := setup(t)
	schedule, err := manager.Create(store.ScheduleInput{
		Project: project.ID, Board: board.ID, Name: "Careful work", Cron: "0 9 * * *", Timezone: "UTC",
		Action: model.ScheduleActionDraft, TitleTemplate: "Careful", PromptTemplate: "Think", Provider: "codex", Model: "gpt-5.6-sol", Effort: "high",
	})
	if err != nil {
		t.Fatal(err)
	}
	run, err := manager.RunNow(schedule.ID)
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.ResolveCard(run.CardID)
	if err != nil || card.Effort != "high" {
		t.Fatalf("card=%#v err=%v", card, err)
	}
	_, err = manager.Create(store.ScheduleInput{
		Project: project.ID, Board: board.ID, Name: "Unsupported", Cron: "0 10 * * *", Timezone: "UTC",
		Action: model.ScheduleActionDraft, TitleTemplate: "Bad", PromptTemplate: "Think", Provider: "codex", Model: "gpt-5.6-sol", Effort: "max",
	})
	if err == nil {
		t.Fatal("unsupported schedule effort was accepted")
	}
}

func TestTickArchivesDoneCardsUsingBoardPolicy(t *testing.T) {
	manager, data, project, board := setup(t)
	fixed := time.Now().UTC().Add(time.Second)
	manager.now = func() time.Time { return fixed }
	if _, err := data.UpdateBoardDoneArchivePolicy(board.ID, model.DoneArchiveImmediately); err != nil {
		t.Fatal(err)
	}
	card, err := data.CreateCard(store.CreateCardInput{Project: project.ID, Board: board.ID, Title: "Completed"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := data.MoveCard(card.ID, model.LaneDone, nil); err != nil {
		t.Fatal(err)
	}

	manager.Tick()
	card, err = data.ResolveCard(card.ID)
	if err != nil || !card.Archived {
		t.Fatalf("archived card=%#v err=%v", card, err)
	}
}

func TestDueRunUsesLatestMisfireAndAdvancesCursor(t *testing.T) {
	manager, data, project, board := setup(t)
	clock := time.Date(2026, 8, 13, 7, 29, 0, 0, time.UTC)
	manager.now = func() time.Time { return clock }
	schedule, err := manager.Create(store.ScheduleInput{Project: project.ID, Board: board.ID, Name: "Minute", Cron: "* * * * *", Timezone: "UTC", Enabled: true, Action: "draft", TitleTemplate: "Tick {{scheduled_at}}", PromptTemplate: "Tick", Provider: "mock", Model: "mock"})
	if err != nil {
		t.Fatal(err)
	}
	clock = clock.Add(4*time.Minute + 20*time.Second)
	manager.Tick()
	runs, _ := data.ListScheduleRuns(schedule.ID, 0)
	if len(runs) != 1 || runs[0].ScheduledFor != "2026-08-13T07:33:00Z" || runs[0].Status != model.ScheduleRunCompleted {
		t.Fatalf("runs=%#v", runs)
	}
	updated, _ := data.ResolveSchedule(schedule.ID)
	if updated.NextRunAt != "2026-08-13T07:34:00Z" {
		t.Fatalf("next=%s", updated.NextRunAt)
	}
}

func TestAutoRunWaitsForGlobalCapacityThenStarts(t *testing.T) {
	manager, data, project, board := setup(t)
	if _, err := data.UpdateSettings(model.Settings{GlobalParallelLimit: 1}); err != nil {
		t.Fatal(err)
	}
	hold, err := data.AcquireRuntimeLeaseFor("another-project", "another-board", "hold", "mock")
	if err != nil {
		t.Fatal(err)
	}
	schedule, err := manager.Create(store.ScheduleInput{Project: project.ID, Board: board.ID, Name: "Agent", Cron: "0 9 * * *", Timezone: "UTC", Enabled: true, Action: "run", TitleTemplate: "Run", PromptTemplate: "Do it", Provider: "mock", Model: "mock", BusyPolicy: "queue", OpenCardPolicy: "always"})
	if err != nil {
		t.Fatal(err)
	}
	run, err := manager.RunNow(schedule.ID)
	if err != nil {
		t.Fatal(err)
	}
	if run.Status != model.ScheduleRunWaitingForProject {
		t.Fatalf("waiting run=%#v", run)
	}
	card, _ := data.ResolveCard(run.CardID)
	if card.Lane != model.LaneTodo || card.InitialPromptSentAt != "" {
		t.Fatalf("waiting card=%#v", card)
	}
	if err := data.ReleaseRuntimeLease(hold); err != nil {
		t.Fatal(err)
	}
	manager.Tick()
	completed := waitRun(t, data, run.ID, model.ScheduleRunCompleted)
	card, _ = data.ResolveCard(completed.CardID)
	if card.InitialPromptSentAt == "" || card.Lane != model.LaneRunning {
		t.Fatalf("started card=%#v", card)
	}
}

func TestSkipIfOpenRecordsOccurrenceWithoutBrokenCardLink(t *testing.T) {
	manager, data, project, board := setup(t)
	schedule, err := manager.Create(store.ScheduleInput{Project: project.ID, Board: board.ID, Name: "Guarded", Cron: "0 9 * * *", Timezone: "UTC", Enabled: true, Action: "draft", TitleTemplate: "Guarded", PromptTemplate: "Do it", Provider: "mock", Model: "mock", OpenCardPolicy: "skip_if_open"})
	if err != nil {
		t.Fatal(err)
	}
	first, err := manager.RunNow(schedule.ID)
	if err != nil || first.Status != model.ScheduleRunCompleted {
		t.Fatalf("first=%#v err=%v", first, err)
	}
	second, err := manager.RunNow(schedule.ID)
	if err != nil {
		t.Fatal(err)
	}
	if second.Status != model.ScheduleRunSkipped || second.CardID != "" || second.Message == "" {
		t.Fatalf("second=%#v", second)
	}
	cards, _ := data.ListCards(store.CardFilter{})
	if len(cards) != 1 {
		t.Fatalf("cards=%#v", cards)
	}
}
