package api

import (
	"os"
	"path/filepath"
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

func TestAgentTurnsCanLaunchAndContinueStrix(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Scans", Path: testkit.GitRepo(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	// Exercise an arbitrary provider ID backed by the Strix adapter too.
	adapter, ok := testkit.MockCatalog().ResolveAdapter("strix")
	if !ok {
		t.Fatal("missing Strix adapter")
	}
	adapter.ID = "security-scan"
	catalog := harness.StaticCatalogOf([]harness.Adapter{adapter}, true)
	runner := &testkit.FakeRunner{Release: make(chan struct{})}
	client, _ := newConnectTestClient(t, data, runner, catalog)
	var ids []string
	t.Cleanup(func() {
		close(runner.Release)
		for _, id := range ids {
			testkit.Eventually(t, 30*time.Second, func() bool {
				conversation, err := data.Conversations.Get(id)
				active, leaseErr := data.Leases.CardActive(id)
				return err == nil && leaseErr == nil && !active && conversation.ActiveTurn == nil && len(conversation.Queue) == 0
			}, "scan and follow-up to finish")
		}
		if !t.Failed() && runner.Count() != 2*len(ids)-1 {
			t.Errorf("admitted %d turns, want %d", runner.Count(), 2*len(ids)-1)
		}
		waitForQuietStore(t, data.Root)
	})
	ctx := t.Context()
	if _, err := client.InitVault(ctx, &dieterv1.InitVaultRequest{Name: "test"}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.CreateVaultItem(ctx, &dieterv1.CreateVaultItemRequest{Name: "strix", Password: "fixture-model-key", Notes: "STRIX_LLM=openai/test"}); err != nil {
		t.Fatal(err)
	}
	parent, err := client.CreateCard(ctx, &dieterv1.CreateConversationRequest{ProjectId: project.ID, BoardId: board.ID,
		Title: "Coder", Prompt: "Work", Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject, Lane: model.LaneRunning})
	if err != nil {
		t.Fatal(err)
	}
	ids = append(ids, parent.GetId())
	testkit.Eventually(t, 30*time.Second, func() bool { return runner.Count() == 1 }, "parent turn")
	agent := withHeaders(ctx, map[string]string{turnTokenMetadata: runner.Request(0).Environment["DIETER_TURN_TOKEN"]})
	for _, operation := range []string{"create", "chat", "start", "move", "send", "deferred"} {
		t.Run(operation, func(t *testing.T) {
			request := &dieterv1.CreateConversationRequest{ProjectId: project.ID, BoardId: board.ID,
				Title: operation, Prompt: "Scan for injection", Provider: "security-scan", Model: "default", WorkspaceMode: model.WorkspaceModeWorktree,
				Lane: model.LaneTodo, ClientId: "agent", CommandId: "create-" + operation}
			if operation == "create" {
				request.Lane = model.LaneRunning
			}
			request.DeferStart = operation == "deferred"
			if request.DeferStart {
				request.Lane = model.LaneRunning
			}
			before := runner.Count()
			var scan *dieterv1.Card
			var err error
			if operation == "chat" {
				scan, err = client.CreateChat(agent, request)
			} else {
				scan, err = client.CreateCard(agent, request)
			}
			if err != nil {
				t.Fatal(err)
			}
			ids = append(ids, scan.GetId())
			switch operation {
			case "start", "deferred":
				start := &dieterv1.StartCardRequest{CardId: scan.GetId(), ClientId: "agent", CommandId: "start-" + operation}
				if _, err := client.StartCard(agent, start); err != nil {
					t.Fatal(err)
				}
				if replay, err := client.StartCard(agent, start); err != nil || !replay.GetReplayed() {
					t.Fatalf("start replay = %v, %v", replay, err)
				}
			case "move":
				if _, err := client.MoveCard(agent, &dieterv1.MoveCardRequest{CardId: scan.GetId(), Lane: model.LaneRunning}); err != nil {
					t.Fatal(err)
				}
			case "send":
				if _, err := client.SendMessage(agent, &dieterv1.SendMessageRequest{CardId: scan.GetId(), Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Scan for injection"}}}); err != nil {
					t.Fatal(err)
				}
			}
			testkit.Eventually(t, 30*time.Second, func() bool { return runner.Count() == before+1 }, "one scan turn")
			turn := runner.Request(before)
			if turn.Adapter != "strix" || turn.Prompt != "Scan for injection" || turn.SteerEnabled || turn.ChannelHookCommand != "" || scan.GetVaultAccess() {
				t.Fatalf("automated scan: request=%+v card=%v", turn, scan)
			}
			followup := &dieterv1.SendMessageRequest{CardId: scan.GetId(), ClientId: "agent", CommandId: "follow-" + operation,
				Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Validate the finding"}}}
			for range 2 {
				if result, err := client.SendMessage(agent, followup); err != nil || !result.GetQueued() {
					t.Fatalf("follow-up = %v, %v", result, err)
				}
			}
			conversation, err := data.Conversations.Get(scan.GetId())
			if err != nil || len(conversation.Queue) != 1 || runner.Count() != before+1 {
				t.Fatalf("follow-up duplicated or started concurrently: %+v, %v", conversation, err)
			}
			// A forged token still fails before admitting another message.
			bad := withHeaders(ctx, map[string]string{turnTokenMetadata: "forged"})
			_, err = client.SendMessage(bad, &dieterv1.SendMessageRequest{CardId: scan.GetId(), Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Bad"}}})
			wantCode(t, err, connect.CodePermissionDenied, "forged caller")
		})
	}
}

func TestStrixLaunchOperationsStillRejectForgedTurnTokens(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Scans", Path: testkit.GitRepo(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	runner := &testkit.FakeRunner{}
	client, _ := newConnectTestClient(t, data, runner, testkit.MockCatalog())
	request := &dieterv1.CreateConversationRequest{ProjectId: project.ID, BoardId: board.ID, Title: "Scan", Prompt: "Scan",
		Provider: "strix", WorkspaceMode: model.WorkspaceModeWorktree, Lane: model.LaneTodo}
	scan, err := client.CreateCard(t.Context(), request)
	if err != nil {
		t.Fatal(err)
	}
	bad := withHeaders(t.Context(), map[string]string{turnTokenMetadata: "forged"})
	_, err = client.CreateCard(bad, request)
	wantCode(t, err, connect.CodePermissionDenied, "agent draft with forged token")
	_, err = client.CreateChat(bad, request)
	wantCode(t, err, connect.CodePermissionDenied, "agent chat with forged token")
	_, err = client.StartCard(bad, &dieterv1.StartCardRequest{CardId: scan.GetId(), ClientId: "bad", CommandId: "start"})
	wantCode(t, err, connect.CodePermissionDenied, "agent start with forged token")
	_, err = client.MoveCard(bad, &dieterv1.MoveCardRequest{CardId: scan.GetId(), Lane: model.LaneRunning})
	wantCode(t, err, connect.CodePermissionDenied, "agent move with forged token")
	_, err = client.SendMessage(bad, &dieterv1.SendMessageRequest{CardId: scan.GetId(), Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Scan"}}})
	wantCode(t, err, connect.CodePermissionDenied, "agent message with forged token")
	stored, err := data.Kanban.ResolveCard(scan.GetId())
	conversation, conversationErr := data.Conversations.Get(scan.GetId())
	if err != nil || conversationErr != nil || stored.Lane != model.LaneTodo || len(conversation.Messages) != 0 || runner.Count() != 0 {
		t.Fatalf("rejected requests mutated the draft: %+v, %+v, %v, %v", stored, conversation, err, conversationErr)
	}
}

// Strix turns get their model credentials from a vault item, run only in a
// worktree, take the submitted message as their instruction, and do not
// accept live steering.
func TestStrixTurnsFollowTheirSafetyRules(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Pentest", Path: testkit.GitRepo(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	runner := vaultTurnRunner{started: make(chan harness.Request, 1), release: make(chan string, 1)}
	client, _ := newConnectTestClient(t, data, runner, testkit.MockCatalog())
	ctx := t.Context()
	if _, err := client.InitVault(ctx, &dieterv1.InitVaultRequest{Name: "test"}); err != nil {
		t.Fatal(err)
	}
	const apiKey = "sk-strix-test-key-123"
	if _, err := client.CreateVaultItem(ctx, &dieterv1.CreateVaultItemRequest{
		Name: "strix", Urls: []string{"https://models.example/v1"}, Password: apiKey,
		Notes: "STRIX_LLM=openai/glm-5.3-flash\nSTRIX_TELEMETRY=1\nPATH=/attacker\nLLM_EXTRA_HEADERS={\"X-Team\":\"red\"}\nEXA_API_KEY=exa-test-key-456",
	}); err != nil {
		t.Fatal(err)
	}

	// A shared checkout is refused when the conversation is created.
	_, err = client.CreateCard(ctx, &dieterv1.CreateConversationRequest{
		ProjectId: project.ID, BoardId: board.ID, Title: "Scan", Prompt: "Scan the app", Lane: model.LaneTodo,
		Provider: "strix", WorkspaceMode: model.WorkspaceModeProject,
	})
	wantCode(t, err, connect.CodeFailedPrecondition, "strix in a shared checkout")
	shared, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Shared", Prompt: "Scan", Provider: "strix", Model: "default", ProviderOptions: map[string]string{"credentials": "strix"}})
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.SendMessage(ctx, &dieterv1.SendMessageRequest{CardId: shared.ID, Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Scan"}}})
	wantCode(t, err, connect.CodeFailedPrecondition, "strix turn in a shared checkout")

	// A missing credentials item fails before any turn state exists.
	created, err := client.CreateCard(ctx, &dieterv1.CreateConversationRequest{
		ProjectId: project.ID, BoardId: board.ID, Title: "No key", Prompt: "Scan", Lane: model.LaneTodo,
		Provider: "strix", WorkspaceMode: model.WorkspaceModeWorktree, ProviderOptions: map[string]string{"credentials": "missing"},
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = client.SendMessage(ctx, &dieterv1.SendMessageRequest{CardId: created.GetId(), Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Scan"}}})
	wantCode(t, err, connect.CodeFailedPrecondition, "strix without its vault item")
	if conversation, getErr := data.Conversations.Get(created.GetId()); getErr != nil || len(conversation.Messages) != 0 || conversation.ActiveTurn != nil {
		t.Fatalf("refused turn left state: %+v %v", conversation, getErr)
	}

	scan, err := client.CreateCard(ctx, &dieterv1.CreateConversationRequest{
		ProjectId: project.ID, BoardId: board.ID, Title: "Scan", Prompt: "Scan for injection", Lane: model.LaneTodo,
		Provider: "strix", WorkspaceMode: model.WorkspaceModeWorktree,
	})
	if err != nil {
		t.Fatal(err)
	}

	// The worker gets the vault item's settings and the submitted instruction,
	// with no steering.
	if _, err := client.SendMessage(ctx, &dieterv1.SendMessageRequest{CardId: scan.GetId(), Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Scan for injection"}}}); err != nil {
		t.Fatal(err)
	}
	var request harness.Request
	select {
	case request = <-runner.started:
	case <-time.After(testkit.Budget(30 * time.Second)):
		t.Fatal("strix turn did not start")
	}
	if request.Adapter != "strix" || request.Model != "" || request.Options["credentials"] != "strix" || request.Options["scan_mode"] != "quick" {
		t.Fatalf("strix request = %+v", request)
	}
	want := map[string]string{
		"LLM_API_KEY":       apiKey,
		"LLM_API_BASE":      "https://models.example/v1",
		"STRIX_LLM":         "openai/glm-5.3-flash",
		"LLM_EXTRA_HEADERS": `{"X-Team":"red"}`,
		"EXA_API_KEY":       "exa-test-key-456",
	}
	for key, value := range want {
		if request.Environment[key] != value {
			t.Errorf("environment %s=%q want %q", key, request.Environment[key], value)
		}
	}
	for _, key := range []string{"STRIX_TELEMETRY", "PATH"} {
		if _, ok := request.Environment[key]; ok {
			t.Errorf("vault notes set %s", key)
		}
	}
	if request.SteerEnabled || request.ChannelHookCommand != "" {
		t.Errorf("strix turn steering=%v hook=%q", request.SteerEnabled, request.ChannelHookCommand)
	}
	if request.DiffBase == "" {
		t.Error("strix request has no diff base for a changes-only scan")
	}
	if request.Prompt != "Scan for injection" {
		t.Errorf("strix prompt = %q, want the submitted instruction only", request.Prompt)
	}
	if !strings.HasSuffix(request.ProjectPath, scan.GetId()) && !strings.Contains(request.ProjectPath, "worktrees") {
		t.Errorf("strix project path %q is not the card's worktree", request.ProjectPath)
	}
	// The key never lands in the transcript.
	runner.release <- "LLM_API_KEY=" + apiKey
	waitForIdle(t, data, scan.GetId())
	// A finished scan waits for a person in Review.
	deadline := time.Now().Add(testkit.Budget(10 * time.Second))
	for {
		card, err := data.Kanban.ResolveCard(scan.GetId())
		if err != nil {
			t.Fatal(err)
		}
		if card.Lane == model.LaneReview {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("finished scan lane = %q, want review", card.Lane)
		}
		time.Sleep(20 * time.Millisecond)
	}
	conversation, err := data.Conversations.Get(scan.GetId())
	if err != nil {
		t.Fatal(err)
	}
	for _, message := range conversation.Messages {
		for _, part := range message.Parts {
			if strings.Contains(string(part.Output), apiKey) || strings.Contains(part.Text, apiKey) {
				t.Fatalf("transcript stores the API key: %+v", part)
			}
		}
	}
	waitForQuietStore(t, data.Root)
}

// waitForQuietStore waits until turn bookkeeping that finishes after a turn
// (workspace refresh, channel cleanup) stops changing the store, so the test's
// temporary DIETER_HOME can be removed.
func waitForQuietStore(t *testing.T, root string) {
	t.Helper()
	path := filepath.Join(root, "sync", "highwater")
	last, _ := os.ReadFile(path)
	stableSince := time.Now()
	deadline := time.Now().Add(testkit.Budget(10 * time.Second))
	for time.Since(stableSince) < 300*time.Millisecond {
		if time.Now().After(deadline) {
			t.Fatal("the store kept changing after the turns ended")
		}
		time.Sleep(25 * time.Millisecond)
		if current, _ := os.ReadFile(path); string(current) != string(last) {
			last, stableSince = current, time.Now()
		}
	}
}
