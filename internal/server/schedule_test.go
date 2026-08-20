package server

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"
	naucliov1 "github.com/dbpprt/nauclio/internal/gen/nauclio/v1"
	"github.com/dbpprt/nauclio/internal/model"
	"github.com/dbpprt/nauclio/internal/store"
	"google.golang.org/protobuf/types/known/emptypb"
)

func TestScheduleAndSettingsConnectEndToEnd(t *testing.T) {
	t.Setenv("NAUCLIO_ENABLE_MOCK_HARNESS", "1")
	// Settings options intentionally exercise live provider discovery. A cold
	// OMP/Pi startup can use the discovery layer's 30-second bound.
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	data := store.New(t.TempDir())
	client, _ := newConnectTestClient(t, data, &fakeRunner{})
	workspace, err := client.CreateProject(ctx, connect.NewRequest(&naucliov1.CreateProjectRequest{Mode: "open", Path: testRepository(t), BoardName: "Main", Workflow: model.WorkflowReview}))
	if err != nil {
		t.Fatal(err)
	}
	project, board := workspace.Msg.GetProject(), workspace.Msg.GetBoard()

	settings, err := client.UpdateSettings(ctx, connect.NewRequest(&naucliov1.UpdateSettingsRequest{Settings: &naucliov1.Settings{
		GlobalParallelLimit: 3, AgentParallelLimits: map[string]int32{"mock": 1}, BoardParallelLimits: map[string]int32{board.GetId(): 2},
	}}))
	if err != nil || settings.Msg.GetGlobalParallelLimit() != 3 || settings.Msg.GetAgentParallelLimits()["mock"] != 1 {
		t.Fatalf("settings=%#v err=%v", settings, err)
	}
	loaded, err := client.GetSettings(ctx, connect.NewRequest(&emptypb.Empty{}))
	if err != nil || loaded.Msg.GetBoardParallelLimits()[board.GetId()] != 2 {
		t.Fatalf("loaded settings=%#v err=%v", loaded, err)
	}
	options, err := client.GetSettingsOptions(ctx, connect.NewRequest(&emptypb.Empty{}))
	if err != nil || len(options.Msg.GetProjects()) != 1 || len(options.Msg.GetBoards()) != 1 || len(options.Msg.GetAgents().GetHarnesses()) == 0 {
		t.Fatalf("options=%#v err=%v", options, err)
	}
	preview, err := client.PreviewSchedule(ctx, connect.NewRequest(&naucliov1.PreviewScheduleRequest{Cron: "0 9 * * 1-5", Timezone: "Europe/Berlin", Count: 5}))
	if err != nil || len(preview.Msg.GetTimes()) != 5 {
		t.Fatalf("preview=%#v err=%v", preview, err)
	}

	schedule, err := client.CreateSchedule(ctx, connect.NewRequest(&naucliov1.SaveScheduleRequest{Schedule: &naucliov1.ScheduleDraft{
		ProjectId: project.GetId(), BoardId: board.GetId(), Name: "Morning", Cron: "0 9 * * 1-5", Timezone: "Europe/Berlin", Enabled: true,
		Action: model.ScheduleActionRun, TitleTemplate: "Morning · {{date}}", PromptTemplate: "Check {{project}}", Provider: "mock", Model: "mock",
		OpenCardPolicy: "skip_if_open", MisfirePolicy: "latest", BusyPolicy: "queue",
	}}))
	if err != nil {
		t.Fatal(err)
	}
	run, err := client.RunSchedule(ctx, connect.NewRequest(&naucliov1.ScheduleRef{ScheduleId: schedule.Msg.GetId()}))
	if err != nil || run.Msg.GetScheduleId() != schedule.Msg.GetId() {
		t.Fatalf("run=%#v err=%v", run, err)
	}
	status := run.Msg.GetStatus()
	deadline := time.Now().Add(3 * time.Second)
	for status != model.ScheduleRunCompleted && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
		runs, listErr := client.ListScheduleRuns(ctx, connect.NewRequest(&naucliov1.ListScheduleRunsRequest{ScheduleId: schedule.Msg.GetId(), Limit: 5}))
		if listErr != nil {
			t.Fatal(listErr)
		}
		if len(runs.Msg.GetRuns()) > 0 {
			status = runs.Msg.GetRuns()[0].GetStatus()
		}
	}
	if status != model.ScheduleRunCompleted {
		t.Fatalf("run status=%s", status)
	}
	paused, err := client.SetScheduleEnabled(ctx, connect.NewRequest(&naucliov1.SetScheduleEnabledRequest{ScheduleId: schedule.Msg.GetId(), Enabled: false}))
	if err != nil || paused.Msg.GetEnabled() {
		t.Fatalf("paused=%#v err=%v", paused, err)
	}
	schedules, err := client.ListSchedules(ctx, connect.NewRequest(&naucliov1.ListSchedulesRequest{ProjectId: project.GetId()}))
	if err != nil || len(schedules.Msg.GetSchedules()) != 1 {
		t.Fatalf("schedules=%#v err=%v", schedules, err)
	}
	if _, err := client.DeleteSchedule(ctx, connect.NewRequest(&naucliov1.ScheduleRef{ScheduleId: schedule.Msg.GetId()})); err != nil {
		t.Fatal(err)
	}
}
