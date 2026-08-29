package server

import (
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/protobuf/types/known/emptypb"
)

func TestGRPCMachineListener(t *testing.T) {
	repo := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(repo, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, "README.md"), []byte("# Fixture\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	data := store.New(t.TempDir())
	project, err := data.CreateProject(store.CreateProjectInput{Name: "Fixture", Path: repo})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.CreateBoard(store.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	application := NewWithRunner(data, slog.New(slog.NewTextHandler(io.Discard, nil)), &fakeRunner{})
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	httpServer := &http.Server{Handler: application.Handler()}
	go func() { _ = httpServer.Serve(listener) }()
	t.Cleanup(func() {
		_ = httpServer.Close()
		_ = listener.Close()
	})

	response, err := http.Get("http://" + listener.Addr().String() + "/")
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusNotFound {
		t.Fatalf("machine-only root status = %d", response.StatusCode)
	}

	connection, err := grpc.NewClient(
		listener.Addr().String(),
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	client := dieterv1.NewDieterServiceClient(connection)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	health, err := client.Health(ctx, &emptypb.Empty{})
	if err != nil || health.GetStatus() != "ok" {
		t.Fatalf("gRPC health = %#v, %v", health, err)
	}
	state, err := client.GetState(ctx, &dieterv1.GetStateRequest{ProjectId: project.ID, BoardId: board.ID})
	if err != nil || len(state.GetProjects()) != 1 || len(state.GetBoards()) != 1 {
		t.Fatalf("state = %#v, %v", state, err)
	}
	promptSettings, err := client.GetPromptSettings(ctx, &emptypb.Empty{})
	if err != nil || promptSettings.GetPromptTemplate() == "" || len(promptSettings.GetVariables()) == 0 {
		t.Fatalf("gRPC prompt settings = %#v, %v", promptSettings, err)
	}
	if _, err := client.SetProjectPromptTemplate(ctx, &dieterv1.SetScopedPromptTemplateRequest{
		ScopeId: project.ID, PromptTemplate: "Native prompt\n{{project.instructions_block}}\n{{labels.instructions_block}}",
	}); err != nil {
		t.Fatal(err)
	}
	promptPreview, err := client.PreviewPrompt(ctx, &dieterv1.PreviewPromptRequest{ProjectId: project.ID, BoardId: board.ID, Scope: model.ConversationScopeBoard})
	if err != nil || promptPreview.GetSource() != "project" || promptPreview.GetInstructions() == "" {
		t.Fatalf("gRPC prompt preview = %#v, %v", promptPreview, err)
	}
	directories, err := client.ListDirectories(ctx, &dieterv1.ListDirectoriesRequest{Path: filepath.Dir(repo)})
	if err != nil {
		t.Fatal(err)
	}
	foundRepository := false
	for _, entry := range directories.GetEntries() {
		if entry.GetPath() == repo && entry.GetGitRepository() {
			foundRepository = true
			break
		}
	}
	if !foundRepository {
		t.Fatalf("native directory listing did not expose repository: %#v", directories)
	}
	secondRepo := filepath.Join(t.TempDir(), "remote-repo")
	if err := os.MkdirAll(filepath.Join(secondRepo, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	createdWorkspace, err := client.CreateProject(ctx, &dieterv1.CreateProjectRequest{
		Mode: "open", Path: secondRepo, Name: "Remote fixture", BoardName: "Main", Workflow: model.WorkflowReview,
	})
	canonicalSecondRepo, canonicalErr := filepath.EvalSymlinks(secondRepo)
	if err != nil || canonicalErr != nil || createdWorkspace.GetProject().GetPath() != canonicalSecondRepo || createdWorkspace.GetBoard().GetProjectId() != createdWorkspace.GetProject().GetId() {
		t.Fatalf("native project creation = %#v, %v", createdWorkspace, err)
	}
	card, err := client.CreateCard(ctx, &dieterv1.CreateConversationRequest{
		ProjectId: project.ID, BoardId: board.ID, Lane: model.LaneTodo,
		Title: "Native work", Prompt: "Build the app", Provider: "codex",
		Model: "gpt-5.5", DeferStart: true, WorkspaceMode: model.WorkspaceModeMain,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.SendMessage(ctx, &dieterv1.SendMessageRequest{
		CardId: card.GetId(),
		Parts:  []*dieterv1.MessagePart{{Type: "text", Text: "Start from Android"}},
	}); err != nil {
		t.Fatal(err)
	}
	var snapshot *dieterv1.ConversationSnapshot
	for {
		snapshot, err = client.GetConversation(ctx, &dieterv1.GetConversationRequest{CardId: card.GetId(), Limit: 30})
		if err != nil {
			t.Fatal(err)
		}
		if snapshot.GetConversation().GetStatus() == "idle" &&
			len(snapshot.GetConversation().GetMessages()) >= 2 &&
			len(snapshot.GetConversation().GetTaskPlans()) == 1 &&
			len(snapshot.GetConversation().GetSubagents()) == 1 &&
			snapshot.GetDetail().GetCard().GetRuntime() == "idle" {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-time.After(10 * time.Millisecond):
		}
	}
	got := ""
	for _, part := range snapshot.GetConversation().GetMessages()[1].GetParts() {
		if part.GetType() == "text" {
			got = part.GetText()
		}
	}
	if got != "Built locally" {
		t.Fatalf("assistant response = %q", got)
	}
	if _, err := client.AddComment(ctx, &dieterv1.AddCommentRequest{CardId: card.GetId(), Message: "Looks good", Name: "Android"}); err != nil {
		t.Fatal(err)
	}
	files, err := client.ListFiles(ctx, &dieterv1.ListFilesRequest{ProjectId: project.ID})
	if err != nil || len(files.GetEntries()) != 1 || files.GetEntries()[0].GetName() != "README.md" {
		t.Fatalf("files = %#v, %v", files, err)
	}
	document, err := client.ReadFile(ctx, &dieterv1.ReadFileRequest{ProjectId: project.ID, Path: "README.md"})
	if err != nil || document.GetContent() != "# Fixture\n" {
		t.Fatalf("document = %#v, %v", document, err)
	}
	schedule, err := client.CreateSchedule(ctx, &dieterv1.SaveScheduleRequest{Schedule: &dieterv1.ScheduleDraft{
		ProjectId: project.ID, BoardId: board.ID, Name: "Daily",
		Cron: "0 9 * * 1-5", Timezone: "UTC", Action: model.ScheduleActionDraft,
		TitleTemplate: "Daily check", PromptTemplate: "Check the repository",
		Provider: "codex", Model: "gpt-5.5", WorkspaceMode: model.WorkspaceModeMain,
	}})
	if err != nil || schedule.GetName() != "Daily" {
		t.Fatalf("schedule = %#v, %v", schedule, err)
	}
}
