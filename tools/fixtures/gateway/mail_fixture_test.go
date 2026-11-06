package main

import (
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
	mailfixture "github.com/dbpprt/dieter/tests/fixtures/mail"
)

// The Maestro flows of the Mail destination rely on these exact messages.
func TestE2EFixtureSeedsTheMailFlowsRelyOn(t *testing.T) {
	t.Parallel()
	data := testkit.Store(t)
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Isolated E2E", Path: testkit.CheckoutDir(t)})
	if err != nil {
		t.Fatal(err)
	}
	board, err := data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		t.Fatal(err)
	}
	if err := seedE2EFixture(data, project, board); err != nil {
		t.Fatal(err)
	}
	headers, _, err := data.Mail.Headers()
	if err != nil || len(headers) != 5 {
		t.Fatalf("headers = %+v, %v", headers, err)
	}
	bySubject := map[string]model.MailHeader{}
	for _, header := range headers {
		bySubject[header.Subject] = header
	}
	sentAgo := func(header model.MailHeader) time.Duration {
		at, err := time.Parse(time.RFC3339Nano, header.SentAt)
		if err != nil {
			t.Fatal(err)
		}
		return time.Since(at).Round(time.Hour)
	}
	audit := bySubject["Dependency audit — 3 critical, 7 outdated"]
	if audit.Importance != model.MailImportanceHigh || audit.Read || audit.Folder != model.MailFolderInbox || sentAgo(audit) != time.Hour ||
		audit.Sender.CardID != mailAuditCardID || audit.Sender.ScheduleName != "Nightly dependency audit" || audit.Sender.Harness != "claude-code" || audit.Preview == "" {
		t.Fatalf("audit = %+v", audit)
	}
	invoices := bySubject["Invoice migration finished: 12,408 rows moved"]
	if invoices.Read || invoices.Folder != model.MailFolderInbox || invoices.Sender.Title != "Migrate invoices" || invoices.Sender.Harness != "codex" || sentAgo(invoices) != 2*time.Hour {
		t.Fatalf("invoices = %+v", invoices)
	}
	smoke := bySubject["Release smoke results: all platforms passed"]
	if !smoke.Read || !smoke.Flagged || smoke.Folder != model.MailFolderInbox || smoke.Sender.ScheduleName != "Stable smoke" || sentAgo(smoke) != 24*time.Hour {
		t.Fatalf("smoke = %+v", smoke)
	}
	backgrounds := bySubject["Chart background comparison"]
	if backgrounds.Read || backgrounds.Importance != model.MailImportanceHigh || backgrounds.Folder != model.MailFolderInbox {
		t.Fatalf("background comparison = %+v", backgrounds)
	}
	_, comparison, err := data.Mail.Get(backgrounds.ID)
	if err != nil || strings.TrimSpace(comparison) != strings.TrimSpace(mailfixture.Backgrounds) || strings.Count(comparison, "```vega") != 6 {
		t.Fatalf("background comparison fixture missing or changed: %v", err)
	}
	backup := bySubject["Nightly backup completed (41.2 GB)"]
	if !backup.Read || backup.Folder != model.MailFolderArchive || backup.Sender.Kind != model.MailSenderOperator || backup.Sender.Label != "backup.sh" || sentAgo(backup) != 72*time.Hour {
		t.Fatalf("backup = %+v", backup)
	}
	for _, id := range []string{mailAuditCardID, mailInvoiceCardID} {
		card, err := data.Kanban.ResolveCard(id)
		if err != nil || !card.MailAccess || card.Lane != model.LaneDone {
			t.Fatalf("sender card %s = %+v, %v", id, card, err)
		}
	}
	if card, err := data.Kanban.ResolveCard(mailAuditCardID); err != nil || card.Origin == nil || card.Origin.ScheduleID != audit.Sender.ScheduleID {
		t.Fatalf("audit card origin = %+v, %v", card.Origin, err)
	}
	if _, err := data.Kanban.ResolveCard(mailSmokeCardID); err == nil {
		t.Fatal("the smoke report's conversation should be gone")
	}
	_, body, err := data.Mail.Get(audit.ID)
	if err != nil || len(body) == 0 {
		t.Fatalf("audit body = %q, %v", body, err)
	}
	_, richBody, err := data.Mail.Get(smoke.ID)
	if err != nil || !strings.Contains(richBody, "```vegalite") || !strings.Contains(richBody, "```mermaid") || !strings.Contains(richBody, "```vega\n") {
		t.Fatalf("rich Mail reader fixture missing: %v", err)
	}
}
