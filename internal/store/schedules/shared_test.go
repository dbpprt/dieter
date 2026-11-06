package schedules_test

import (
	"errors"
	"testing"

	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/schedules"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestScheduleHistoryCannotCrossAccountSwitch(t *testing.T) {
	t.Parallel()
	s := testkit.PeerStore(t, "machine_a")
	p, err := s.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Repo", Path: testkit.ProjectDir(t), InitialBoardName: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	b, err := s.Kanban.InitialBoard(p.ID)
	if err != nil {
		t.Fatal(err)
	}
	schedule, err := s.Schedules.Create(schedules.Input{Project: p.ID, Board: b.ID, Name: "Daily", Cron: "0 9 * * *", Timezone: "UTC", TitleTemplate: "Daily", PromptTemplate: "Check", Provider: "codex", Model: "gpt-5", WorkspaceMode: "project"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Replica.BindPeerAccount("other-account", "other", "machine_b", "https://gateway.test"); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Schedules.ListRunsPage(schedule.ID, 10, ""); !errors.Is(err, home.ErrNotFound) {
		t.Fatalf("history leaked: %v", err)
	}
	items, err := s.Schedules.List("")
	if err != nil || len(items) != 0 {
		t.Fatalf("definitions leaked: %v %v", items, err)
	}
}
