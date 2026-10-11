package api

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
)

func TestGitWatchPublishesTerminalStatusAfterLogCursorAlreadyAdvanced(t *testing.T) {
	t.Parallel()
	data, api, card := changesFixture(t)
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
	err = api.server.watchGitOperation(ctx, &dieterv1.WatchGitOperationRequest{OperationId: operation.ID, HeartbeatMs: 1000}, func(frame *dieterv1.GitOperationFrame) error {
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
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), testkit.Budget(30*time.Second))
	defer cancel()
	data := testkit.Store(t)
	client, _ := newConnectTestClient(t, data, newFakeRunner())
	repository := testkit.GitRepo(t)
	created, err := client.CreateProject(ctx, &dieterv1.CreateProjectRequest{
		Mode: "open", Path: repository, Name: "Workspace", BoardName: "Main", Workflow: model.WorkflowReview,
		BaseBranch: "main",
	})
	if err != nil {
		t.Fatal(err)
	}
	project, board := created.GetProject(), created.GetBoard()
	card, err := client.CreateCard(ctx, &dieterv1.CreateConversationRequest{
		ProjectId: project.GetId(), BoardId: board.GetId(), Lane: model.LaneTodo,
		Title: "Card workspace", Prompt: "work", DeferStart: true, WorkspaceMode: model.WorkspaceModeWorktree,
	})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := client.CreateChat(ctx, &dieterv1.CreateConversationRequest{
		ProjectId: project.GetId(), Title: "Chat workspace", Prompt: "work", DeferStart: true, WorkspaceMode: model.WorkspaceModeWorktree,
	})
	if err != nil {
		t.Fatal(err)
	}
	cardWorkspace, err := client.GetWorkspace(ctx, &dieterv1.ConversationRef{CardId: card.GetId()})
	if err != nil {
		t.Fatal(err)
	}
	chatWorkspace, err := client.GetWorkspace(ctx, &dieterv1.ConversationRef{CardId: chat.GetId()})
	if err != nil {
		t.Fatal(err)
	}
	if cardWorkspace.GetPath() == chatWorkspace.GetPath() || cardWorkspace.GetRevision() == "" || chatWorkspace.GetRevision() == "" {
		t.Fatalf("card=%#v chat=%#v", cardWorkspace, chatWorkspace)
	}
	document, err := client.ReadFile(ctx, &dieterv1.ReadFileRequest{CardId: card.GetId(), Path: "README.md"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.SaveFile(ctx, &dieterv1.SaveFileRequest{
		CardId: card.GetId(), Path: "README.md", Revision: document.GetRevision(), Content: "conversation scoped\n",
	}); err != nil {
		t.Fatal(err)
	}
	set, err := client.GetChangeset(ctx, &dieterv1.GetChangesetRequest{CardId: card.GetId()})
	if err != nil || len(set.GetFiles()) != 1 || set.GetRevision() == "" {
		t.Fatalf("changeset=%#v err=%v", set, err)
	}
	diff, err := client.GetFileDiff(ctx, &dieterv1.GetDiffRequest{
		CardId: card.GetId(), Path: "README.md", ExpectedRevision: set.GetRevision(),
	})
	if err != nil || !strings.Contains(diff.GetPatch(), "+conversation scoped") {
		t.Fatalf("diff=%#v err=%v", diff, err)
	}
	comment, err := client.AddChangeComment(ctx, &dieterv1.AddChangeCommentRequest{
		CardId: card.GetId(), Revision: set.GetRevision(), Path: "README.md", Side: "new", Line: 1, Body: "Looks good", Author: "Tester",
	})
	if err != nil || comment.GetBody() != "Looks good" {
		t.Fatalf("comment=%#v err=%v", comment, err)
	}
	terminalSession, err := client.CreateTerminal(ctx, &dieterv1.CreateTerminalRequest{
		CardId: card.GetId(), Shell: "sh", WorkingDirectory: ".", Columns: 80, Rows: 24,
	})
	expectedTerminalRoot, _ := filepath.EvalSymlinks(cardWorkspace.GetPath())
	if err != nil || terminalSession.GetCardId() != card.GetId() || terminalSession.GetWorkingDirectory() != expectedTerminalRoot {
		t.Fatalf("terminal=%#v err=%v", terminalSession, err)
	}
	if _, err := client.StartGitOperation(ctx, &dieterv1.StartGitOperationRequest{
		CardId: card.GetId(), Kind: "commit", ExpectedRevision: set.GetRevision(),
		Parameters: map[string]string{"subject": "must wait", "validate": "false"},
	}); connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatalf("active workspace terminal did not block Git operation: %v", err)
	}
	if _, err := client.CloseTerminal(ctx, &dieterv1.TerminalRef{TerminalId: terminalSession.GetId()}); err != nil {
		t.Fatal(err)
	}
	operation, err := client.StartGitOperation(ctx, &dieterv1.StartGitOperationRequest{
		CardId: card.GetId(), Kind: "commit", ExpectedRevision: set.GetRevision(),
		Parameters: map[string]string{"subject": "conversation change", "validate": "false", "stage_all": "true"},
	})
	if err != nil {
		t.Fatal(err)
	}
	watch, err := client.WatchGitOperation(ctx, &dieterv1.WatchGitOperationRequest{OperationId: operation.GetId(), HeartbeatMs: 1_000})
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
	listed, err := client.ListProjectWorkspaces(ctx, &dieterv1.ProjectRef{ProjectId: project.GetId()})
	if err != nil || len(listed.GetWorkspaces()) != 2 {
		t.Fatalf("workspaces=%#v err=%v", listed, err)
	}
}

func TestProjectCheckoutChangesAreProjectScopedAndMutable(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(context.Background(), testkit.Budget(30*time.Second))
	defer cancel()
	data := testkit.Store(t)
	client, _ := newConnectTestClient(t, data, newFakeRunner())
	repository := testkit.GitRepo(t)
	remote := filepath.Join(t.TempDir(), "remote.git")
	testkit.RunGit(t, "", "init", "--bare", remote)
	testkit.RunGit(t, repository, "remote", "add", "origin", remote)
	created, err := client.CreateProject(ctx, &dieterv1.CreateProjectRequest{
		Mode: "open", Path: repository, Name: "Project changes", BoardName: "Main", Workflow: model.WorkflowReview,
		BaseRemote: "origin", BaseBranch: "main",
	})
	if err != nil {
		t.Fatal(err)
	}
	project := created.GetProject()
	card, err := client.CreateChat(ctx, &dieterv1.CreateConversationRequest{
		ProjectId: project.GetId(), Title: "Shared checkout", Prompt: "work", DeferStart: true, WorkspaceMode: model.WorkspaceModeProject,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repository, "README.md"), []byte("project checkout\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := client.GetChangeset(ctx, &dieterv1.GetChangesetRequest{CardId: card.GetId()}); connect.CodeOf(err) != connect.CodeFailedPrecondition {
		t.Fatalf("project-mode card changes must redirect to project Changes: %v", err)
	}
	set, err := client.GetChangeset(ctx, &dieterv1.GetChangesetRequest{ProjectId: project.GetId()})
	if err != nil || set.GetProjectId() != project.GetId() || set.GetCardId() != "" || len(set.GetFiles()) != 1 || !set.GetFiles()[0].GetUnstaged() {
		t.Fatalf("project changeset=%#v err=%v", set, err)
	}
	operation, err := client.StartGitOperation(ctx, &dieterv1.StartGitOperationRequest{
		ProjectId: project.GetId(), Kind: "stage", ExpectedRevision: set.GetRevision(), Parameters: map[string]string{"path": "README.md"},
	})
	if err != nil {
		t.Fatal(err)
	}
	waitConnectGitOperation(t, ctx, client, operation.GetId())
	staged, err := client.GetChangeset(ctx, &dieterv1.GetChangesetRequest{ProjectId: project.GetId()})
	if err != nil || len(staged.GetFiles()) != 1 || !staged.GetFiles()[0].GetStaged() || staged.GetFiles()[0].GetUnstaged() {
		t.Fatalf("staged project changeset=%#v err=%v", staged, err)
	}
	diff, err := client.GetFileDiff(ctx, &dieterv1.GetDiffRequest{
		ProjectId: project.GetId(), Path: "README.md", ExpectedRevision: staged.GetRevision(), Section: "staged",
	})
	if err != nil || diff.GetProjectId() != project.GetId() || !strings.Contains(diff.GetPatch(), "+project checkout") {
		t.Fatalf("staged project diff=%#v err=%v", diff, err)
	}
	operation, err = client.StartGitOperation(ctx, &dieterv1.StartGitOperationRequest{
		ProjectId: project.GetId(), Kind: "commit", ExpectedRevision: staged.GetRevision(),
		Parameters: map[string]string{"subject": "project checkout change", "validate": "false"},
	})
	if err != nil {
		t.Fatal(err)
	}
	waitConnectGitOperation(t, ctx, client, operation.GetId())
	clean, err := client.GetChangeset(ctx, &dieterv1.GetChangesetRequest{ProjectId: project.GetId()})
	if err != nil || len(clean.GetFiles()) != 0 || clean.GetDirty() {
		t.Fatalf("project checkout was not clean after commit: %#v err=%v", clean, err)
	}
	operation, err = client.StartGitOperation(ctx, &dieterv1.StartGitOperationRequest{
		ProjectId: project.GetId(), Kind: "push",
	})
	if err != nil {
		t.Fatal(err)
	}
	waitConnectGitOperation(t, ctx, client, operation.GetId())
	localHead := testkit.RunGit(t, repository, "rev-parse", "HEAD")
	remoteHead := testkit.RunGit(t, "", "--git-dir="+remote, "rev-parse", "refs/heads/main")
	if localHead != remoteHead {
		t.Fatalf("project push did not update the configured remote: local=%s remote=%s", localHead, remoteHead)
	}
	for _, request := range []*dieterv1.StartGitOperationRequest{
		{ProjectId: project.GetId(), Kind: "update", Parameters: map[string]string{"fetch": "true", "validate": "false"}},
		{ProjectId: project.GetId(), Kind: "validate"},
	} {
		operation, err = client.StartGitOperation(ctx, request)
		if err != nil {
			t.Fatal(err)
		}
		waitConnectGitOperation(t, ctx, client, operation.GetId())
	}
}

func waitConnectGitOperation(t *testing.T, ctx context.Context, client dieterclient.ConnectClient, id string) *dieterv1.GitOperation {
	t.Helper()
	for {
		value, err := client.GetGitOperation(ctx, &dieterv1.GitOperationRef{OperationId: id})
		if err != nil {
			t.Fatal(err)
		}
		switch value.GetStatus() {
		case model.GitOperationSucceeded:
			return value
		case model.GitOperationFailed, model.GitOperationCanceled, model.GitOperationWaitingForResolution:
			t.Fatalf("Git operation ended as %s: %s", value.GetStatus(), value.GetError())
		}
		select {
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-time.After(10 * time.Millisecond):
		}
	}
}

func TestConversationInputRequiresPerConversationWorkspaceMode(t *testing.T) {
	t.Parallel()
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
