//go:build e2e

package cli

import (
	"bytes"
	"strings"
	"testing"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestDaemonCLIAgentChannels(t *testing.T) {
	t.Setenv("DIETER_TURN_TOKEN", "")
	client, output, data := daemonCLIForTest(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Path: initTestRepository(t, "channels"), Name: "Channels"})
	if err != nil {
		t.Fatal(err)
	}
	assertChannelCLI(t, client, output, data, project.ID)
}

// assertChannelCLI drives every channel command as a human over the client's
// route (local, verified direct TLS or the gateway relay).
func assertChannelCLI(t *testing.T, client *CLI, output *bytes.Buffer, data *store.Store, projectID string) {
	t.Helper()
	// These assertions act as a human; an agent turn running the suite would
	// otherwise be the caller.
	client.env.TurnToken = ""
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: projectID, Name: home.NewID("Channels-"), Workflow: "review"})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: projectID, Board: board.ID, Lane: model.LaneTodo, Title: "Channel reader"})
	if err != nil {
		t.Fatal(err)
	}
	var settings dieterv1.ChannelSettings
	if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "channel", "settings", "--board", board.ID, "--set", "on")), &settings); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, override := range settings.GetOverrides() {
		found = found || override.GetScope() == "board" && override.GetId() == board.ID && override.GetValue() == "on"
	}
	if !found {
		t.Fatalf("settings after enabling the board: %v", &settings)
	}
	var posted dieterv1.ChannelMessage
	raw := runDaemonCLI(t, client, output, "channel", "post", "--project", projectID, "--kind", "decision", "--file", "src/pricing.go", "Keep", "src/pricing.go", "rules", "pure.")
	if err := protojson.Unmarshal([]byte(raw), &posted); err != nil {
		t.Fatalf("post output %q: %v", raw, err)
	}
	if posted.GetBody() != "Keep src/pricing.go rules pure." || !posted.GetPinned() || posted.GetAuthor().GetKind() != "human" || posted.GetFiles()[0] != "src/pricing.go" {
		t.Fatalf("posted = %v", &posted)
	}
	if posted.GetOriginDaemonId() == "" {
		t.Fatalf("posted without its origin machine: %v", &posted)
	}
	var here dieterv1.ChannelMessage
	if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "channel", "post", "--project", projectID, "--here", "Stop", "pushing", "to", "main.")), &here); err != nil || !here.GetHere() || len(here.GetToCardIds()) != 0 {
		t.Fatalf("@here post = %v, %v", &here, err)
	}
	if text := runDaemonCLI(t, client, output, "channel", "messages", "--project", projectID); !strings.Contains(text, posted.GetId()) || !strings.Contains(text, "[pinned]") {
		t.Fatalf("messages = %q", text)
	}
	var channels dieterv1.ListChannelsResponse
	if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "channel", "list", "--format", "json")), &channels); err != nil {
		t.Fatal(err)
	}
	enabled := false
	for _, channel := range channels.GetChannels() {
		enabled = enabled || channel.GetProjectId() == projectID && channel.GetEnabled() && channel.GetLastSeq() >= posted.GetSeq()
	}
	if !enabled {
		t.Fatalf("channel list = %v", &channels)
	}
	if text := runDaemonCLI(t, client, output, "channel", "check", "--card", card.ID, "src/pricing.go"); !strings.Contains(text, "Pinned decisions") || !strings.Contains(text, "Keep src/pricing.go rules pure.") {
		t.Fatalf("check = %q", text)
	}
	if text := runDaemonCLI(t, client, output, "channel", "claims", "--project", projectID); !strings.HasPrefix(text, "PATH") {
		t.Fatalf("claims = %q", text)
	}
	var inbox dieterv1.ChannelMessagePage
	if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "channel", "inbox", "--card", card.ID, "--format", "json")), &inbox); err != nil {
		t.Fatal(err)
	}
	if len(inbox.GetMessages()) == 0 || inbox.GetMessages()[len(inbox.GetMessages())-1].GetId() != posted.GetId() {
		t.Fatalf("inbox = %v", &inbox)
	}
	if text := runDaemonCLI(t, client, output, "channel", "inbox", "--card", card.ID); text != "No unread channel messages.\n" {
		t.Fatalf("second inbox = %q", text)
	}
	var unpinned dieterv1.ChannelMessage
	if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "channel", "pin", "--project", projectID, "--off", posted.GetId())), &unpinned); err != nil || unpinned.GetPinned() {
		t.Fatalf("unpin = %v, %v", &unpinned, err)
	}
	if text := runDaemonCLI(t, client, output, "channel", "read", "--project", projectID); !strings.HasPrefix(text, "read through ") {
		t.Fatalf("read = %q", text)
	}
	var frame dieterv1.ChannelFrame
	line := strings.TrimSpace(runDaemonCLI(t, client, output, "channel", "watch", "--project", projectID, "--count", "1"))
	if err := protojson.Unmarshal([]byte(line), &frame); err != nil || !frame.GetReset_() || frame.GetSummary().GetProjectId() != projectID {
		t.Fatalf("watch frame %q: %v", line, err)
	}
	// Outside an agent turn the hook has no opinion and never fails.
	client.In = strings.NewReader(`{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/pricing.go"}}`)
	if text := runDaemonCLI(t, client, output, "channel", "hook"); text != "" {
		t.Fatalf("hook = %q, want no opinion", text)
	}
	if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "channel", "settings", "--board", board.ID, "--set", "inherit")), &settings); err != nil {
		t.Fatal(err)
	}
	for _, override := range settings.GetOverrides() {
		if override.GetId() == board.ID {
			t.Fatalf("inherit kept the override: %v", &settings)
		}
	}
}
