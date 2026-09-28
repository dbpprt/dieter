package cli

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/store"
)

func TestDaemonCLIBoardsUseRequestedProject(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	client, output, data := daemonCLIForTest(t)
	for _, name := range []string{"afa", "dieter"} {
		_, err := data.CreateProject(store.CreateProjectInput{Name: name, Path: initTestRepository(t, name), InitialBoardName: "Main", InitialWorkflow: "review"})
		if err != nil {
			t.Fatal(err)
		}
	}
	project, err := data.ResolveProject("dieter")
	if err != nil {
		t.Fatal(err)
	}
	boards, err := data.ListBoards(project.ID)
	if err != nil || len(boards) != 1 {
		t.Fatalf("boards: %+v %v", boards, err)
	}
	board := boards[0]
	for _, ref := range []string{project.ID, "dieter"} {
		if got := strings.TrimSpace(runDaemonCLI(t, client, output, "board", "list", "--project", ref, "--format", "ids")); got != board.ID {
			t.Fatalf("list %s: %s", ref, got)
		}
	}
	runDaemonCLI(t, client, output, "board", "show", board.ID)
	if err := client.Run([]string{"board", "show", "Main"}); err == nil || !strings.Contains(err.Error(), "ambiguous") {
		t.Fatalf("ambiguous Main: %v", err)
	}
	runDaemonCLI(t, client, output, "board", "label", "add", "--board", board.ID, "--name", "#YOLO", "--instructions", "Preserve these instructions")
	raw := runDaemonCLI(t, client, output, "card", "create", "--project", project.ID, "--board", board.ID, "--lane", "todo", "--title", "Scoped draft", "--prompt", "Do not start", "--workspace", "project", "--provider", "mock", "--model", "mock")
	var card struct {
		ID    string `json:"id"`
		Board string `json:"boardId"`
		Lane  string `json:"lane"`
	}
	if err := json.Unmarshal([]byte(raw), &card); err != nil || card.Board != board.ID || card.Lane != "todo" {
		t.Fatalf("card: %s %v", raw, err)
	}
	created := runDaemonCLI(t, client, output, "board", "create", "--project", project.ID, "--name", "Second")
	var second struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal([]byte(created), &second); err != nil || second.ID == "" {
		t.Fatalf("create: %s %v", created, err)
	}
	runDaemonCLI(t, client, output, "board", "show", second.ID)
	if got := strings.Fields(runDaemonCLI(t, client, output, "board", "list", "--project", project.ID, "--format", "ids")); len(got) != 2 {
		t.Fatalf("list: %v", got)
	}
	got := runDaemonCLI(t, client, output, "project", "show", project.ID)
	var summary struct {
		BoardCount int `json:"boardCount"`
	}
	if err := json.Unmarshal([]byte(got), &summary); err != nil || summary.BoardCount != 2 {
		t.Fatalf("count: %s %v", got, err)
	}
}
