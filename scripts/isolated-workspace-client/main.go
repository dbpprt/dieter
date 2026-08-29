// Command isolated-workspace-client exercises the conversation workspace API
// through an already-running isolated gateway. It is intentionally separate
// from production clients so end-to-end tests never need real credentials.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

func main() {
	address := flag.String("addr", "", "isolated gateway address")
	token := flag.String("token", "", "isolated gateway session token")
	daemonID := flag.String("daemon", "", "isolated daemon ID")
	projectID := flag.String("project", "", "isolated project ID")
	flag.Parse()
	if *address == "" || *token == "" || *daemonID == "" || *projectID == "" {
		fmt.Fprintln(os.Stderr, "addr, token, daemon, and project are required")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	ctx = metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+*token, "x-dieter-daemon-id", *daemonID)
	connection, err := grpc.NewClient(*address, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fail(err)
	}
	defer connection.Close()
	client := dieterv1.NewDieterServiceClient(connection)
	card, err := client.CreateChat(ctx, &dieterv1.CreateConversationRequest{
		ProjectId: *projectID, Title: "Executable workspace E2E", Prompt: "exercise workspace", DeferStart: true,
		WorkspaceMode: "worktree",
	})
	if err != nil {
		fail(err)
	}
	workspace, err := client.GetWorkspace(ctx, &dieterv1.ConversationRef{CardId: card.GetId()})
	if err != nil {
		fail(err)
	}
	if workspace.GetMode() != "worktree" || workspace.GetRevision() == "" {
		fail(fmt.Errorf("unexpected workspace: %#v", workspace))
	}
	document, err := client.ReadFile(ctx, &dieterv1.ReadFileRequest{CardId: card.GetId(), Path: "README.md"})
	if status.Code(err) == codes.NotFound {
		if _, createErr := client.CreateFile(ctx, &dieterv1.CreateFileRequest{
			CardId: card.GetId(), Path: "README.md", Kind: "file", Content: "initial\n",
		}); createErr != nil {
			fail(createErr)
		}
		document, err = client.ReadFile(ctx, &dieterv1.ReadFileRequest{CardId: card.GetId(), Path: "README.md"})
	}
	if err != nil {
		fail(err)
	}
	if _, err := client.SaveFile(ctx, &dieterv1.SaveFileRequest{
		CardId: card.GetId(), Path: "README.md", Revision: document.GetRevision(), Content: "executable gateway workspace\n",
	}); err != nil {
		fail(err)
	}
	changes, err := client.GetChangeset(ctx, &dieterv1.GetChangesetRequest{CardId: card.GetId()})
	if err != nil {
		fail(err)
	}
	if len(changes.GetFiles()) != 1 {
		fail(fmt.Errorf("changeset has %d files", len(changes.GetFiles())))
	}
	operation, err := client.StartGitOperation(ctx, &dieterv1.StartGitOperationRequest{
		CardId: card.GetId(), Kind: "commit", ExpectedRevision: changes.GetRevision(),
		Parameters: map[string]string{"subject": "executable gateway workspace", "validate": "false"},
	})
	if err != nil {
		fail(err)
	}
	watch, err := client.WatchGitOperation(ctx, &dieterv1.WatchGitOperationRequest{OperationId: operation.GetId(), HeartbeatMs: 1_000})
	if err != nil {
		fail(err)
	}
	statusValue := ""
	for {
		frame, receiveErr := watch.Recv()
		if receiveErr == io.EOF {
			break
		}
		if receiveErr != nil {
			fail(receiveErr)
		}
		statusValue = frame.GetOperation().GetStatus()
	}
	if statusValue != "succeeded" {
		fail(fmt.Errorf("Git operation ended as %q", statusValue))
	}
	result := map[string]any{
		"status": "ok", "cardId": card.GetId(), "workspacePath": workspace.GetPath(),
		"revision": changes.GetRevision(), "operationId": operation.GetId(),
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "error:", err)
	os.Exit(1)
}
