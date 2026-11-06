//go:build e2e

package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/store/home"
	"github.com/dbpprt/dieter/internal/testkit"
	"google.golang.org/protobuf/encoding/protojson"
)

func TestDaemonCLIMail(t *testing.T) {
	t.Setenv("DIETER_TURN_TOKEN", "")
	client, output, _ := daemonCLIForTest(t)
	assertMailCLI(t, client, output, false)
}

// assertMailCLI drives every mail command as the operator over the client's
// route (local, verified direct TLS or the gateway relay). A remote operator
// is named by its device.
func assertMailCLI(t *testing.T, client *CLI, output *bytes.Buffer, remote bool) {
	t.Helper()
	// These assertions act as the operator; an agent turn running the suite
	// would otherwise be the caller.
	client.env.TurnToken = ""
	defer func() { client.In = os.Stdin }()
	subject := "Route report " + home.NewID("")
	body := "## Summary\n\n| Check | Result |\n|:--|--:|\n| build | **ok** |\n"
	path := filepath.Join(t.TempDir(), "report.md")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	operation := home.NewID("op_")
	id := strings.TrimSpace(runDaemonCLI(t, client, output, "mail", "send", "--subject", subject, "--body-file", path, "--important", "--from", "route-test", "--operation-id", operation, "--format", "id"))
	if !strings.HasPrefix(id, "ml_") {
		t.Fatalf("send id = %q", id)
	}
	if again := strings.TrimSpace(runDaemonCLI(t, client, output, "mail", "send", "--subject", subject, "--body", "retry", "--operation-id", operation, "--format", "id")); again != id {
		t.Fatalf("retried send = %q, want %q", again, id)
	}
	client.In = strings.NewReader("Second report from stdin.\n")
	if sent := runDaemonCLI(t, client, output, "mail", "send", "--subject", subject+" (stdin)", "--body-file", "-"); !strings.HasPrefix(sent, "Sent ml_") || !strings.Contains(sent, subject+" (stdin)") {
		t.Fatalf("stdin send = %q", sent)
	}

	if table := runDaemonCLI(t, client, output, "mail", "list"); !strings.Contains(table, id) || !strings.Contains(table, "●!") || !strings.Contains(table, "route-test") || !strings.Contains(table, subject) {
		t.Fatalf("list = %q", table)
	}
	var page dieterv1.MailPage
	if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "mail", "list", "--unread", "--format", "json")), &page); err != nil {
		t.Fatal(err)
	}
	var listed *dieterv1.MailHeader
	for _, header := range page.GetMessages() {
		if header.GetId() == id {
			listed = header
		}
	}
	if listed == nil || listed.GetSender().GetKind() != dieterv1.MailSenderKind_MAIL_SENDER_KIND_OPERATOR || listed.GetSender().GetLabel() != "route-test" ||
		listed.GetImportance() != dieterv1.MailImportance_MAIL_IMPORTANCE_HIGH || listed.GetPreview() != "Check · Result" || (listed.GetSender().GetDeviceId() != "") != remote {
		t.Fatalf("listed = %v (remote %t)", listed, remote)
	}

	if shown := runDaemonCLI(t, client, output, "mail", "show", id); !strings.Contains(shown, "Subject:  "+subject) || !strings.Contains(shown, "From:     route-test") || !strings.Contains(shown, "unread, important") || !strings.HasSuffix(shown, "\n"+body) {
		t.Fatalf("show = %q", shown)
	}
	if raw := runDaemonCLI(t, client, output, "mail", "show", "--raw", id); raw != body {
		t.Fatalf("show --raw = %q", raw)
	}

	if marked := runDaemonCLI(t, client, output, "mail", "mark", "--read", "--flag", "--folder", "archive", id); !strings.Contains(marked, id) || !strings.Contains(marked, "⚑!") || !strings.Contains(marked, "archive") {
		t.Fatalf("mark = %q", marked)
	}
	if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "mail", "list", "--folder", "archive", "--flagged", "--format", "json")), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.GetMessages()) == 0 || page.GetMessages()[0].GetId() != id || !page.GetMessages()[0].GetRead() {
		t.Fatalf("archived = %v", &page)
	}
	if inbox := runDaemonCLI(t, client, output, "mail", "list", "--unread"); strings.Contains(inbox, id) {
		t.Fatalf("a read archived message is listed as unread in the Inbox: %q", inbox)
	}
	output.Reset()
	if err := client.Run([]string{"mail", "mark", "--unread", id, "ml_missing"}); err == nil || !strings.Contains(err.Error(), "mail not found: ml_missing") {
		t.Fatalf("mark with an unknown ID = %v", err)
	}

	runDaemonCLI(t, client, output, "mail", "mark", "--folder", "trash", id)
	if deleted := runDaemonCLI(t, client, output, "mail", "delete", "--empty-trash"); !strings.HasPrefix(deleted, "Deleted ") {
		t.Fatalf("empty trash = %q", deleted)
	}
	output.Reset()
	if err := client.Run([]string{"mail", "show", id}); err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("show after delete = %v", err)
	}
	stdinID := ""
	if err := protojson.Unmarshal([]byte(runDaemonCLI(t, client, output, "mail", "list", "--format", "json")), &page); err != nil {
		t.Fatal(err)
	}
	for _, header := range page.GetMessages() {
		if header.GetSubject() == subject+" (stdin)" {
			stdinID = header.GetId()
		}
	}
	if deleted := runDaemonCLI(t, client, output, "mail", "delete", stdinID); deleted != "Deleted 1 message.\n" {
		t.Fatalf("delete = %q", deleted)
	}
	output.Reset()
	if err := client.Run([]string{"mail", "delete", stdinID}); err == nil || !strings.Contains(err.Error(), "mail not found") {
		t.Fatalf("delete twice = %v", err)
	}
}

// TestMailCLIAgentTurnsSendWithAccessOnly runs mail as an agent with its real
// turn token.
func TestMailCLIAgentTurnsSendWithAccessOnly(t *testing.T) {
	t.Setenv("DIETER_TURN_TOKEN", "")
	runner := &fakeRunner{Script: cliTurn, Release: make(chan struct{})}
	client, output, data := daemonCLIWithRunner(t, runner)
	repository := initTestRepository(t, "mail")
	var created struct {
		Project struct {
			ID string `json:"id"`
		} `json:"project"`
		Board struct {
			ID string `json:"id"`
		} `json:"board"`
	}
	if err := json.Unmarshal([]byte(runDaemonCLI(t, client, output, "project", "open", "--name", "Mail", "--format", "json", repository)), &created); err != nil {
		t.Fatal(err)
	}
	// startTurn creates a running card and returns its agent turn token.
	startTurn := func(title string, extra ...string) (string, string) {
		t.Helper()
		before := runner.Count()
		args := append([]string{"card", "create", "--project", created.Project.ID, "--board", created.Board.ID, "--title", title, "--workspace", "project", "--provider", "mock", "--model", "mock", "--lane", "running", "--format", "id"}, extra...)
		cardID := strings.TrimSpace(runDaemonCLI(t, client, output, args...))
		deadline := time.Now().Add(testkit.Budget(30 * time.Second))
		for runner.Count() == before {
			if time.Now().After(deadline) {
				t.Fatal("the turn did not start")
			}
			time.Sleep(10 * time.Millisecond)
		}
		request := runner.Request(before)
		if request.Environment["DIETER_CARD_ID"] != cardID {
			t.Fatalf("turn of %q, want %s", request.Environment["DIETER_CARD_ID"], cardID)
		}
		return cardID, request.Environment["DIETER_TURN_TOKEN"]
	}
	cardID, token := startTurn("Nightly audit", "--mail")
	if stored, err := data.Kanban.ResolveCard(cardID); err != nil || !stored.MailAccess {
		t.Fatalf("card create --mail = %+v, %v", stored, err)
	}
	if prompt := runner.Request(0).Instructions; !strings.Contains(prompt, "mail send --subject") {
		t.Fatalf("instructions lack mail: %q", prompt)
	}
	plainID, plainToken := startTurn("No mail")

	// The connection carries the token it was dialed with.
	act := func(token string) {
		client.Close()
		client.env.TurnToken = token
	}
	act(token)
	sent := runDaemonCLI(t, client, output, "mail", "send", "--subject", "Audit: 3 critical", "--body", "## Summary\n\nThree advisories.", "--important")
	if !strings.HasPrefix(sent, "Sent ml_") {
		t.Fatalf("agent send = %q", sent)
	}
	output.Reset()
	if err := client.Run([]string{"mail", "send", "--subject", "Named", "--body", "x", "--from", "me"}); err == nil || !strings.Contains(err.Error(), "agents cannot set from") {
		t.Fatalf("agent --from = %v", err)
	}
	for _, args := range [][]string{{"mail", "list"}, {"mail", "show", "ml_x"}, {"mail", "mark", "--read", "ml_x"}, {"mail", "delete", "ml_x"}} {
		output.Reset()
		if err := client.Run(args); err == nil || !strings.Contains(err.Error(), "agents can send mail but not read it") {
			t.Fatalf("agent %v = %v", args, err)
		}
	}
	output.Reset()
	if err := client.Run([]string{"card", "create", "--project", created.Project.ID, "--board", created.Board.ID, "--title", "Sibling", "--workspace", "project", "--provider", "mock", "--model", "mock", "--mail"}); err != nil {
		t.Fatalf("an agent with mail access passes it on: %v", err)
	}
	client.Machine = "elsewhere"
	output.Reset()
	if err := client.Run([]string{"mail", "send", "--subject", "Remote", "--body", "x"}); err == nil || !strings.Contains(err.Error(), "omit --machine") {
		t.Fatalf("agent --machine = %v", err)
	}
	client.Machine = ""

	act(plainToken)
	output.Reset()
	if err := client.Run([]string{"mail", "send", "--subject", "Nope", "--body", "x"}); err == nil || !strings.Contains(err.Error(), "created without mail access") {
		t.Fatalf("send without access = %v", err)
	}
	output.Reset()
	if err := client.Run([]string{"chat", "create", "--project", created.Project.ID, "--title", "Escalate", "--workspace", "project", "--provider", "mock", "--model", "mock", "--mail"}); err == nil || !strings.Contains(err.Error(), "cannot grant it") {
		t.Fatalf("escalation = %v", err)
	}

	act("")
	close(runner.Release)
	for _, id := range []string{cardID, plainID} {
		for deadline := time.Now().Add(testkit.Budget(30 * time.Second)); ; time.Sleep(10 * time.Millisecond) {
			if card, err := data.Kanban.ResolveCard(id); err == nil && card.Runtime == "idle" {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("turn of %s did not finish", id)
			}
		}
	}
	if _, err := data.Kanban.GlobalStateContext(t.Context()); err != nil {
		t.Fatal(err)
	}
	// The operator reads what the agent sent, named by its conversation.
	if table := runDaemonCLI(t, client, output, "mail", "list"); !strings.Contains(table, "Nightly audit") || !strings.Contains(table, "Audit: 3 critical") {
		t.Fatalf("operator list = %q", table)
	}
	// The ended turn's token no longer sends.
	act(token)
	output.Reset()
	if err := client.Run([]string{"mail", "send", "--subject", "Late", "--body", "x"}); err == nil || !strings.Contains(err.Error(), "turn token") {
		t.Fatalf("finished turn = %v", err)
	}
	act("")
	// Decoded afresh each time: protojson omits a false flag.
	mailAccess := func(raw string) (string, bool) {
		t.Helper()
		var value struct {
			ID         string `json:"id"`
			MailAccess bool   `json:"mailAccess"`
		}
		if err := json.Unmarshal([]byte(raw), &value); err != nil {
			t.Fatalf("decode %q: %v", raw, err)
		}
		return value.ID, value.MailAccess
	}
	scheduleID, granted := mailAccess(runDaemonCLI(t, client, output, "schedule", "create", "--project", created.Project.ID, "--board", created.Board.ID, "--name", "Nightly audit", "--cron", "0 3 * * *", "--title", "Audit", "--prompt", "Audit", "--provider", "mock", "--model", "mock", "--mail"))
	if !granted {
		t.Fatal("schedule create --mail did not grant mail access")
	}
	if _, kept := mailAccess(runDaemonCLI(t, client, output, "schedule", "update", "--name", "Renamed", scheduleID)); !kept {
		t.Fatal("schedule update dropped mail access")
	}
	if _, kept := mailAccess(runDaemonCLI(t, client, output, "schedule", "update", "--mail=false", scheduleID)); kept {
		t.Fatal("schedule update --mail=false kept mail access")
	}
}
