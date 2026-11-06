package api

import (
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/mail"
	"github.com/dbpprt/dieter/internal/store/schedules"
	"github.com/dbpprt/dieter/internal/testkit"
	"google.golang.org/protobuf/proto"
)

func mailFixture(t *testing.T, data *store.Store) (model.Project, model.Board) {
	t.Helper()
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Mail", Path: testkit.CheckoutDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	return project, board
}

func mailCard(t *testing.T, data *store.Store, project model.Project, board model.Board, title string, vault, mailAccess bool) model.Card {
	t.Helper()
	card, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: title, Prompt: "Report", Provider: "mock", Model: "mock", VaultAccess: vault, MailAccess: mailAccess})
	if err != nil {
		t.Fatal(err)
	}
	return card
}

func turnHeaders(request harness.Request) map[string]string {
	return map[string]string{turnTokenMetadata: request.Environment["DIETER_TURN_TOKEN"]}
}

// turnID reads the turn of a token (dtt1:CARD:TURN:MAC).
func turnID(t *testing.T, request harness.Request) string {
	t.Helper()
	parts := strings.Split(request.Environment["DIETER_TURN_TOKEN"], ":")
	if len(parts) != 4 {
		t.Fatalf("turn token = %q", request.Environment["DIETER_TURN_TOKEN"])
	}
	return parts[2]
}

func TestMailAgentsSendOnlyWithAccessAndNeverRead(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	project, board := mailFixture(t, data)
	allowed := mailCard(t, data, project, board, "Nightly audit", true, true)
	denied := mailCard(t, data, project, board, "No mail", false, false)
	runner := vaultTurnRunner{started: make(chan harness.Request, 1), release: make(chan string, 1)}
	client, _ := newConnectTestClient(t, data, runner, testkit.MockCatalog())
	ctx := t.Context()

	// The local operator sends with a label; a remote device is named by its
	// device ID. A turn token from a remote caller is never trusted.
	local, err := client.SendMail(ctx, &dieterv1.SendMailRequest{Subject: "Backup done", Body: "All **good**.", From: "backup.sh"})
	if err != nil || local.GetSender().GetKind() != dieterv1.MailSenderKind_MAIL_SENDER_KIND_OPERATOR || local.GetSender().GetLabel() != "backup.sh" || local.GetSender().GetDeviceId() != "" || local.GetPreview() != "All good." {
		t.Fatalf("local operator send = %v, %v", local, err)
	}
	remote := map[string]string{operatorSubjectMetadata: "github:1", deviceIDMetadata: "dv_remote", turnTokenMetadata: "forged"}
	fromDevice, err := client.SendMail(withHeaders(ctx, remote), &dieterv1.SendMailRequest{Subject: "From my phone", Body: "Hi", Importance: dieterv1.MailImportance_MAIL_IMPORTANCE_HIGH})
	if err != nil || fromDevice.GetSender().GetKind() != dieterv1.MailSenderKind_MAIL_SENDER_KIND_OPERATOR || fromDevice.GetSender().GetDeviceId() != "dv_remote" || fromDevice.GetImportance() != dieterv1.MailImportance_MAIL_IMPORTANCE_HIGH {
		t.Fatalf("remote device send = %v, %v", fromDevice, err)
	}
	_, err = client.SendMail(withHeaders(ctx, map[string]string{turnTokenMetadata: "dtt1:" + allowed.ID + ":turn:forged"}), &dieterv1.SendMailRequest{Subject: "Forged", Body: "x"})
	wantCode(t, err, connect.CodePermissionDenied, "forged token")

	// The vault is set up so the agent can reveal a secret.
	if _, err := client.InitVault(ctx, &dieterv1.InitVaultRequest{Name: "test"}); err != nil {
		t.Fatal(err)
	}
	const secret = "hunter2-mail-secret"
	if _, err := client.CreateVaultItem(ctx, &dieterv1.CreateVaultItemRequest{Name: "Database", Password: secret}); err != nil {
		t.Fatal(err)
	}

	request := startVaultTurn(t, client, runner, allowed.ID)
	if !strings.Contains(request.Instructions, "## Mail to the user") || !strings.Contains(request.Instructions, " mail send --subject") {
		t.Fatal("mail instructions missing for a conversation with mail access")
	}
	agent := withHeaders(ctx, turnHeaders(request))
	sent, err := client.SendMail(agent, &dieterv1.SendMailRequest{Subject: "Audit: 3 critical", Body: "## Summary\n\nThree advisories.", OperationId: "audit-1"})
	if err != nil {
		t.Fatal(err)
	}
	sender := sent.GetSender()
	if sender.GetKind() != dieterv1.MailSenderKind_MAIL_SENDER_KIND_AGENT || sender.GetCardId() != allowed.ID || sender.GetTurnId() != turnID(t, request) ||
		sender.GetScope() != "card" || sender.GetTitle() != "Nightly audit" || sender.GetProjectId() != project.ID || sender.GetProjectName() != "Mail" ||
		sender.GetCheckoutId() != allowed.CheckoutID || sender.GetHarness() != "mock" || sender.GetModel() != "mock" || sender.GetLabel() != "" {
		t.Fatalf("agent sender = %v", sender)
	}
	again, err := client.SendMail(agent, &dieterv1.SendMailRequest{Subject: "Audit: 3 critical", Body: "different", OperationId: "audit-1"})
	if err != nil || again.GetId() != sent.GetId() {
		t.Fatalf("retried send = %v, %v; want %s", again, err, sent.GetId())
	}
	_, err = client.SendMail(agent, &dieterv1.SendMailRequest{Subject: "Named", Body: "x", From: "someone else"})
	wantCode(t, err, connect.CodeInvalidArgument, "agent from")

	// A secret revealed to the turn never reaches the mailbox.
	if _, err := client.RevealVaultItem(agent, &dieterv1.RevealVaultItemRequest{Item: "Database"}); err != nil {
		t.Fatal(err)
	}
	leaked, err := client.SendMail(agent, &dieterv1.SendMailRequest{Subject: "Password " + secret, Body: "The password is " + secret + ".\n\n```json\n{\"password\": \"" + secret + "\"}\n```"})
	if err != nil {
		t.Fatal(err)
	}
	stored, err := client.GetMail(ctx, &dieterv1.MailRef{Id: leaked.GetId()})
	if err != nil {
		t.Fatal(err)
	}
	if raw, _ := proto.Marshal(stored); strings.Contains(string(raw), secret) || !strings.Contains(stored.GetBody(), "[redacted vault secret]") ||
		stored.GetHeader().GetSubject() != "Password [redacted vault secret]" || stored.GetHeader().GetPreview() != "The password is [redacted vault secret]." {
		t.Fatalf("mail was not redacted: %v", stored)
	}

	// Agents may only send.
	_, err = client.ListMail(agent, &dieterv1.ListMailRequest{})
	wantCode(t, err, connect.CodePermissionDenied, "agent list")
	if !strings.Contains(err.Error(), "agents can send mail but not read it") {
		t.Fatalf("agent list error = %v", err)
	}
	_, err = client.GetMail(agent, &dieterv1.MailRef{Id: sent.GetId()})
	wantCode(t, err, connect.CodePermissionDenied, "agent get")
	_, err = client.UpdateMail(agent, &dieterv1.UpdateMailRequest{Ids: []string{sent.GetId()}, Read: proto.Bool(true)})
	wantCode(t, err, connect.CodePermissionDenied, "agent update")
	_, err = client.DeleteMail(agent, &dieterv1.DeleteMailRequest{Ids: []string{sent.GetId()}})
	wantCode(t, err, connect.CodePermissionDenied, "agent delete")
	_, err = client.ListMail(withHeaders(ctx, remote), &dieterv1.ListMailRequest{})
	wantCode(t, err, connect.CodePermissionDenied, "remote caller with a token")

	// The token stops working when its turn ends.
	runner.release <- "done"
	waitForIdle(t, data, allowed.ID)
	_, err = client.SendMail(agent, &dieterv1.SendMailRequest{Subject: "Late", Body: "x"})
	wantCode(t, err, connect.CodePermissionDenied, "finished turn token")

	// A conversation created without mail access is told how to get it.
	request = startVaultTurn(t, client, runner, denied.ID)
	if strings.Contains(request.Instructions, "Mail to the user") {
		t.Fatal("mail instructions leaked to a conversation without access")
	}
	_, err = client.SendMail(withHeaders(ctx, turnHeaders(request)), &dieterv1.SendMailRequest{Subject: "Nope", Body: "x"})
	wantCode(t, err, connect.CodePermissionDenied, "conversation without mail access")
	if !strings.Contains(err.Error(), "created without mail access; the user can create one with --mail") {
		t.Fatalf("denial = %v", err)
	}
	runner.release <- "done"
	waitForIdle(t, data, denied.ID)

	// The operator reads and organizes everything.
	page, err := client.ListMail(ctx, &dieterv1.ListMailRequest{})
	if err != nil || len(page.GetMessages()) != 4 || page.GetMessages()[0].GetId() != leaked.GetId() {
		t.Fatalf("operator list = %v, %v", page, err)
	}
	updated, err := client.UpdateMail(ctx, &dieterv1.UpdateMailRequest{Ids: []string{sent.GetId()}, Read: proto.Bool(true), Flagged: proto.Bool(true), Folder: dieterv1.MailFolder_MAIL_FOLDER_ARCHIVE})
	if err != nil || len(updated.GetMessages()) != 1 || !updated.GetMessages()[0].GetRead() || !updated.GetMessages()[0].GetFlagged() || updated.GetMessages()[0].GetFolder() != dieterv1.MailFolder_MAIL_FOLDER_ARCHIVE {
		t.Fatalf("update = %v, %v", updated, err)
	}
	flagged, err := client.ListMail(withHeaders(ctx, map[string]string{operatorSubjectMetadata: "github:1"}), &dieterv1.ListMailRequest{FlaggedOnly: true})
	if err != nil || len(flagged.GetMessages()) != 1 || flagged.GetMessages()[0].GetId() != sent.GetId() {
		t.Fatalf("remote flagged list = %v, %v", flagged, err)
	}
	deleted, err := client.DeleteMail(ctx, &dieterv1.DeleteMailRequest{Ids: []string{local.GetId(), "ml_unknown"}})
	if err != nil || !slices.Equal(deleted.GetDeletedIds(), []string{local.GetId()}) {
		t.Fatalf("delete = %v, %v", deleted, err)
	}
	_, err = client.GetMail(ctx, &dieterv1.MailRef{Id: local.GetId()})
	wantCode(t, err, connect.CodeNotFound, "deleted message")
	_, err = client.ListMail(ctx, &dieterv1.ListMailRequest{Limit: model.MailMaxPageSize + 1})
	wantCode(t, err, connect.CodeInvalidArgument, "page too large")
	_, err = client.SendMail(ctx, &dieterv1.SendMailRequest{Subject: "Big", Body: strings.Repeat("x\n", model.MailMaxBodyLines+1)})
	wantCode(t, err, connect.CodeInvalidArgument, "too many lines")
}

func TestMailRateBoundsHoldAcrossARestart(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	project, board := mailFixture(t, data)
	card := mailCard(t, data, project, board, "Chatty", false, true)
	runner := vaultTurnRunner{started: make(chan harness.Request, 1), release: make(chan string, 1)}
	client, _ := newConnectTestClient(t, data, runner, testkit.MockCatalog())
	ctx := t.Context()
	sender := func(turn string) model.MailSender {
		return model.MailSender{Kind: model.MailSenderAgent, CardID: card.ID, TurnID: turn}
	}
	seed := func(store *store.Store, count int, turn func(int) string) {
		t.Helper()
		for index := range count {
			if _, _, err := store.Mail.Send(mail.Draft{Sender: sender(turn(index)), Subject: fmt.Sprint("Seeded ", index), Body: "x"}); err != nil {
				t.Fatal(err)
			}
		}
	}

	request := startVaultTurn(t, client, runner, card.ID)
	current := turnID(t, request)
	seed(data, model.MailMaxPerTurn-1, func(int) string { return current })
	agent := withHeaders(ctx, turnHeaders(request))
	if _, err := client.SendMail(agent, &dieterv1.SendMailRequest{Subject: "Tenth", Body: "x"}); err != nil {
		t.Fatal(err)
	}
	_, err := client.SendMail(agent, &dieterv1.SendMailRequest{Subject: "Eleventh", Body: "x"})
	wantCode(t, err, connect.CodeResourceExhausted, "eleventh in a turn")
	runner.release <- "done"
	waitForIdle(t, data, card.ID)
	// Earlier turns, ten each, bring the conversation to 49 in a day.
	seed(data, model.MailMaxPerConversation-model.MailMaxPerTurn-1, func(index int) string { return fmt.Sprint("turn_earlier_", index/model.MailMaxPerTurn) })

	// A restarted daemon counts the stored messages.
	reopened := store.New(data.Root)
	if err := reopened.Ensure(); err != nil {
		t.Fatal(err)
	}
	restartedRunner := vaultTurnRunner{started: make(chan harness.Request, 1), release: make(chan string, 1)}
	restarted, _ := newConnectTestClient(t, reopened, restartedRunner, testkit.MockCatalog())
	request = startVaultTurn(t, restarted, restartedRunner, card.ID)
	agent = withHeaders(ctx, turnHeaders(request))
	if _, err := restarted.SendMail(agent, &dieterv1.SendMailRequest{Subject: "Fiftieth", Body: "x"}); err != nil {
		t.Fatal(err)
	}
	_, err = restarted.SendMail(agent, &dieterv1.SendMailRequest{Subject: "Fifty-first", Body: "x"})
	wantCode(t, err, connect.CodeResourceExhausted, "51st in a day after a restart")
	if !strings.Contains(err.Error(), "50") {
		t.Fatalf("the refusal does not name the bound: %v", err)
	}
	restartedRunner.release <- "done"
	waitForIdle(t, reopened, card.ID)
}

func TestMailAccessCannotBeEscalatedByAnAgent(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	project, board := mailFixture(t, data)
	without := mailCard(t, data, project, board, "Without mail", false, false)
	with := mailCard(t, data, project, board, "With mail", false, true)
	runner := vaultTurnRunner{started: make(chan harness.Request, 1), release: make(chan string, 1)}
	client, _ := newConnectTestClient(t, data, runner, testkit.MockCatalog())
	ctx := t.Context()
	conversation := func(title string, mailAccess bool) *dieterv1.CreateConversationRequest {
		return &dieterv1.CreateConversationRequest{ProjectId: project.ID, BoardId: board.ID, Title: title, Prompt: "Work", Provider: "mock", Model: "mock", WorkspaceMode: "project", DeferStart: true, MailAccess: mailAccess}
	}
	draft := func(name string, mailAccess bool) *dieterv1.ScheduleDraft {
		return &dieterv1.ScheduleDraft{ProjectId: project.ID, BoardId: board.ID, Name: name, Cron: "0 3 * * *", Timezone: "UTC", Action: "draft", TitleTemplate: name, PromptTemplate: "Work", Provider: "mock", Model: "mock", WorkspaceMode: "project", OpenCardPolicy: "skip_if_open", MisfirePolicy: "latest", MailAccess: mailAccess}
	}
	const denial = "a conversation without mail access cannot grant it"
	operatorSchedule, err := client.CreateSchedule(ctx, &dieterv1.SaveScheduleRequest{Schedule: draft("Operator schedule", false)})
	if err != nil {
		t.Fatal(err)
	}

	request := startVaultTurn(t, client, runner, without.ID)
	agent := withHeaders(ctx, turnHeaders(request))
	_, err = client.CreateCard(agent, conversation("Escalated card", true))
	wantCode(t, err, connect.CodePermissionDenied, "agent card with mail")
	if !strings.Contains(err.Error(), denial) {
		t.Fatalf("denial = %v", err)
	}
	chat := conversation("Escalated chat", true)
	chat.BoardId = ""
	_, err = client.CreateChat(agent, chat)
	wantCode(t, err, connect.CodePermissionDenied, "agent chat with mail")
	_, err = client.CreateSchedule(agent, &dieterv1.SaveScheduleRequest{Schedule: draft("Escalated schedule", true)})
	wantCode(t, err, connect.CodePermissionDenied, "agent schedule with mail")
	_, err = client.UpdateSchedule(agent, &dieterv1.SaveScheduleRequest{ScheduleId: operatorSchedule.GetId(), Schedule: draft("Operator schedule", true)})
	wantCode(t, err, connect.CodePermissionDenied, "agent turns schedule mail on")
	if plain, err := client.CreateCard(agent, conversation("Plain card", false)); err != nil || plain.GetMailAccess() {
		t.Fatalf("agent card without mail = %v, %v", plain, err)
	}
	// Once the user turned it on, an agent may keep it while editing.
	if _, err := client.UpdateSchedule(ctx, &dieterv1.SaveScheduleRequest{ScheduleId: operatorSchedule.GetId(), Schedule: draft("Operator schedule", true)}); err != nil {
		t.Fatal(err)
	}
	if kept, err := client.UpdateSchedule(agent, &dieterv1.SaveScheduleRequest{ScheduleId: operatorSchedule.GetId(), Schedule: draft("Renamed by agent", true)}); err != nil || !kept.GetMailAccess() {
		t.Fatalf("agent kept mail = %v, %v", kept, err)
	}
	runner.release <- "done"
	waitForIdle(t, data, without.ID)

	// An agent with mail access may pass it on.
	request = startVaultTurn(t, client, runner, with.ID)
	agent = withHeaders(ctx, turnHeaders(request))
	granted, err := client.CreateCard(agent, conversation("Granted card", true))
	if err != nil || !granted.GetMailAccess() {
		t.Fatalf("agent with mail = %v, %v", granted, err)
	}
	if schedule, err := client.CreateSchedule(agent, &dieterv1.SaveScheduleRequest{Schedule: draft("Granted schedule", true)}); err != nil || !schedule.GetMailAccess() {
		t.Fatalf("agent schedule with mail = %v, %v", schedule, err)
	}
	runner.release <- "done"
	waitForIdle(t, data, with.ID)

	// People always may: the local CLI and remote devices.
	chat = conversation("Operator chat", true)
	chat.BoardId = ""
	created, err := client.CreateChat(ctx, chat)
	if err != nil || !created.GetMailAccess() {
		t.Fatalf("operator chat = %v, %v", created, err)
	}
	if stored, err := data.Kanban.ResolveCard(created.GetId()); err != nil || !stored.MailAccess {
		t.Fatalf("stored chat = %+v, %v", stored, err)
	}
	remote := withHeaders(ctx, map[string]string{operatorSubjectMetadata: "github:1", deviceIDMetadata: "dv_remote", turnTokenMetadata: "forged"})
	if card, err := client.CreateCard(remote, conversation("Remote card", true)); err != nil || !card.GetMailAccess() {
		t.Fatalf("remote card = %v, %v", card, err)
	}
	// A fork starts without it, like vault access.
	if forked, err := client.ForkChat(ctx, &dieterv1.ForkChatRequest{SourceCardId: with.ID, Title: "Fork"}); err != nil || forked.GetMailAccess() {
		t.Fatalf("fork = %v, %v", forked, err)
	}
}

func TestMailSenderNamesTheSchedule(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	project, board := mailFixture(t, data)
	schedule, err := data.Schedules.Create(schedules.Input{Project: project.ID, Board: board.ID, Name: "Nightly dependency audit", Cron: "0 3 * * *", Timezone: "UTC", Action: "draft", TitleTemplate: "Audit", PromptTemplate: "Audit", Provider: "mock", Model: "mock", WorkspaceMode: "project", MailAccess: true})
	if err != nil {
		t.Fatal(err)
	}
	card, err := data.Kanban.CreateCard(kanban.CreateCardInput{Project: project.ID, Board: board.ID, Lane: model.LaneTodo, Title: "Audit 2026-10-25", Prompt: "Audit", Provider: "mock", Model: "mock", MailAccess: true,
		Origin: &model.CardOrigin{Kind: "schedule", ScheduleID: schedule.ID, ScheduleRunID: "run_1", ScheduledFor: "2026-10-25T03:00:00Z"}})
	if err != nil {
		t.Fatal(err)
	}
	server := NewWithRunner(data, nil, newFakeRunner())
	sender := server.mailSender(card, "turn_1")
	if sender.ScheduleID != schedule.ID || sender.ScheduleName != "Nightly dependency audit" || sender.Title != "Audit 2026-10-25" || sender.TurnID != "turn_1" {
		t.Fatalf("sender = %+v", sender)
	}
}

func TestChangesCarryMailHeadersAndRemovals(t *testing.T) {
	t.Parallel()
	data, api, _ := changesFixture(t)
	frames, _ := watchChangesFrames(t, api, &dieterv1.ChangesRequest{HeartbeatMs: 1_000})
	untilCaughtUp(t, frames)
	header, _, err := data.Mail.Send(mail.Draft{Sender: model.MailSender{Kind: model.MailSenderOperator, Label: "test"}, Subject: "Stream me", Body: "Body"})
	if err != nil {
		t.Fatal(err)
	}
	waitForMail := func(match func(*dieterv1.ChangesFrame) bool, what string) {
		t.Helper()
		deadline := time.Now().Add(testkit.Budget(30 * time.Second))
		for time.Now().Before(deadline) {
			if frame := nextDataFrame(t, frames); match(frame) {
				return
			}
		}
		t.Fatalf("no frame with %s", what)
	}
	sentHeader := func(frame *dieterv1.ChangesFrame) *dieterv1.MailHeader {
		for _, value := range frame.GetMail() {
			if value.GetId() == header.ID {
				return value
			}
		}
		return nil
	}
	waitForMail(func(frame *dieterv1.ChangesFrame) bool {
		value := sentHeader(frame)
		return value != nil && value.GetSubject() == "Stream me" && !value.GetRead() && value.GetSender().GetLabel() == "test"
	}, "the sent header")

	// A new stream starts with every header.
	fresh, _ := watchChangesFrames(t, api, &dieterv1.ChangesRequest{HeartbeatMs: 1_000})
	found := false
	for _, frame := range untilCaughtUp(t, fresh) {
		found = found || sentHeader(frame) != nil
	}
	if !found {
		t.Fatal("the initial frames lack the mail header")
	}

	yes := true
	if _, err := data.Mail.Update([]string{header.ID}, mail.Change{Read: &yes}); err != nil {
		t.Fatal(err)
	}
	waitForMail(func(frame *dieterv1.ChangesFrame) bool {
		value := sentHeader(frame)
		return value != nil && value.GetRead() && len(frame.GetMail()) == 1
	}, "only the updated header")
	if _, err := data.Mail.Delete([]string{header.ID}, false); err != nil {
		t.Fatal(err)
	}
	waitForMail(func(frame *dieterv1.ChangesFrame) bool { return slices.Contains(frame.GetRemovedMailIds(), header.ID) }, "the removal")
}
