package api

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"google.golang.org/protobuf/types/known/emptypb"
)

// vaultTurnRunner holds each turn open so the test can act as its agent, then
// emits tool output that repeats a revealed secret.
type vaultTurnRunner struct {
	started chan harness.Request
	release chan string
}

func (r vaultTurnRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`)}); err != nil {
		return err
	}
	r.started <- request
	var output string
	select {
	case output = <-r.release:
	case <-ctx.Done():
		return ctx.Err()
	}
	payload, _ := json.Marshal(map[string]any{"type": "tool-output-available", "toolCallId": "tool_vault", "toolName": "exec_command", "output": map[string]any{"stdout": output, "exitCode": 0}})
	for _, chunk := range []string{
		`{"type":"tool-input-available","toolCallId":"tool_vault","toolName":"exec_command","input":{"command":"dieter vault get GitHub --reveal"}}`,
		string(payload),
		`{"type":"finish","finishReason":"stop"}`,
	} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	return nil
}

// vaultHeaders sends headers with the calls made in the returned context, as
// the gateway relay and a daemon agent turn do.
func withHeaders(ctx context.Context, headers map[string]string) context.Context {
	ctx, call := connect.NewClientContext(ctx)
	for name, value := range headers {
		call.RequestHeader().Set(name, value)
	}
	return ctx
}

func wantCode(t *testing.T, err error, code connect.Code, context string) {
	t.Helper()
	var connectErr *connect.Error
	if !errors.As(err, &connectErr) || connectErr.Code() != code {
		t.Fatalf("%s: err = %v, want %s", context, err, code)
	}
}

func startVaultTurn(t *testing.T, client dieterclient.ConnectClient, runner vaultTurnRunner, cardID string) harness.Request {
	t.Helper()
	if _, err := client.SendMessage(t.Context(), &dieterv1.SendMessageRequest{
		CardId: cardID, Provider: "mock", Model: "mock", Parts: []*dieterv1.MessagePart{{Type: "text", Text: "Log in"}},
	}); err != nil {
		t.Fatal(err)
	}
	select {
	case request := <-runner.started:
		return request
	case <-time.After(testkit.Budget(30 * time.Second)):
		t.Fatal("turn did not start")
	}
	return harness.Request{}
}

func waitForIdle(t *testing.T, data *store.Store, cardID string) {
	t.Helper()
	deadline := time.Now().Add(testkit.Budget(30 * time.Second))
	for time.Now().Before(deadline) {
		if card, err := data.Kanban.ResolveCard(cardID); err == nil && card.Runtime == "idle" {
			if _, err := data.Kanban.GlobalStateContext(t.Context()); err != nil {
				t.Fatal(err)
			}
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("turn did not finish")
}

func TestVaultAgentAccessFollowsConversationCreationAndRoute(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Vault", Path: testkit.CheckoutDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	allowed, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "With vault", Prompt: "Log in", Provider: "mock", Model: "mock", VaultAccess: true})
	if err != nil {
		t.Fatal(err)
	}
	denied, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Without vault", Prompt: "Log in", Provider: "mock", Model: "mock"})
	if err != nil {
		t.Fatal(err)
	}
	runner := vaultTurnRunner{started: make(chan harness.Request, 1), release: make(chan string, 1)}
	client, _ := newConnectTestClient(t, data, runner, testkit.MockCatalog())
	ctx := t.Context()

	// The operator creates the vault and an item.
	initialized, err := client.InitVault(ctx, &dieterv1.InitVaultRequest{Name: "test"})
	if err != nil || !strings.HasPrefix(initialized.GetRecoveryKey(), "DVR1-") || initialized.GetStatus().GetState() != "unlocked" {
		t.Fatalf("init = %v, %v", initialized, err)
	}
	const secret = "s3cret-value-123"
	if _, err = client.CreateVaultItem(ctx, &dieterv1.CreateVaultItemRequest{Name: "GitHub", Urls: []string{"https://github.com/login"}, Username: "octo", Password: secret, Totp: "JBSWY3DPEHPK3PXP"}); err != nil {
		t.Fatal(err)
	}

	// The gateway relay never carries decrypted content.
	relay := map[string]string{routeMetadata: "relay", operatorSubjectMetadata: "github:1"}
	_, err = client.ListVaultItems(withHeaders(ctx, relay), &dieterv1.ListVaultItemsRequest{})
	wantCode(t, err, connect.CodeFailedPrecondition, "relay list")
	if status, err := client.GetVaultStatus(withHeaders(ctx, relay), &emptypb.Empty{}); err != nil || status.GetCaller().GetRoute() != "relay" {
		t.Fatalf("relay status = %v, %v", status, err)
	}

	// An agent of a vault-enabled card is identified by its turn token.
	request := startVaultTurn(t, client, runner, allowed.ID)
	if request.Environment["DIETER_CARD_ID"] != allowed.ID || request.Environment["DIETER_HOME"] != data.Root || request.Environment["DIETER_TURN_TOKEN"] == "" {
		t.Fatalf("agent environment = %v", request.Environment)
	}
	if !strings.Contains(request.Instructions, "Account vault access") {
		t.Fatal("vault instructions missing for a vault-enabled card")
	}
	agent := map[string]string{turnTokenMetadata: request.Environment["DIETER_TURN_TOKEN"]}
	status, err := client.GetVaultStatus(withHeaders(ctx, agent), &emptypb.Empty{})
	if err != nil || status.GetCaller().GetKind() != "agent" || !status.GetCaller().GetVaultAccess() {
		t.Fatalf("agent status = %v, %v", status, err)
	}
	revealed, err := client.RevealVaultItem(withHeaders(ctx, agent), &dieterv1.RevealVaultItemRequest{Item: "github", Fields: []string{"password", "totp"}})
	if err != nil || revealed.GetValues()["password"] != secret || len(revealed.GetValues()["totp"]) != 6 {
		t.Fatalf("agent reveal = %v, %v", revealed, err)
	}
	_, err = client.RotateVault(withHeaders(ctx, agent), &dieterv1.RotateVaultRequest{})
	wantCode(t, err, connect.CodePermissionDenied, "agent rotate")
	_, err = client.ListVaultAudit(withHeaders(ctx, agent), &dieterv1.ListVaultAuditRequest{})
	wantCode(t, err, connect.CodePermissionDenied, "agent audit")
	created, err := client.CreateVaultItem(withHeaders(ctx, agent), &dieterv1.CreateVaultItemRequest{Name: "New service", GeneratePassword: true})
	if err != nil || !created.GetHasPassword() || created.GetUpdatedBy() != "agent:"+allowed.ID {
		t.Fatalf("agent create = %v, %v", created, err)
	}

	// Tool output that repeats the revealed secret is redacted in the transcript.
	runner.release <- "logged in with " + secret
	waitForIdle(t, data, allowed.ID)
	conversation, err := data.Conversations.Get(allowed.ID)
	if err != nil {
		t.Fatal(err)
	}
	transcript, _ := json.Marshal(conversation)
	if strings.Contains(string(transcript), secret) || !strings.Contains(string(transcript), "[redacted vault secret]") {
		t.Fatalf("transcript was not redacted: %s", transcript)
	}

	// The token stops working when its turn ends.
	_, err = client.ListVaultItems(withHeaders(ctx, agent), &dieterv1.ListVaultItemsRequest{})
	wantCode(t, err, connect.CodePermissionDenied, "finished turn token")

	// A card created without vault access is denied.
	request = startVaultTurn(t, client, runner, denied.ID)
	if strings.Contains(request.Instructions, "Account vault access") {
		t.Fatal("vault instructions leaked to a card without access")
	}
	other := map[string]string{turnTokenMetadata: request.Environment["DIETER_TURN_TOKEN"]}
	_, err = client.ListVaultItems(withHeaders(ctx, other), &dieterv1.ListVaultItemsRequest{})
	wantCode(t, err, connect.CodePermissionDenied, "card without vault access")
	status, err = client.GetVaultStatus(withHeaders(ctx, other), &emptypb.Empty{})
	if err != nil || status.GetCaller().GetVaultAccess() || status.GetVaultId() != "" || len(status.GetMembers()) != 0 {
		t.Fatalf("status without access = %v, %v", status, err)
	}
	runner.release <- "done"
	waitForIdle(t, data, denied.ID)

	// The audit names the agent and the denial without secret values.
	audit, err := client.ListVaultAudit(ctx, &dieterv1.ListVaultAuditRequest{Limit: 100})
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(audit)
	if strings.Contains(string(raw), secret) || !strings.Contains(string(raw), "agent:"+allowed.ID) || !strings.Contains(string(raw), "agent:"+denied.ID) || !strings.Contains(string(raw), `"outcome":"denied"`) {
		t.Fatalf("audit = %s", raw)
	}

	// URL matching includes subdomains.
	items, err := client.ListVaultItems(ctx, &dieterv1.ListVaultItemsRequest{Url: "https://gist.github.com/new"})
	if err != nil || len(items.GetItems()) != 1 || items.GetItems()[0].GetName() != "GitHub" {
		t.Fatalf("url match = %v, %v", items, err)
	}
}

func TestVaultAccessIsSetWhenChatIsCreated(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Vault", Path: testkit.CheckoutDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	client, _ := newConnectTestClient(t, data, newFakeRunner(), testkit.MockCatalog())
	chat, err := client.CreateChat(t.Context(), &dieterv1.CreateConversationRequest{ProjectId: project.ID, Title: "Vault chat", Prompt: "Hi", Provider: "mock", Model: "mock", WorkspaceMode: "project", VaultAccess: true, DeferStart: true})
	if err != nil || !chat.GetVaultAccess() {
		t.Fatalf("chat = %v, %v", chat, err)
	}
	stored, err := data.Kanban.ResolveCard(chat.GetId())
	if err != nil || !stored.VaultAccess {
		t.Fatalf("stored chat = %+v, %v", stored, err)
	}
}
