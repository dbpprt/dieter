package server

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

func TestConversationWorkspaceConnectEndToEndForCardAndChat(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	client, _ := newConnectTestClient(t, data, &fakeRunner{})
	repository := realGitRepository(t)
	created, err := client.CreateProject(ctx, connect.NewRequest(&dieterv1.CreateProjectRequest{
		Mode: "open", Path: repository, Name: "Workspace", BoardName: "Main", Workflow: model.WorkflowReview,
		DefaultWorkspaceMode: model.WorkspaceModeWorktree, BaseBranch: "main",
	}))
	if err != nil {
		t.Fatal(err)
	}
	project, board := created.Msg.GetProject(), created.Msg.GetBoard()
	card, err := client.CreateCard(ctx, connect.NewRequest(&dieterv1.CreateConversationRequest{
		ProjectId: project.GetId(), BoardId: board.GetId(), Lane: model.LaneTodo,
		Title: "Card workspace", Prompt: "work", DeferStart: true,
	}))
	if err != nil {
		t.Fatal(err)
	}
	chat, err := client.CreateChat(ctx, connect.NewRequest(&dieterv1.CreateConversationRequest{
		ProjectId: project.GetId(), Title: "Chat workspace", Prompt: "work", DeferStart: true,
	}))
	if err != nil {
		t.Fatal(err)
	}
	cardWorkspace, err := client.GetWorkspace(ctx, connect.NewRequest(&dieterv1.ConversationRef{CardId: card.Msg.GetId()}))
	if err != nil {
		t.Fatal(err)
	}
	chatWorkspace, err := client.GetWorkspace(ctx, connect.NewRequest(&dieterv1.ConversationRef{CardId: chat.Msg.GetId()}))
	if err != nil {
		t.Fatal(err)
	}
	if cardWorkspace.Msg.GetPath() == chatWorkspace.Msg.GetPath() || cardWorkspace.Msg.GetRevision() == "" || chatWorkspace.Msg.GetRevision() == "" {
		t.Fatalf("card=%#v chat=%#v", cardWorkspace.Msg, chatWorkspace.Msg)
	}
	document, err := client.ReadFile(ctx, connect.NewRequest(&dieterv1.ReadFileRequest{CardId: card.Msg.GetId(), Path: "README.md"}))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.SaveFile(ctx, connect.NewRequest(&dieterv1.SaveFileRequest{
		CardId: card.Msg.GetId(), Path: "README.md", Revision: document.Msg.GetRevision(), Content: "conversation scoped\n",
	})); err != nil {
		t.Fatal(err)
	}
	set, err := client.GetChangeset(ctx, connect.NewRequest(&dieterv1.GetChangesetRequest{CardId: card.Msg.GetId()}))
	if err != nil || len(set.Msg.GetFiles()) != 1 || set.Msg.GetRevision() == "" {
		t.Fatalf("changeset=%#v err=%v", set, err)
	}
	diff, err := client.GetFileDiff(ctx, connect.NewRequest(&dieterv1.GetDiffRequest{
		CardId: card.Msg.GetId(), Path: "README.md", ExpectedRevision: set.Msg.GetRevision(),
	}))
	if err != nil || !strings.Contains(diff.Msg.GetPatch(), "+conversation scoped") {
		t.Fatalf("diff=%#v err=%v", diff, err)
	}
	comment, err := client.AddChangeComment(ctx, connect.NewRequest(&dieterv1.AddChangeCommentRequest{
		CardId: card.Msg.GetId(), Revision: set.Msg.GetRevision(), Path: "README.md", Side: "new", Line: 1, Body: "Looks good", Author: "Tester",
	}))
	if err != nil || comment.Msg.GetBody() != "Looks good" {
		t.Fatalf("comment=%#v err=%v", comment, err)
	}
	terminalSession, err := client.CreateTerminal(ctx, connect.NewRequest(&dieterv1.CreateTerminalRequest{
		CardId: card.Msg.GetId(), Shell: "sh", WorkingDirectory: ".", Columns: 80, Rows: 24,
	}))
	expectedTerminalRoot, _ := filepath.EvalSymlinks(cardWorkspace.Msg.GetPath())
	if err != nil || terminalSession.Msg.GetCardId() != card.Msg.GetId() || terminalSession.Msg.GetWorkingDirectory() != expectedTerminalRoot {
		t.Fatalf("terminal=%#v err=%v", terminalSession, err)
	}
	if _, err := client.StartGitOperation(ctx, connect.NewRequest(&dieterv1.StartGitOperationRequest{
		CardId: card.Msg.GetId(), Kind: "commit", ExpectedRevision: set.Msg.GetRevision(),
		Parameters: map[string]string{"subject": "must wait", "validate": "false"},
	})); connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatalf("active workspace terminal did not block Git operation: %v", err)
	}
	if _, err := client.CloseTerminal(ctx, connect.NewRequest(&dieterv1.TerminalRef{TerminalId: terminalSession.Msg.GetId()})); err != nil {
		t.Fatal(err)
	}
	operation, err := client.StartGitOperation(ctx, connect.NewRequest(&dieterv1.StartGitOperationRequest{
		CardId: card.Msg.GetId(), Kind: "commit", ExpectedRevision: set.Msg.GetRevision(),
		Parameters: map[string]string{"subject": "conversation change", "validate": "false"},
	}))
	if err != nil {
		t.Fatal(err)
	}
	watch, err := client.WatchGitOperation(ctx, connect.NewRequest(&dieterv1.WatchGitOperationRequest{OperationId: operation.Msg.GetId(), HeartbeatMs: 1_000}))
	if err != nil {
		t.Fatal(err)
	}
	lastStatus, sawLog := "", false
	for watch.Receive() {
		lastStatus = watch.Msg().GetOperation().GetStatus()
		sawLog = sawLog || len(watch.Msg().GetLogs()) > 0
	}
	if watch.Err() != nil || lastStatus != model.GitOperationSucceeded || !sawLog {
		t.Fatalf("watch status=%s sawLog=%v err=%v", lastStatus, sawLog, watch.Err())
	}
	listed, err := client.ListProjectWorkspaces(ctx, connect.NewRequest(&dieterv1.ProjectRef{ProjectId: project.GetId()}))
	if err != nil || len(listed.Msg.GetWorkspaces()) != 2 {
		t.Fatalf("workspaces=%#v err=%v", listed, err)
	}
}

func realGitRepository(t *testing.T) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "repository")
	commands := [][]string{
		{"init", "-b", "main", root},
		{"-C", root, "config", "user.name", "Dieter Test"},
		{"-C", root, "config", "user.email", "dieter@example.test"},
	}
	for _, args := range commands {
		command := exec.Command("git", args...)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s: %v", args, output, err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "README.md"), []byte("base\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"-C", root, "add", "README.md"}, {"-C", root, "commit", "-m", "base"}} {
		command := exec.Command("git", args...)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s: %v", args, output, err)
		}
	}
	return root
}
