package api

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestChannelServiceIdentifiesAgentsAndGuardsSettings(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Pricing", Path: testkit.CheckoutDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	agentCard, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Rename tiers", Prompt: "Work", Provider: "mock", Model: "mock"})
	if err != nil {
		t.Fatal(err)
	}
	other, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Add tier cap", Prompt: "Work", Provider: "mock", Model: "mock"})
	if err != nil {
		t.Fatal(err)
	}
	runner := vaultTurnRunner{started: make(chan harness.Request, 1), release: make(chan string, 1)}
	client, _ := newConnectTestClient(t, data, runner, testkit.MockCatalog())
	ctx := t.Context()

	// Off by default: humans cannot post.
	if _, err := client.PostChannelMessage(ctx, &dieterv1.PostChannelMessageRequest{ProjectId: project.ID, Body: "hello"}); err == nil {
		t.Fatal("posted while agent channels are off")
	}
	settings, err := client.SetChannelSetting(ctx, &dieterv1.SetChannelSettingRequest{Scope: "board", Id: board.ID, Value: "on"})
	if err != nil || len(settings.GetOverrides()) != 1 || settings.GetOverrides()[0].GetValue() != "on" || settings.GetGlobal() {
		t.Fatalf("settings = %v, %v", settings, err)
	}
	if _, err := client.SetChannelSetting(ctx, &dieterv1.SetChannelSettingRequest{Scope: "board", Id: "b_missing", Value: "on"}); err == nil {
		t.Fatal("an unknown board was accepted")
	}

	// A live turn token makes the caller that card's agent.
	request := startVaultTurn(t, client, runner, agentCard.ID)
	agent := withHeaders(ctx, map[string]string{turnTokenMetadata: request.Environment["DIETER_TURN_TOKEN"]})
	if !request.SteerEnabled || !strings.Contains(request.Instructions, "Agent channels (experimental) are on") {
		t.Fatalf("the turn of an enabled board lacks channels: steer=%v", request.SteerEnabled)
	}
	posted, err := client.PostChannelMessage(agent, &dieterv1.PostChannelMessageRequest{Kind: "decision", Body: "Tier caps live next to their rules in src/module3.js."})
	if err != nil {
		t.Fatal(err)
	}
	if posted.GetAuthor().GetKind() != "agent" || posted.GetAuthor().GetCardId() != agentCard.ID || posted.GetProjectId() != project.ID || !posted.GetPinned() {
		t.Fatalf("agent post = %v", posted)
	}
	if _, err := client.SetChannelSetting(agent, &dieterv1.SetChannelSettingRequest{Scope: "global", Value: "on"}); err == nil {
		t.Fatal("an agent changed agent channel settings")
	} else {
		wantCode(t, err, connect.CodePermissionDenied, "agent settings write")
	}
	if _, err := client.GetChannelInbox(agent, &dieterv1.GetChannelInboxRequest{CardId: other.ID}); err == nil {
		t.Fatal("an agent read another card's inbox")
	}
	// A forged token is refused; a hook with one fails open.
	forged := withHeaders(ctx, map[string]string{turnTokenMetadata: "dtt1:" + agentCard.ID + ":turn:bad"})
	if _, err := client.PostChannelMessage(forged, &dieterv1.PostChannelMessageRequest{Body: "x"}); err == nil {
		t.Fatal("a forged turn token was accepted")
	}
	hook, err := client.HandleChannelHook(forged, &dieterv1.ChannelHookRequest{EventJson: []byte(`{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/module3.js"}}`)})
	if err != nil || len(hook.GetOutputJson()) != 0 {
		t.Fatalf("forged hook = %v, %v; want no opinion", hook, err)
	}
	// The agent's real hook claims the file; a check by a human for the other card sees it.
	if hook, err = client.HandleChannelHook(agent, &dieterv1.ChannelHookRequest{EventJson: []byte(`{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"src/module3.js"}}`)}); err != nil || len(hook.GetOutputJson()) != 0 {
		t.Fatalf("own claim hook = %v, %v", hook, err)
	}
	check, err := client.CheckChannelFiles(ctx, &dieterv1.CheckChannelFilesRequest{CardId: other.ID, Files: []string{"src/module3.js"}})
	if err != nil || len(check.GetConflicts()) != 1 || check.GetConflicts()[0].GetCardId() != agentCard.ID || len(check.GetDecisions()) != 1 || check.GetUnread() != 1 {
		t.Fatalf("check = %v, %v", check, err)
	}
	if !strings.Contains(check.GetSummary(), "being changed by agent "+agentCard.ID) || !strings.Contains(check.GetSummary(), "Tier caps live") {
		t.Fatalf("summary = %q", check.GetSummary())
	}
	claims, err := client.ListChannelClaims(ctx, &dieterv1.ListChannelClaimsRequest{ProjectId: project.Name})
	if err != nil || len(claims.GetClaims()) != 1 {
		t.Fatalf("claims = %v, %v", claims, err)
	}
	// Humans read a card's inbox; a peek keeps it undelivered.
	page, err := client.GetChannelInbox(ctx, &dieterv1.GetChannelInboxRequest{CardId: other.ID, Peek: true})
	if err != nil || len(page.GetMessages()) != 1 {
		t.Fatalf("peek = %v, %v", page, err)
	}
	if page, err = client.GetChannelInbox(ctx, &dieterv1.GetChannelInboxRequest{CardId: other.ID}); err != nil || len(page.GetMessages()) != 1 {
		t.Fatalf("inbox = %v, %v", page, err)
	}
	if page, _ = client.GetChannelInbox(ctx, &dieterv1.GetChannelInboxRequest{CardId: other.ID}); len(page.GetMessages()) != 0 {
		t.Fatalf("delivered messages came back: %v", page)
	}
	channels, err := client.ListChannels(ctx, &dieterv1.ListChannelsRequest{})
	if err != nil || len(channels.GetChannels()) != 1 || !channels.GetChannels()[0].GetEnabled() || channels.GetChannels()[0].GetClaims() != 1 || channels.GetChannels()[0].GetUnread() != 1 {
		t.Fatalf("channels = %v, %v", channels, err)
	}
	var running bool
	for _, member := range channels.GetChannels()[0].GetMembers() {
		running = running || member.GetCardId() == agentCard.ID && member.GetStatus() == "running" && len(member.GetHolds()) == 1
	}
	if !running {
		t.Fatalf("members = %v, want the agent running and holding its file", channels.GetChannels()[0].GetMembers())
	}
	if _, err := client.MarkChannelRead(ctx, &dieterv1.MarkChannelReadRequest{ProjectId: project.ID, Seq: posted.GetSeq()}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.ReleaseChannelClaims(agent, &dieterv1.ReleaseChannelClaimsRequest{CardId: other.ID}); err == nil {
		t.Fatal("an agent released another card's claims")
	}
	runner.release <- "done"
	waitForIdle(t, data, agentCard.ID)
	testkit.Eventually(t, testkit.Budget(10*time.Second), func() bool {
		claims, err := client.ListChannelClaims(ctx, &dieterv1.ListChannelClaimsRequest{})
		return err == nil && len(claims.GetClaims()) == 0
	}, "claims released at turn end")
	// The token died with the turn.
	if _, err := client.PostChannelMessage(agent, &dieterv1.PostChannelMessageRequest{Body: "late"}); err == nil {
		t.Fatal("a finished turn's token still posts")
	}
}

func TestWatchChannelStreamsNewAndChangedMessages(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Watched", Path: testkit.CheckoutDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	client, _ := newConnectTestClient(t, data, &testkit.FakeRunner{}, testkit.MockCatalog())
	ctx, cancel := context.WithTimeout(t.Context(), testkit.Budget(30*time.Second))
	defer cancel()
	if _, err := client.SetChannelSetting(ctx, &dieterv1.SetChannelSettingRequest{Scope: "global", Value: "on"}); err != nil {
		t.Fatal(err)
	}
	first, err := client.PostChannelMessage(ctx, &dieterv1.PostChannelMessageRequest{ProjectId: project.ID, Body: "first"})
	if err != nil {
		t.Fatal(err)
	}
	stream, err := client.WatchChannel(ctx, &dieterv1.WatchChannelRequest{ProjectId: project.ID})
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	next := func() *dieterv1.ChannelFrame {
		t.Helper()
		for stream.Receive() {
			if frame := stream.Msg(); !frame.GetHeartbeat() {
				return frame
			}
		}
		t.Fatalf("watch ended: %v", stream.Err())
		return nil
	}
	reset := next()
	if !reset.GetReset_() || len(reset.GetMessages()) != 1 || reset.GetMessages()[0].GetId() != first.GetId() || reset.GetSummary().GetProjectId() != project.ID {
		t.Fatalf("reset frame = %v", reset)
	}
	second, err := client.PostChannelMessage(ctx, &dieterv1.PostChannelMessageRequest{ProjectId: project.ID, Body: "second", ThreadId: first.GetId()})
	if err != nil {
		t.Fatal(err)
	}
	seen := map[string]*dieterv1.ChannelMessage{}
	for seen[second.GetId()] == nil || seen[first.GetId()].GetReplyCount() != 1 {
		for _, message := range next().GetMessages() {
			seen[message.GetId()] = message
			if message.GetId() == first.GetId() && message.GetReplyCount() == 0 {
				delete(seen, first.GetId())
			}
		}
		if seen[first.GetId()] == nil {
			seen[first.GetId()] = &dieterv1.ChannelMessage{}
		}
	}
	if _, err := client.PinChannelMessage(ctx, &dieterv1.PinChannelMessageRequest{ProjectId: project.ID, MessageId: second.GetId(), Pinned: true}); err != nil {
		t.Fatal(err)
	}
	for pinned := false; !pinned; {
		for _, message := range next().GetMessages() {
			pinned = pinned || message.GetId() == second.GetId() && message.GetPinned()
		}
	}
	raw, _ := json.Marshal(seen[second.GetId()].GetThreadId())
	if string(raw) != `"`+first.GetId()+`"` {
		t.Fatalf("reply thread = %s", raw)
	}
}

func TestPeerNoticePartCarriesItsPayload(t *testing.T) {
	t.Parallel()
	part := protoMessagePart(model.UIMessagePart{Type: "data-peer-notice", Text: "Release tag PAPAYA-7", Data: json.RawMessage(`{"messageId":"m_1","channel":"pricing"}`)}, nil)
	if part.GetType() != "data-peer-notice" || part.GetText() != "Release tag PAPAYA-7" || string(part.GetDataJson()) != `{"messageId":"m_1","channel":"pricing"}` {
		t.Fatalf("part = %v", part)
	}
	if plain := protoMessagePart(model.UIMessagePart{Type: "text", Text: "hi", Data: json.RawMessage(`{}`)}, nil); len(plain.GetDataJson()) != 0 {
		t.Fatalf("a text part carried data: %v", plain)
	}
}
