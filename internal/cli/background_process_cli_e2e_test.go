package cli

import (
	"bytes"
	"strings"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestDaemonCLIBackgroundConversationProcesses(t *testing.T) {
	client, output, data := daemonCLIForTest(t)
	project, err := data.CreateProject(store.CreateProjectInput{Path: initTestRepository(t, "processes"), Name: "Processes"})
	if err != nil {
		t.Fatal(err)
	}
	assertBackgroundProcessCLI(t, client, output, data, project.ID)
}

func assertBackgroundProcessCLI(t *testing.T, client *CLI, output *bytes.Buffer, data *store.Store, projectID string) {
	t.Helper()
	card, err := data.CreateChat(store.CreateCardInput{Project: projectID, Title: "Background process", WorkspaceMode: "project"})
	if err != nil {
		t.Fatal(err)
	}
	raw := runDaemonCLI(t, client, output, "remote", "exec", "--card", card.ID, "--detach", "--format", "json", "--name", "Preview", "--", "/bin/sh", "-c", "printf registered; exec sleep 30")
	var value dieterv1.Execution
	if err := protojson.Unmarshal([]byte(raw), &value); err != nil || value.CardId != card.ID || value.Status != "running" {
		t.Fatalf("background=%s err=%v", raw, err)
	}
	if listed := runDaemonCLI(t, client, output, "remote", "list", "--card", card.ID, "--format", "ids"); !strings.Contains(listed, value.Id) {
		t.Fatalf("scoped list=%s", listed)
	}
	runDaemonCLI(t, client, output, "remote", "cancel", value.Id)
	deadline := time.Now().Add(5 * time.Second)
	for {
		raw = runDaemonCLI(t, client, output, "remote", "show", value.Id)
		value.Reset()
		if err := protojson.Unmarshal([]byte(raw), &value); err != nil {
			t.Fatal(err)
		}
		if value.Status == "canceled" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("process still running after explicit stop: %s", raw)
		}
		time.Sleep(10 * time.Millisecond)
	}
	runDaemonCLI(t, client, output, "remote", "close", value.Id)
}
