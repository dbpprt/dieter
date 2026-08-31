package store

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
)

func scheduleFixtureInput(projectID, boardID, name string) ScheduleInput {
	return ScheduleInput{
		Project: projectID, Board: boardID, Name: name, Cron: "* * * * *", Timezone: "UTC",
		Enabled: true, Action: model.ScheduleActionDraft, TitleTemplate: name,
		PromptTemplate: "Run " + name, Provider: "codex", Model: "gpt-5.5",
		OpenCardPolicy: "always", BusyPolicy: "queue", WorkspaceMode: model.WorkspaceModeProject,
	}
}

func TestScheduleAndOccurrencePagesUseStableKeysetTokens(t *testing.T) {
	data, project, board := setup(t, model.WorkflowReview)
	var selected model.Schedule
	for index := range 123 {
		created, err := data.CreateSchedule(scheduleFixtureInput(project.ID, board.ID, fmt.Sprintf("Schedule %03d", index)))
		if err != nil {
			t.Fatal(err)
		}
		if index == 42 {
			selected = created
		}
	}
	seenSchedules := map[string]bool{}
	token := ""
	for {
		page, err := data.ListSchedulesPage(project.ID, 17, token)
		if err != nil {
			t.Fatal(err)
		}
		if page.TotalCount != 123 || len(page.Items) > 17 {
			t.Fatalf("schedule page count=%d items=%d", page.TotalCount, len(page.Items))
		}
		for _, item := range page.Items {
			if seenSchedules[item.ID] {
				t.Fatalf("duplicate schedule %s", item.ID)
			}
			seenSchedules[item.ID] = true
		}
		token = page.NextPageToken
		if token == "" {
			break
		}
	}
	if len(seenSchedules) != 123 {
		t.Fatalf("visited %d schedules", len(seenSchedules))
	}

	base := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	for index := range 137 {
		if _, err := data.ClaimScheduleRun(selected.ID, base.Add(time.Duration(index)*time.Minute).Format(time.RFC3339Nano), "", true); err != nil {
			t.Fatal(err)
		}
	}
	first, err := data.ListScheduleRunsPage(selected.ID, 19, "")
	if err != nil || len(first.Items) != 19 || first.NextPageToken == "" {
		t.Fatalf("first run page=%#v err=%v", first, err)
	}
	// A newer occurrence inserted between pages must not shift the keyset tail.
	if _, err := data.ClaimScheduleRun(selected.ID, base.Add(10_000*time.Minute).Format(time.RFC3339Nano), "", true); err != nil {
		t.Fatal(err)
	}
	seenRuns := map[string]bool{}
	for _, run := range first.Items {
		seenRuns[run.ID] = true
	}
	token = first.NextPageToken
	for token != "" {
		page, pageErr := data.ListScheduleRunsPage(selected.ID, 19, token)
		if pageErr != nil {
			t.Fatal(pageErr)
		}
		for _, run := range page.Items {
			if seenRuns[run.ID] {
				t.Fatalf("duplicate run %s", run.ID)
			}
			seenRuns[run.ID] = true
		}
		token = page.NextPageToken
	}
	if len(seenRuns) != 137 {
		t.Fatalf("keyset traversal visited %d original runs", len(seenRuns))
	}
}

func TestDeletedScheduleHistoryRemainsPageable(t *testing.T) {
	data, project, board := setup(t, model.WorkflowReview)
	schedule, err := data.CreateSchedule(scheduleFixtureInput(project.ID, board.ID, "Disposable"))
	if err != nil {
		t.Fatal(err)
	}
	run, err := data.ClaimScheduleRun(schedule.ID, "2026-08-31T12:00:00Z", "", true)
	if err != nil {
		t.Fatal(err)
	}
	if err := data.DeleteSchedule(schedule.ID); err != nil {
		t.Fatal(err)
	}
	page, err := data.ListScheduleRunsPage(schedule.ID, 10, "")
	if err != nil || len(page.Items) != 1 || page.Items[0].ID != run.ID {
		t.Fatalf("deleted history=%#v err=%v", page, err)
	}
}

func TestOccurrencePagesOrderMixedTimestampPrecisionChronologically(t *testing.T) {
	data, project, board := setup(t, model.WorkflowReview)
	schedule, err := data.CreateSchedule(scheduleFixtureInput(project.ID, board.ID, "Precision"))
	if err != nil {
		t.Fatal(err)
	}
	for _, scheduledFor := range []string{
		"2026-08-31T12:00:00Z",
		"2026-08-31T12:00:00.1Z",
		"2026-08-31T12:00:00.9Z",
	} {
		if _, err := data.ClaimScheduleRun(schedule.ID, scheduledFor, "", true); err != nil {
			t.Fatal(err)
		}
	}
	var ordered []string
	token := ""
	for {
		page, err := data.ListScheduleRunsPage(schedule.ID, 1, token)
		if err != nil {
			t.Fatal(err)
		}
		for _, run := range page.Items {
			ordered = append(ordered, run.ScheduledFor)
		}
		token = page.NextPageToken
		if token == "" {
			break
		}
	}
	want := []string{"2026-08-31T12:00:00.9Z", "2026-08-31T12:00:00.1Z", "2026-08-31T12:00:00Z"}
	if fmt.Sprint(ordered) != fmt.Sprint(want) {
		t.Fatalf("occurrence order=%v want=%v", ordered, want)
	}
}

func TestRunnableBatchReservesCapacityForPendingAndWaitingRuns(t *testing.T) {
	data, project, board := setup(t, model.WorkflowReview)
	schedule, err := data.CreateSchedule(scheduleFixtureInput(project.ID, board.ID, "Fair queue"))
	if err != nil {
		t.Fatal(err)
	}
	database, err := data.scheduleDatabase()
	if err != nil {
		t.Fatal(err)
	}
	base := time.Date(2026, 8, 31, 12, 0, 0, 0, time.UTC)
	for index := range 120 {
		status := model.ScheduleRunPending
		nextAttemptAt := ""
		if index >= 60 {
			status = model.ScheduleRunWaitingForProject
			nextAttemptAt = base.Add(-time.Minute).Format(time.RFC3339Nano)
		}
		scheduledFor := base.Add(time.Duration(index) * time.Minute).Format(time.RFC3339Nano)
		run := model.ScheduleRun{
			ID: fmt.Sprintf("sr_fair_%03d", index), ScheduleID: schedule.ID, ProjectID: project.ID, BoardID: board.ID,
			ScheduledFor: scheduledFor, Status: status, CreatedAt: scheduledFor, UpdatedAt: scheduledFor,
		}
		if err := insertScheduleRunDocument(database, run, nextAttemptAt); err != nil {
			t.Fatal(err)
		}
	}
	runs, err := data.ListRunnableScheduleRuns(base, 100)
	if err != nil {
		t.Fatal(err)
	}
	counts := map[string]int{}
	for _, run := range runs {
		counts[run.Status]++
	}
	if len(runs) != 100 || counts[model.ScheduleRunPending] != 50 || counts[model.ScheduleRunWaitingForProject] != 50 {
		t.Fatalf("runnable batch=%d statuses=%v", len(runs), counts)
	}
}

func TestLegacyScheduleMarkdownMigratesOnce(t *testing.T) {
	root := t.TempDir()
	data := New(root)
	if err := osMkdirAll(data.scheduleDir()); err != nil {
		t.Fatal(err)
	}
	if err := osMkdirAll(data.scheduleRunDir()); err != nil {
		t.Fatal(err)
	}
	schedule := model.Schedule{ID: "sch_legacy", ProjectID: "p_legacy", BoardID: "b_legacy", Name: "Legacy",
		Cron: "0 9 * * *", Timezone: "UTC", Action: model.ScheduleActionDraft, WorkspaceMode: model.WorkspaceModeProject,
		CreatedAt: "2026-08-31T10:00:00Z", UpdatedAt: "2026-08-31T10:00:00Z"}
	if err := writeMarkdown(filepath.Join(data.scheduleDir(), schedule.ID+".md"), schedule, "legacy prompt"); err != nil {
		t.Fatal(err)
	}
	run := model.ScheduleRun{ID: "sr_legacy", ScheduleID: schedule.ID, ProjectID: schedule.ProjectID, BoardID: schedule.BoardID,
		ScheduledFor: "2026-08-31T11:00:00Z", Status: model.ScheduleRunCompleted,
		CreatedAt: "2026-08-31T11:00:00Z", UpdatedAt: "2026-08-31T11:00:00Z"}
	if err := writeMarkdown(filepath.Join(data.scheduleRunDir(), run.ID+".md"), run, "legacy result"); err != nil {
		t.Fatal(err)
	}
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	loaded, err := data.scheduleByID(schedule.ID)
	if err != nil || loaded.PromptTemplate != "legacy prompt" {
		t.Fatalf("migrated schedule=%#v err=%v", loaded, err)
	}
	loadedRun, err := data.ResolveScheduleRun(run.ID)
	if err != nil || loadedRun.Message != "legacy result" {
		t.Fatalf("migrated run=%#v err=%v", loadedRun, err)
	}
	// Leaving the legacy files in place is safe: the durable marker prevents
	// later starts from overwriting the indexed canonical rows.
	loaded.Name = "Indexed"
	database, err := data.scheduleDatabase()
	if err != nil || upsertScheduleDocument(database, loaded) != nil {
		t.Fatal(err)
	}
	if _, err := data.scheduleDatabase(); err != nil {
		t.Fatal(err)
	}
	again, err := data.scheduleByID(schedule.ID)
	if err != nil || again.Name != "Indexed" {
		t.Fatalf("migration replayed legacy data: %#v err=%v", again, err)
	}
}

func osMkdirAll(path string) error {
	return os.MkdirAll(path, 0o755)
}
