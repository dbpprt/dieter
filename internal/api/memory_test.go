package api

import (
	"strings"
	"testing"

	"connectrpc.com/connect"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
)

func TestMemoryServicePeopleAndAgentScope(t *testing.T) {
	t.Parallel()
	data := testkit.PeerStore(t, "dm_api_memory")
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Remembered", Path: testkit.GitRepo(t)})
	if err != nil {
		t.Fatal(err)
	}
	other, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Elsewhere", Path: testkit.GitRepo(t)})
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

	// Memory is off until a person turns it on for the project.
	_, err = client.SaveMemory(ctx, &dieterv1.SaveMemoryRequest{ProjectId: project.ID, Content: "A memory before memory is on."})
	wantCode(t, err, connect.CodeFailedPrecondition, "save with memory off")
	updated, err := client.UpdateProject(ctx, &dieterv1.UpdateProjectRequest{ProjectId: project.ID, MemoryEnabled: proto.Bool(true)})
	if err != nil || !updated.GetMemoryEnabled() {
		t.Fatalf("project memory on = %v, %v", updated, err)
	}
	if _, err = client.UpdateProject(ctx, &dieterv1.UpdateProjectRequest{ProjectId: other.ID, MemoryEnabled: proto.Bool(true)}); err != nil {
		t.Fatal(err)
	}
	created, err := client.CreateChat(ctx, &dieterv1.CreateConversationRequest{ProjectId: project.ID, Title: "Private chat", Prompt: "x", WorkspaceMode: "project", Memory: proto.Bool(false), DeferStart: true})
	if err != nil || created.GetMemory() {
		t.Fatalf("conversation created with memory off = %v, %v", created, err)
	}
	own, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Agent card", Prompt: "Report", Provider: "mock", Model: "mock", Memory: true})
	if err != nil {
		t.Fatal(err)
	}

	saved, err := client.SaveMemory(ctx, &dieterv1.SaveMemoryRequest{ProjectId: project.ID, Kind: "decision", Content: "Releases are cut from main every night; stable promotion needs approval."})
	if err != nil || saved.GetMemory().GetKind() != "decision" || saved.GetMemory().GetCreatedByCardId() != "" || saved.GetMemory().GetCreatedByMachineId() != "dm_api_memory" {
		t.Fatalf("person save = %v, %v", saved, err)
	}
	_, err = client.SaveMemory(ctx, &dieterv1.SaveMemoryRequest{Content: "No project given by a person."})
	wantCode(t, err, connect.CodeInvalidArgument, "save without a project")
	found, err := client.SearchMemory(ctx, &dieterv1.SearchMemoryRequest{ProjectId: project.ID, Query: "stable promotion approval"})
	if err != nil || len(found.GetMemories()) != 1 || found.GetMemories()[0].GetId() != saved.GetMemory().GetId() {
		t.Fatalf("person search = %v, %v", found, err)
	}
	status, err := client.GetMemoryStatus(ctx, &dieterv1.GetMemoryStatusRequest{})
	if err != nil || len(status.GetProjects()) != 2 || status.GetMachineId() != "dm_api_memory" {
		t.Fatalf("status = %v, %v", status, err)
	}

	defaults, err := client.GetMemorySettings(ctx, &emptypb.Empty{})
	if err != nil || defaults.GetConfigured() || defaults.GetDreaming() || defaults.GetMinHours() != 24 || defaults.GetMaxRetirePercent() != 25 {
		t.Fatalf("default settings = %v, %v", defaults, err)
	}
	settings, err := client.UpdateMemorySettings(ctx, &dieterv1.UpdateMemorySettingsRequest{Settings: &dieterv1.MemorySettings{Dreaming: true, Harness: "mock", Apply: "review", Window: "01:00-05:00"}, ExpectedRevision: defaults.GetRevision()})
	if err != nil || !settings.GetConfigured() || settings.GetHarness() != "mock" || settings.GetModel() == "" || settings.GetApply() != "review" || settings.GetMaxOperations() != 40 {
		t.Fatalf("saved settings = %v, %v", settings, err)
	}
	if _, err = client.UpdateMemorySettings(ctx, &dieterv1.UpdateMemorySettingsRequest{Settings: &dieterv1.MemorySettings{Dreaming: true, Harness: "mock", Apply: "review"}, ExpectedRevision: settings.GetRevision()}); err != nil {
		t.Fatal(err)
	}
	_, err = client.UpdateMemorySettings(ctx, &dieterv1.UpdateMemorySettingsRequest{Settings: &dieterv1.MemorySettings{Harness: "mock"}, ExpectedRevision: settings.GetRevision()})
	wantCode(t, err, connect.CodeAborted, "stale revision")
	for name, invalid := range map[string]*dieterv1.MemorySettings{
		"unknown harness": {Harness: "no-such-harness"},
		"window":          {Harness: "mock", Window: "late"},
		"apply":           {Harness: "mock", Apply: "sometimes"},
		"bounds":          {Harness: "mock", MaxOperations: 500},
	} {
		_, err = client.UpdateMemorySettings(ctx, &dieterv1.UpdateMemorySettingsRequest{Settings: invalid})
		wantCode(t, err, connect.CodeInvalidArgument, name)
	}

	// An agent turn: recall and save in its own project only, nothing else.
	request := startVaultTurn(t, client, runner, own.ID)
	agent := withHeaders(ctx, turnHeaders(request))
	agentSaved, err := client.SaveMemory(agent, &dieterv1.SaveMemoryRequest{Kind: "lesson", Content: "Approve stable promotions only after the nightly passed."})
	if err != nil || agentSaved.GetMemory().GetProjectId() != project.ID || agentSaved.GetMemory().GetCreatedByCardId() != own.ID || len(agentSaved.GetMemory().GetSources()) != 1 {
		t.Fatalf("agent save = %v, %v", agentSaved, err)
	}
	if found, err = client.SearchMemory(agent, &dieterv1.SearchMemoryRequest{Query: "stable promotion"}); err != nil || len(found.GetMemories()) != 2 {
		t.Fatalf("agent search = %v, %v", found, err)
	}
	_, err = client.SearchMemory(agent, &dieterv1.SearchMemoryRequest{ProjectId: other.ID, Query: "anything"})
	wantCode(t, err, connect.CodePermissionDenied, "agent searches another project")
	_, err = client.SaveMemory(agent, &dieterv1.SaveMemoryRequest{ProjectId: other.ID, Content: "Writing into another project."})
	wantCode(t, err, connect.CodePermissionDenied, "agent saves into another project")
	if status, err = client.GetMemoryStatus(agent, &dieterv1.GetMemoryStatusRequest{ProjectId: other.ID}); err != nil || len(status.GetProjects()) != 1 || status.GetProjects()[0].GetProjectId() != project.ID {
		t.Fatalf("agent status = %v, %v", status, err)
	}
	for name, call := range map[string]func() error{
		"forget": func() error {
			_, err := client.ForgetMemory(agent, &dieterv1.ForgetMemoryRequest{ProjectId: project.ID, MemoryId: saved.GetMemory().GetId()})
			return err
		},
		"reindex": func() error {
			_, err := client.ReindexMemory(agent, &dieterv1.ReindexMemoryRequest{ProjectId: project.ID})
			return err
		},
		"switch": func() error {
			_, err := client.SetCardMemory(agent, &dieterv1.SetCardMemoryRequest{CardId: own.ID, Enabled: false})
			return err
		},
		"settings": func() error {
			_, err := client.UpdateMemorySettings(agent, &dieterv1.UpdateMemorySettingsRequest{Settings: &dieterv1.MemorySettings{Harness: "mock"}})
			return err
		},
		"dream": func() error {
			_, err := client.StartMemoryDream(agent, &dieterv1.StartMemoryDreamRequest{ProjectId: project.ID})
			return err
		},
		"undo": func() error {
			_, err := client.UndoMemoryDream(agent, &dieterv1.MemoryDreamRef{CardId: own.ID})
			return err
		},
	} {
		wantCode(t, call(), connect.CodePermissionDenied, "agent "+name)
	}
	runner.release <- "done"
	waitForIdle(t, data, own.ID)

	switched, err := client.SetCardMemory(ctx, &dieterv1.SetCardMemoryRequest{CardId: own.ID, Enabled: false})
	if err != nil || switched.GetMemory() {
		t.Fatalf("switch off = %v, %v", switched, err)
	}
	if _, err = client.ForgetMemory(ctx, &dieterv1.ForgetMemoryRequest{ProjectId: project.ID, MemoryId: agentSaved.GetMemory().GetId()}); err != nil {
		t.Fatal(err)
	}
	_, err = client.ForgetMemory(ctx, &dieterv1.ForgetMemoryRequest{ProjectId: project.ID, MemoryId: agentSaved.GetMemory().GetId()})
	wantCode(t, err, connect.CodeNotFound, "forget twice")
	_, err = client.UndoMemoryDream(ctx, &dieterv1.MemoryDreamRef{CardId: own.ID})
	wantCode(t, err, connect.CodeNotFound, "undo of a card that is not a dream")
	if dreams, err := client.ListMemoryDreams(ctx, &dieterv1.ListMemoryDreamsRequest{ProjectId: project.ID}); err != nil || len(dreams.GetDreams()) != 0 {
		t.Fatalf("dreams = %v, %v", dreams, err)
	}
}

func TestMemoryRecordsRefuseRawKVWrites(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	client, _ := newConnectTestClient(t, data, vaultTurnRunner{}, testkit.MockCatalog())
	for _, namespace := range []string{"memory", "memory-settings"} {
		page, err := client.ListKV(t.Context(), &dieterv1.KVListRequest{Namespace: namespace})
		if err != nil {
			t.Fatal(err)
		}
		_, err = client.PutKV(t.Context(), &dieterv1.KVPutRequest{Ref: &dieterv1.KVRef{Account: page.GetAccount(), Namespace: namespace, Key: "default"}, ValueJson: []byte(`{"dreaming":true}`), OperationId: "op_kv_" + strings.ReplaceAll(namespace, "-", "_"), DaemonId: page.GetDaemonId()})
		wantCode(t, err, connect.CodePermissionDenied, "raw KV write of "+namespace)
	}
}
