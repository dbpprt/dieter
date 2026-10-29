package api

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/protobuf/types/known/emptypb"
)

func TestScheduleAndSettingsConnectEndToEnd(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	data := testkit.Store(t)
	application := NewWithOptions(data, slog.New(slog.NewTextHandler(io.Discard, nil)), Options{Runner: newFakeRunner(), Catalog: isolatedMockCatalog()})
	settled := make(chan model.ScheduleRun, 4)
	application.schedules.OnRunSettled = func(run model.ScheduleRun) { settled <- run }
	host := testkit.HTTPServer(application.Handler())
	t.Cleanup(host.Close)
	client := dieterclient.NewConnect(localHTTPClient(host.Client(), data.Root), host.URL)
	workspace, err := client.CreateProject(ctx, &dieterv1.CreateProjectRequest{Mode: "open", Path: testkit.CheckoutDir(t), BoardName: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	project, board := workspace.GetProject(), workspace.GetBoard()

	settings, err := client.UpdateSettings(ctx, &dieterv1.UpdateSettingsRequest{Settings: &dieterv1.Settings{}})
	if err != nil || settings.GetUpdatedAt() == "" {
		t.Fatalf("settings=%#v err=%v", settings, err)
	}
	loaded, err := client.GetSettings(ctx, &emptypb.Empty{})
	if err != nil || loaded.GetUpdatedAt() != settings.GetUpdatedAt() {
		t.Fatalf("loaded settings=%#v err=%v", loaded, err)
	}
	options, err := client.GetSettingsOptions(ctx, &emptypb.Empty{})
	if err != nil || len(options.GetProjects()) != 1 || len(options.GetBoards()) != 1 || len(options.GetAgents().GetHarnesses()) == 0 {
		t.Fatalf("options=%#v err=%v", options, err)
	}
	preview, err := client.PreviewSchedule(ctx, &dieterv1.PreviewScheduleRequest{Cron: "0 9 * * 1-5", Timezone: "Europe/Berlin", Count: 5})
	if err != nil || len(preview.GetTimes()) != 5 {
		t.Fatalf("preview=%#v err=%v", preview, err)
	}

	schedule, err := client.CreateSchedule(ctx, &dieterv1.SaveScheduleRequest{Schedule: &dieterv1.ScheduleDraft{
		ProjectId: project.GetId(), BoardId: board.GetId(), Name: "Morning", Cron: "0 9 * * 1-5", Timezone: "Europe/Berlin", Enabled: true,
		Action: model.ScheduleActionRun, TitleTemplate: "Morning · {{date}}", PromptTemplate: "Check {{project}}", Provider: "mock", Model: "mock",
		OpenCardPolicy: "skip_if_open", MisfirePolicy: "latest", WorkspaceMode: model.WorkspaceModeProject,
	}})
	if err != nil {
		t.Fatal(err)
	}
	run, err := client.RunSchedule(ctx, &dieterv1.ScheduleRef{ScheduleId: schedule.GetId()})
	if err != nil || run.GetScheduleId() != schedule.GetId() {
		t.Fatalf("run=%#v err=%v", run, err)
	}
	// The occurrence's agent turn completes asynchronously; wait for the
	// scheduler to settle it, then read the outcome through the API.
	select {
	case <-settled:
	case <-time.After(testkit.Budget(30 * time.Second)):
		t.Fatal("scheduled run did not settle")
	}
	runs, err := client.ListScheduleRuns(ctx, &dieterv1.ListScheduleRunsRequest{ScheduleId: schedule.GetId(), PageSize: 5})
	if err != nil || len(runs.GetRuns()) != 1 || runs.GetRuns()[0].GetId() != run.GetId() || runs.GetRuns()[0].GetStatus() != model.ScheduleRunCompleted {
		t.Fatalf("runs=%#v err=%v", runs, err)
	}
	paused, err := client.SetScheduleEnabled(ctx, &dieterv1.SetScheduleEnabledRequest{ScheduleId: schedule.GetId(), Enabled: false})
	if err != nil || paused.GetEnabled() {
		t.Fatalf("paused=%#v err=%v", paused, err)
	}
	schedules, err := client.ListSchedules(ctx, &dieterv1.ListSchedulesRequest{ProjectId: project.GetId()})
	if err != nil || len(schedules.GetSchedules()) != 1 {
		t.Fatalf("schedules=%#v err=%v", schedules, err)
	}
	if _, err := client.DeleteSchedule(ctx, &dieterv1.ScheduleRef{ScheduleId: schedule.GetId()}); err != nil {
		t.Fatal(err)
	}
}

func TestSchedulePagesConnectEndToEnd(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), testkit.Budget(30*time.Second))
	defer cancel()
	data := testkit.Store(t)
	client, _ := newConnectTestClient(t, data, newFakeRunner(), testkit.MockCatalog())
	workspace, err := client.CreateProject(ctx, &dieterv1.CreateProjectRequest{
		Mode: "open", Path: testkit.CheckoutDir(t), BoardName: "Main", Workflow: model.WorkflowReview,
	})
	if err != nil {
		t.Fatal(err)
	}
	project, board := workspace.GetProject(), workspace.GetBoard()
	created := make([]string, 0, 5)
	for index := range 5 {
		response, createErr := client.CreateSchedule(ctx, &dieterv1.SaveScheduleRequest{Schedule: &dieterv1.ScheduleDraft{
			ProjectId: project.GetId(), BoardId: board.GetId(), Name: fmt.Sprintf("Schedule %d", index),
			Cron: "* * * * *", Timezone: "UTC", Enabled: true, Action: model.ScheduleActionDraft,
			TitleTemplate: "Run {{date}}", PromptTemplate: "Do work", Provider: "mock", Model: "mock",
			OpenCardPolicy: "always", MisfirePolicy: "latest", WorkspaceMode: model.WorkspaceModeProject,
		}})
		if createErr != nil {
			t.Fatal(createErr)
		}
		created = append(created, response.GetId())
	}

	seenSchedules := map[string]bool{}
	pageToken := ""
	for {
		page, pageErr := client.ListSchedules(ctx, &dieterv1.ListSchedulesRequest{
			ProjectId: project.GetId(), PageSize: 2, PageToken: pageToken,
		})
		if pageErr != nil {
			t.Fatal(pageErr)
		}
		if page.GetTotalCount() != 5 || len(page.GetSchedules()) > 2 {
			t.Fatalf("schedule page=%#v", page)
		}
		for _, schedule := range page.GetSchedules() {
			if seenSchedules[schedule.GetId()] {
				t.Fatalf("duplicate schedule %s", schedule.GetId())
			}
			seenSchedules[schedule.GetId()] = true
		}
		pageToken = page.GetNextPageToken()
		if pageToken == "" {
			break
		}
	}
	if len(seenSchedules) != 5 {
		t.Fatalf("visited %d schedules", len(seenSchedules))
	}

	for range 5 {
		if _, err := client.RunSchedule(ctx, &dieterv1.ScheduleRef{ScheduleId: created[0]}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := client.DeleteSchedule(ctx, &dieterv1.ScheduleRef{ScheduleId: created[0]}); err != nil {
		t.Fatal(err)
	}
	seenRuns := map[string]bool{}
	pageToken = ""
	for {
		page, pageErr := client.ListScheduleRuns(ctx, &dieterv1.ListScheduleRunsRequest{
			ScheduleId: created[0], PageSize: 2, PageToken: pageToken,
		})
		if pageErr != nil {
			t.Fatal(pageErr)
		}
		if len(page.GetRuns()) > 2 {
			t.Fatalf("run page=%#v", page)
		}
		for _, run := range page.GetRuns() {
			if seenRuns[run.GetId()] {
				t.Fatalf("duplicate run %s", run.GetId())
			}
			seenRuns[run.GetId()] = true
		}
		pageToken = page.GetNextPageToken()
		if pageToken == "" {
			break
		}
	}
	if len(seenRuns) != 5 {
		t.Fatalf("visited %d runs after schedule deletion", len(seenRuns))
	}
}
