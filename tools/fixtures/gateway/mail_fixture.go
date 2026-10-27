package main

import (
	"time"

	"github.com/dbpprt/dieter/internal/model"
	boardstore "github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/mail"
	"github.com/dbpprt/dieter/internal/store/schedules"
	mailfixture "github.com/dbpprt/dieter/tests/fixtures/mail"
)

// Agent mail of the e2e and showcase fixtures. Maestro flows and screenshot
// scripts find the messages by subject; message IDs are generated per run.
const (
	mailAuditSubject   = "Dependency audit — 3 critical, 7 outdated"
	mailInvoiceSubject = "Invoice migration finished: 12,408 rows moved"
	mailSmokeSubject   = "Release smoke results: all platforms passed"
	mailBackupSubject  = "Nightly backup completed (41.2 GB)"

	mailAuditCardID   = "c_mail_audit"
	mailInvoiceCardID = "c_mail_invoices"
	// The smoke report's conversation is gone, as after a cleanup: its
	// Open conversation action is unavailable.
	mailSmokeCardID = "c_mail_smoke_deleted"
)

const mailAuditBody = "## Summary\n\n" +
	"Three dependencies have **critical** advisories and seven are outdated. Every fix is a patch or minor " +
	"release; `go.mod` and `web/package.json` need updates. The upgrade notes are in [README.md](README.md).\n\n" +
	"| Package | Current | Fixed in | Severity | Advisory | Importers | Notes |\n" +
	"|:--|--:|--:|:-:|:--|--:|:--|\n" +
	"| golang.org/x/net | 0.23.0 | 0.33.0 | critical | [DA-2026-0141](https://advisories.example.com/DA-2026-0141) | 14 | HTTP/2 header parsing |\n" +
	"| golang.org/x/crypto | 0.21.0 | 0.31.0 | critical | [DA-2026-0138](https://advisories.example.com/DA-2026-0138) | 9 | SSH key callback misuse |\n" +
	"| github.com/golang-jwt/jwt/v5 | 5.2.0 | 5.2.2 | critical | [DA-2026-0122](https://advisories.example.com/DA-2026-0122) | 3 | Header parsing allocation |\n" +
	"| express | 4.19.2 | 4.21.2 | high | [DA-2026-0117](https://advisories.example.com/DA-2026-0117) | 2 | Open redirect |\n" +
	"| semver | 7.5.1 | 7.5.4 | moderate | [DA-2026-0094](https://advisories.example.com/DA-2026-0094) | 6 | Range parsing ReDoS |\n\n" +
	"### Suggested next steps\n\n" +
	"- [x] Pin the fixed versions on a branch\n" +
	"- [ ] Run the integration suite against the branch\n" +
	"- [ ] Ship the upgrade with the next release\n\n" +
	"```sh\n" +
	"go get golang.org/x/net@v0.33.0 golang.org/x/crypto@v0.31.0 github.com/golang-jwt/jwt/v5@v5.2.2\n" +
	"go mod tidy && go test ./...\n" +
	"```\n"

const mailInvoiceBody = "Moved **12,408** invoice rows from `billing_v1` to `billing_v2` in four batches. " +
	"Totals match to the cent; 17 rows were skipped and need a decision.\n\n" +
	"| Reason | Rows | Example |\n" +
	"|:--|--:|:--|\n" +
	"| Missing customer | 11 | `inv_2024_08812` |\n" +
	"| Negative amount | 4 | `inv_2025_01277` |\n" +
	"| Duplicate number | 2 | `inv_2025_03340` |\n\n" +
	"1. Review the skipped rows in `migrations/skipped.csv`.\n" +
	"2. Decide whether credit notes may carry negative amounts.\n" +
	"3. Drop `billing_v1` after one more billing cycle.\n"

const mailSmokeBody = "Every platform passed the release smoke.\n\n" +
	"| Platform | Flows | Duration |\n" +
	"|:--|--:|--:|\n" +
	"| macOS | 12 | 4m 12s |\n" +
	"| Android | 9 | 6m 40s |\n" +
	"| iOS | 9 | 7m 05s |\n\n" +
	"No flow needed a retry.\n"

const mailBackupBody = "The nightly backup of `/srv/data` finished: **41.2 GB** in 1,204,331 files.\n\n" +
	"- Snapshot verified with 100 sampled files\n" +
	"- Retention: 14 daily, 8 weekly\n"

// mailSenders are the agent senders of the fixture messages.
type mailSenders struct{ audit, invoices, smoke model.MailSender }

// seedMail sends the four fixture messages, backdated, and sets their state:
// the audit is important and unread, the migration unread, the smoke report
// read and flagged, and the operator's backup report read and archived.
func seedMail(data *boardstore.Store, senders mailSenders) error {
	now := time.Now()
	read := true
	for _, message := range []struct {
		sender        model.MailSender
		subject, body string
		important     bool
		ago           time.Duration
		change        mail.Change
	}{
		{senders.smoke, "Chart background comparison", mailfixture.Backgrounds, true, 30 * time.Minute, mail.Change{}},
		{senders.audit, mailAuditSubject, mailAuditBody, true, time.Hour, mail.Change{}},
		{senders.invoices, mailInvoiceSubject, mailInvoiceBody, false, 2 * time.Hour, mail.Change{}},
		{senders.smoke, mailSmokeSubject, mailSmokeBody + "\n" + mailfixture.Rich, false, 24 * time.Hour, mail.Change{Read: &read, Flagged: &read}},
		{model.MailSender{Kind: model.MailSenderOperator, Label: "backup.sh"}, mailBackupSubject, mailBackupBody, false, 72 * time.Hour, mail.Change{Read: &read, Folder: model.MailFolderArchive}},
	} {
		header, _, err := data.Mail.Send(mail.Draft{Sender: message.sender, Subject: message.subject, Body: message.body, Important: message.important, SentAt: now.Add(-message.ago)})
		if err != nil {
			return err
		}
		if message.change.Read != nil || message.change.Folder != "" {
			if _, err := data.Mail.Update([]string{header.ID}, message.change); err != nil {
				return err
			}
		}
	}
	return nil
}

// agentMailSender is the sender snapshot of a fixture card's turn.
func agentMailSender(card model.Card, project model.Project, schedule *model.Schedule) model.MailSender {
	sender := model.MailSender{
		Kind: model.MailSenderAgent, CardID: card.ID, TurnID: "turn_" + card.ID, Scope: "card", Title: card.Title,
		ProjectID: project.ID, ProjectName: project.Name, CheckoutID: card.CheckoutID, Harness: card.Provider, Model: card.Model,
	}
	if schedule != nil {
		sender.ScheduleID, sender.ScheduleName = schedule.ID, schedule.Name
	}
	return sender
}

// mailSenderCard creates a finished conversation with mail access whose turn
// sent a fixture report.
func mailSenderCard(data *boardstore.Store, input kanban.CreateCardInput, answer string) (model.Card, error) {
	input.Lane, input.MailAccess, input.WorkspaceMode = model.LaneTodo, true, model.WorkspaceModeProject
	card, err := data.Kanban.CreateCard(input)
	if err != nil {
		return model.Card{}, err
	}
	if _, err = data.Kanban.MarkPromptSent(card.ID); err != nil {
		return model.Card{}, err
	}
	if _, err = data.Conversations.InitializeFork(card.ID, []model.UIMessage{
		{ID: "mail-prompt-" + card.ID, Role: "user", Parts: []model.UIMessagePart{{Type: "text", Text: input.Prompt}}},
		{ID: "mail-answer-" + card.ID, Role: "assistant", Parts: []model.UIMessagePart{{Type: "text", Text: answer}}},
	}); err != nil {
		return model.Card{}, err
	}
	if _, err = data.Kanban.MoveCard(card.ID, model.LaneDone, nil); err != nil {
		return model.Card{}, err
	}
	return data.Kanban.UpdateCardCache(card.ID, kanban.CardCacheInput{Runtime: "idle", Summary: answer})
}

// seedE2EMail seeds the mail of the Maestro fixture. The audit and migration
// reports come from real finished cards in the Done lane, so Open
// conversation works; the audit card was created by the disabled "Nightly
// dependency audit" schedule. The smoke report names a disabled "Stable
// smoke" schedule and a conversation that no longer exists.
func seedE2EMail(data *boardstore.Store, project model.Project, board model.Board) error {
	scheduled := func(name, provider, modelID string) (model.Schedule, error) {
		return data.Schedules.Create(schedules.Input{
			Project: project.ID, Board: board.ID, Name: name, Description: "Sends a report to Mail", Cron: "0 2 * * *", Timezone: "UTC",
			Action: model.ScheduleActionRun, TitleTemplate: name, PromptTemplate: "Run the " + name + " and mail the report.",
			Provider: provider, Model: modelID, WorkspaceMode: model.WorkspaceModeProject, MailAccess: true,
		})
	}
	audit, err := scheduled("Nightly dependency audit", "claude-code", "sonnet")
	if err != nil {
		return err
	}
	smoke, err := scheduled("Stable smoke", "codex", "gpt-6-astra")
	if err != nil {
		return err
	}
	auditCard, err := mailSenderCard(data, kanban.CreateCardInput{
		ID: mailAuditCardID, Project: project.ID, Board: board.ID, Title: "Nightly dependency audit", Prompt: audit.PromptTemplate,
		Provider: "claude-code", Model: "sonnet", Origin: &model.CardOrigin{Kind: "schedule", ScheduleID: audit.ID, ScheduledFor: time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)},
	}, "Three critical advisories and seven outdated modules; the report is in Mail.")
	if err != nil {
		return err
	}
	invoiceCard, err := mailSenderCard(data, kanban.CreateCardInput{
		ID: mailInvoiceCardID, Project: project.ID, Board: board.ID, Title: "Migrate invoices",
		Prompt: "Move the invoices from billing_v1 to billing_v2 and report what was skipped.", Provider: "codex", Model: "gpt-6-astra",
	}, "Moved 12,408 invoice rows; 17 were skipped. The report is in Mail.")
	if err != nil {
		return err
	}
	smokeSender := agentMailSender(model.Card{ID: mailSmokeCardID, Title: "Stable smoke", Provider: smoke.Provider, Model: smoke.Model, CheckoutID: auditCard.CheckoutID}, project, &smoke)
	return seedMail(data, mailSenders{
		audit:    agentMailSender(auditCard, project, &audit),
		invoices: agentMailSender(invoiceCard, project, nil),
		smoke:    smokeSender,
	})
}

// seedShowcaseMail seeds the same mail on the office machine for the docs
// screenshots. Its sender cards are archived, so the curated boards keep
// their look; the audit names the showcase's own nightly audit schedule.
func seedShowcaseMail(data *boardstore.Store, project model.Project, board model.Board) error {
	audit, err := data.Schedules.Resolve("Nightly dependency audit")
	if err != nil {
		return err
	}
	auditCard, err := mailSenderCard(data, kanban.CreateCardInput{
		ID: mailAuditCardID, Project: project.ID, Board: board.ID, Title: "Nightly dependency audit", Prompt: audit.PromptTemplate,
		Provider: "claude-code", Model: "sonnet", Origin: &model.CardOrigin{Kind: "schedule", ScheduleID: audit.ID, ScheduledFor: time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)},
	}, "Three critical advisories and seven outdated modules; the report is in Mail.")
	if err != nil {
		return err
	}
	invoiceCard, err := mailSenderCard(data, kanban.CreateCardInput{
		ID: mailInvoiceCardID, Project: project.ID, Board: board.ID, Title: "Migrate invoices",
		Prompt: "Move the invoices from billing_v1 to billing_v2 and report what was skipped.", Provider: "codex", Model: "gpt-5.6-sol",
	}, "Moved 12,408 invoice rows; 17 were skipped. The report is in Mail.")
	if err != nil {
		return err
	}
	for _, id := range []string{auditCard.ID, invoiceCard.ID} {
		if _, err := data.Kanban.ArchiveCard(id, true); err != nil {
			return err
		}
	}
	smoke := model.Schedule{ID: "sch_stable_smoke", Name: "Stable smoke"}
	return seedMail(data, mailSenders{
		audit:    agentMailSender(auditCard, project, &audit),
		invoices: agentMailSender(invoiceCard, project, nil),
		smoke:    agentMailSender(model.Card{ID: mailSmokeCardID, Title: "Stable smoke", Provider: "codex", Model: "gpt-5.6-terra", CheckoutID: auditCard.CheckoutID}, project, &smoke),
	})
}
