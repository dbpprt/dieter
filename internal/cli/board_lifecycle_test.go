package cli

import (
	"bytes"
	"strings"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestDaemonCLIBoardRetirement(t *testing.T) {
	client, output, data := daemonCLIForTest(t)
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Repo", Path: initTestRepository(t, "repo"), InitialBoardName: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	assertBoardRetirementCLI(t, client, output, project.ID)
}

func assertBoardRetirementCLI(t *testing.T, client *CLI, output *bytes.Buffer, projectID string) {
	t.Helper()
	raw := runDaemonCLI(t, client, output, "board", "create", "--project", projectID, "--name", "Diagnostic")
	var board dieterv1.Board
	if err := protojson.Unmarshal([]byte(raw), &board); err != nil {
		t.Fatal(err)
	}
	raw = runDaemonCLI(t, client, output, "board", "show", board.Id)
	if err := protojson.Unmarshal([]byte(raw), &board); err != nil {
		t.Fatal(err)
	}
	args := []string{"board", "retire", "--revision", board.RetirementRevision, "--operation", "retire-" + board.Id, board.Id}
	first := runDaemonCLI(t, client, output, args...)
	if second := runDaemonCLI(t, client, output, args...); second != first {
		t.Fatalf("receipt changed: %s / %s", first, second)
	}
	if raw := runDaemonCLI(t, client, output, "board", "list", "--project", projectID, "--format", "ids"); strings.Contains(raw, board.Id) {
		t.Fatal("retired board remains active")
	}
	if raw := runDaemonCLI(t, client, output, "board", "list", "--project", projectID, "--retired", "--format", "json"); !strings.Contains(raw, board.Id) {
		t.Fatalf("missing retired board: %s", raw)
	}
	raw = runDaemonCLI(t, client, output, "board", "show", board.Id)
	if err := protojson.Unmarshal([]byte(raw), &board); err != nil || !board.Retired {
		t.Fatalf("retired: %s %v", raw, err)
	}
	runDaemonCLI(t, client, output, "board", "restore", "--revision", board.RetirementRevision, "--operation", "restore-"+board.Id, board.Id)
	if raw := runDaemonCLI(t, client, output, "board", "list", "--project", projectID, "--format", "ids"); !strings.Contains(raw, board.Id) {
		t.Fatal("restored board missing")
	}
}
