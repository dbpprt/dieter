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
	"github.com/dbpprt/dieter/internal/gen/dieter/v1/dieterv1connect"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
)

func TestGitWatchPublishesTerminalStatusAfterLogCursorAlreadyAdvanced(t *testing.T) {
	data, api, card := syncRecoveryFixture(t)
	operation, err := data.CreateGitOperation(card.ID, "commit", "fixture")
	if err != nil {
		t.Fatal(err)
	}
	sequence, err := data.AppendGitOperationLog(operation.ID, "commit complete")
	if err != nil {
		t.Fatal(err)
	}
	operation.Sequence = sequence
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	var frames []*dieterv1.GitOperationFrame
	err = api.watchGitOperation(ctx, &dieterv1.WatchGitOperationRequest{OperationId: operation.ID, HeartbeatMs: 1000}, func(frame *dieterv1.GitOperationFrame) error {
		frames = append(frames, frame)
		if len(frames) == 1 {
			// Status publication can follow the last log without a newer sequence.
			operation.Status = model.GitOperationSucceeded
			_, err := data.SaveGitOperation(operation)
			return err
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	last := frames[len(frames)-1]
	if last.Heartbeat || last.GetOperation().GetStatus() != model.GitOperationSucceeded {
		t.Fatalf("EOF without final applied status: %+v", last)
	}
}

func TestConversationWorkspaceConnectEndToEndForCardAndChat(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	client, _ := newConnectTestClient(t, data, &fakeRunner{})
	repository := realGitRepository(t)
	created, err := client.CreateProject(ctx, connect.NewRequest(&dieterv1.CreateProjectRequest{
		Mode: "open", Path: repository, Name: "Workspace", BoardName: "Main", Workflow: model.WorkflowReview,
		BaseBranch: "main",
	}))
	if err != nil {
		t.Fatal(err)
	}
	project, board := created.Msg.GetProject(), created.Msg.GetBoard()
	card, err := client.CreateCard(ctx, connect.NewRequest(&dieterv1.CreateConversationRequest{
		ProjectId: project.GetId(), BoardId: board.GetId(), Lane: model.LaneTodo,
		Title: "Card workspace", Prompt: "work", DeferStart: true, WorkspaceMode: model.WorkspaceModeWorktree,
	}))
	if err != nil {
		t.Fatal(err)
	}
	chat, err := client.CreateChat(ctx, connect.NewRequest(&dieterv1.CreateConversationRequest{
		ProjectId: project.GetId(), Title: "Chat workspace", Prompt: "work", DeferStart: true, WorkspaceMode: model.WorkspaceModeWorktree,
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
		Parameters: map[string]string{"subject": "conversation change", "validate": "false", "stage_all": "true"},
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

func TestProjectCheckoutChangesAreProjectScopedAndMutable(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	data := store.New(filepath.Join(t.TempDir(), "dieter-home"))
	client, _ := newConnectTestClient(t, data, &fakeRunner{})
	repository := realGitRepository(t)
	remote := filepath.Join(t.TempDir(), "remote.git")
	runServerGit(t, "", "init", "--bare", remote)
	runServerGit(t, repository, "remote", "add", "origin", remote)
	created, err := client.CreateProject(ctx, connect.NewRequest(&dieterv1.CreateProjectRequest{
		Mode: "open", Path: repository, Name: "Project changes", BoardName: "Main", Workflow: model.WorkflowReview,
		BaseRemote: "origin", BaseBranch: "main",
	}))
	if err != nil {
		t.Fatal(err)
	}
	project := created.Msg.GetProject()
	card, err := client.CreateChat(ctx, connect.NewRequest(&dieterv1.CreateConversationRequest{
		ProjectId: project.GetId(), Title: "Shared checkout", Prompt: "work", DeferStart: true, WorkspaceMode: model.WorkspaceModeProject,
	}))
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repository, "README.md"), []byte("project checkout\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := client.GetChangeset(ctx, connect.NewRequest(&dieterv1.GetChangesetRequest{CardId: card.Msg.GetId()})); connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatalf("project-mode card changes must redirect to project Changes: %v", err)
	}
	set, err := client.GetChangeset(ctx, connect.NewRequest(&dieterv1.GetChangesetRequest{ProjectId: project.GetId()}))
	if err != nil || set.Msg.GetProjectId() != project.GetId() || set.Msg.GetCardId() != "" || len(set.Msg.GetFiles()) != 1 || !set.Msg.GetFiles()[0].GetUnstaged() {
		t.Fatalf("project changeset=%#v err=%v", set, err)
	}
	operation, err := client.StartGitOperation(ctx, connect.NewRequest(&dieterv1.StartGitOperationRequest{
		ProjectId: project.GetId(), Kind: "stage", ExpectedRevision: set.Msg.GetRevision(), Parameters: map[string]string{"path": "README.md"},
	}))
	if err != nil {
		t.Fatal(err)
	}
	waitConnectGitOperation(t, ctx, client, operation.Msg.GetId())
	staged, err := client.GetChangeset(ctx, connect.NewRequest(&dieterv1.GetChangesetRequest{ProjectId: project.GetId()}))
	if err != nil || len(staged.Msg.GetFiles()) != 1 || !staged.Msg.GetFiles()[0].GetStaged() || staged.Msg.GetFiles()[0].GetUnstaged() {
		t.Fatalf("staged project changeset=%#v err=%v", staged, err)
	}
	diff, err := client.GetFileDiff(ctx, connect.NewRequest(&dieterv1.GetDiffRequest{
		ProjectId: project.GetId(), Path: "README.md", ExpectedRevision: staged.Msg.GetRevision(), Section: "staged",
	}))
	if err != nil || diff.Msg.GetProjectId() != project.GetId() || !strings.Contains(diff.Msg.GetPatch(), "+project checkout") {
		t.Fatalf("staged project diff=%#v err=%v", diff, err)
	}
	operation, err = client.StartGitOperation(ctx, connect.NewRequest(&dieterv1.StartGitOperationRequest{
		ProjectId: project.GetId(), Kind: "commit", ExpectedRevision: staged.Msg.GetRevision(),
		Parameters: map[string]string{"subject": "project checkout change", "validate": "false"},
	}))
	if err != nil {
		t.Fatal(err)
	}
	waitConnectGitOperation(t, ctx, client, operation.Msg.GetId())
	clean, err := client.GetChangeset(ctx, connect.NewRequest(&dieterv1.GetChangesetRequest{ProjectId: project.GetId()}))
	if err != nil || len(clean.Msg.GetFiles()) != 0 || clean.Msg.GetDirty() {
		t.Fatalf("project checkout was not clean after commit: %#v err=%v", clean, err)
	}
	operation, err = client.StartGitOperation(ctx, connect.NewRequest(&dieterv1.StartGitOperationRequest{
		ProjectId: project.GetId(), Kind: "push",
	}))
	if err != nil {
		t.Fatal(err)
	}
	waitConnectGitOperation(t, ctx, client, operation.Msg.GetId())
	localHead := runServerGit(t, repository, "rev-parse", "HEAD")
	remoteHead := runServerGit(t, "", "--git-dir="+remote, "rev-parse", "refs/heads/main")
	if localHead != remoteHead {
		t.Fatalf("project push did not update the configured remote: local=%s remote=%s", localHead, remoteHead)
	}
	for _, request := range []*dieterv1.StartGitOperationRequest{
		{ProjectId: project.GetId(), Kind: "update", Parameters: map[string]string{"fetch": "true", "validate": "false"}},
		{ProjectId: project.GetId(), Kind: "validate"},
	} {
		operation, err = client.StartGitOperation(ctx, connect.NewRequest(request))
		if err != nil {
			t.Fatal(err)
		}
		waitConnectGitOperation(t, ctx, client, operation.Msg.GetId())
	}
}

func waitConnectGitOperation(t *testing.T, ctx context.Context, client dieterv1connect.DieterServiceClient, id string) *dieterv1.GitOperation {
	t.Helper()
	for {
		value, err := client.GetGitOperation(ctx, connect.NewRequest(&dieterv1.GitOperationRef{OperationId: id}))
		if err != nil {
			t.Fatal(err)
		}
		switch value.Msg.GetStatus() {
		case model.GitOperationSucceeded:
			return value.Msg
		case model.GitOperationFailed, model.GitOperationCanceled, model.GitOperationWaitingForResolution:
			t.Fatalf("Git operation ended as %s: %s", value.Msg.GetStatus(), value.Msg.GetError())
		}
		select {
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-time.After(10 * time.Millisecond):
		}
	}
}

func TestConversationInputRequiresPerConversationWorkspaceMode(t *testing.T) {
	_, err := conversationInput(&dieterv1.CreateConversationRequest{Title: "Missing workspace"})
	if err == nil || !strings.Contains(err.Error(), "workspace mode must be selected") {
		t.Fatalf("missing workspace mode error=%v", err)
	}

	for wire, want := range map[string]string{
		"WORKTREE": model.WorkspaceModeWorktree,
		"PROJECT":  model.WorkspaceModeProject,
	} {
		input, err := conversationInput(&dieterv1.CreateConversationRequest{Title: "Explicit workspace", WorkspaceMode: wire})
		if err != nil || input.WorkspaceMode != want {
			t.Fatalf("workspace %q input=%#v err=%v", wire, input, err)
		}
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

func runServerGit(t *testing.T, directory string, args ...string) string {
	t.Helper()
	command := exec.Command("git", args...)
	command.Dir = directory
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %s: %v", args, output, err)
	}
	return strings.TrimSpace(string(output))
}
