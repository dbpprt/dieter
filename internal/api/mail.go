package api

import (
	"context"
	"errors"
	"os"
	"strings"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/store/mail"
)

// Mail rules:
//   - An agent turn (a live turn token on the local route) may only send, and
//     only when its conversation was created with mail access. Its sender is
//     taken from the card; the turn cannot name itself.
//   - Every other caller is the operator: the local CLI or a script without a
//     token, which may name itself with from, or a remote roster device. The
//     operator reads and organizes the mailbox.
//   - Reading, changing and deleting refuse any turn token: the mailbox holds
//     every conversation's reports, and mail must never reach a prompt.

// mailCaller is the sender of SendMail.
type mailCaller struct {
	agent  bool
	card   model.Card
	turnID string
	device string
}

func (s *Server) mailCaller(ctx context.Context) (mailCaller, error) {
	card, turnID, agent, err := s.turnCaller(ctx)
	if err != nil || agent {
		return mailCaller{agent: agent, card: card, turnID: turnID}, err
	}
	caller := mailCaller{}
	if requestHeader(ctx, operatorSubjectMetadata) != "" {
		caller.device = requestHeader(ctx, deviceIDMetadata)
	}
	return caller, nil
}

// mailOperator refuses agent turns everything but sending.
func mailOperator(ctx context.Context) error {
	if requestHeader(ctx, turnTokenMetadata) != "" {
		return fault.New(fault.PermissionDenied, "agents can send mail but not read it")
	}
	return nil
}

// mailSender snapshots an agent's conversation, so the message stays
// meaningful after the card is renamed, archived or deleted.
func (s *Server) mailSender(card model.Card, turnID string) model.MailSender {
	sender := model.MailSender{
		Kind: model.MailSenderAgent, CardID: card.ID, TurnID: turnID, Scope: "card", Title: card.Title,
		ProjectID: card.ProjectID, CheckoutID: card.CheckoutID, Harness: card.Provider, Model: card.Model,
	}
	if card.Scope == model.ConversationScopeChat {
		sender.Scope = "chat"
	}
	if project, err := s.store.Kanban.ResolveProject(card.ProjectID); err == nil {
		sender.ProjectName = project.Name
	}
	if origin := card.Origin; origin != nil && origin.Kind == "schedule" && origin.ScheduleID != "" {
		sender.ScheduleID = origin.ScheduleID
		if schedule, err := s.store.Schedules.ResolveIncludingArchived(origin.ScheduleID); err == nil {
			sender.ScheduleName = schedule.Name
		}
	}
	return sender
}

func (api *mailAPI) SendMail(ctx context.Context, r *dieterv1.SendMailRequest) (*dieterv1.MailHeader, error) {
	caller, err := api.server.mailCaller(ctx)
	if err != nil {
		return nil, err
	}
	draft := mail.Draft{Subject: r.GetSubject(), Body: r.GetBody(), OperationID: r.GetOperationId()}
	switch r.GetImportance() {
	case dieterv1.MailImportance_MAIL_IMPORTANCE_UNSPECIFIED, dieterv1.MailImportance_MAIL_IMPORTANCE_NORMAL:
	case dieterv1.MailImportance_MAIL_IMPORTANCE_HIGH:
		draft.Important = true
	default:
		return nil, fault.New(fault.Invalid, "unknown importance")
	}
	if caller.agent {
		if !caller.card.MailAccess {
			return nil, fault.New(fault.PermissionDenied, "this conversation was created without mail access; the user can create one with --mail")
		}
		if strings.TrimSpace(r.GetFrom()) != "" {
			return nil, fault.New(fault.Invalid, "agents cannot set from: mail names the sending conversation")
		}
		draft.Sender = api.server.mailSender(caller.card, caller.turnID)
		api.server.app.RedactVaultText(caller.card.ID, caller.turnID, &draft.Subject, &draft.Body)
	} else {
		label, err := model.NormalizeMailFrom(r.GetFrom())
		if err != nil {
			return nil, err
		}
		draft.Sender = model.MailSender{Kind: model.MailSenderOperator, Label: label, DeviceID: caller.device}
	}
	header, _, err := api.server.store.Mail.Send(draft)
	if errors.Is(err, mail.ErrFull) {
		machine, _ := os.Hostname()
		if machine == "" {
			machine = "this machine"
		}
		return nil, fault.Errorf(fault.ResourceExhausted, "the mailbox on %s is full: every message is unread or flagged; read, unflag or delete some", machine)
	}
	if err != nil {
		return nil, domainFailure(err)
	}
	return protoMailHeader(header), nil
}

func (api *mailAPI) ListMail(ctx context.Context, r *dieterv1.ListMailRequest) (*dieterv1.MailPage, error) {
	if err := mailOperator(ctx); err != nil {
		return nil, err
	}
	folder, err := mailFolderName(r.GetFolder())
	if err != nil {
		return nil, err
	}
	if r.GetLimit() > model.MailMaxPageSize {
		return nil, fault.Invalidf("at most %d messages per page", model.MailMaxPageSize)
	}
	headers, more, err := api.server.store.Mail.List(mail.Filter{
		Folder: folder, Unread: r.GetUnreadOnly(), Flagged: r.GetFlaggedOnly(), BeforeID: strings.TrimSpace(r.GetBeforeId()), Limit: int(r.GetLimit()),
	})
	if err != nil {
		return nil, domainFailure(err)
	}
	page := &dieterv1.MailPage{HasMore: more}
	for _, header := range headers {
		page.Messages = append(page.Messages, protoMailHeader(header))
	}
	return page, nil
}

func (api *mailAPI) GetMail(ctx context.Context, r *dieterv1.MailRef) (*dieterv1.Mail, error) {
	if err := mailOperator(ctx); err != nil {
		return nil, err
	}
	header, body, err := api.server.store.Mail.Get(strings.TrimSpace(r.GetId()))
	if err != nil {
		return nil, domainFailure(err)
	}
	return &dieterv1.Mail{Header: protoMailHeader(header), Body: body}, nil
}

func (api *mailAPI) UpdateMail(ctx context.Context, r *dieterv1.UpdateMailRequest) (*dieterv1.UpdateMailResponse, error) {
	if err := mailOperator(ctx); err != nil {
		return nil, err
	}
	folder, err := mailFolderName(r.GetFolder())
	if err != nil {
		return nil, err
	}
	headers, err := api.server.store.Mail.Update(r.GetIds(), mail.Change{Read: r.Read, Flagged: r.Flagged, Folder: folder})
	if err != nil {
		return nil, domainFailure(err)
	}
	response := &dieterv1.UpdateMailResponse{}
	for _, header := range headers {
		response.Messages = append(response.Messages, protoMailHeader(header))
	}
	return response, nil
}

func (api *mailAPI) DeleteMail(ctx context.Context, r *dieterv1.DeleteMailRequest) (*dieterv1.DeleteMailResponse, error) {
	if err := mailOperator(ctx); err != nil {
		return nil, err
	}
	deleted, err := api.server.store.Mail.Delete(r.GetIds(), r.GetEmptyTrash())
	if err != nil {
		return nil, domainFailure(err)
	}
	return &dieterv1.DeleteMailResponse{DeletedIds: deleted}, nil
}

func mailFolderName(folder dieterv1.MailFolder) (string, error) {
	switch folder {
	case dieterv1.MailFolder_MAIL_FOLDER_UNSPECIFIED:
		return "", nil
	case dieterv1.MailFolder_MAIL_FOLDER_INBOX:
		return model.MailFolderInbox, nil
	case dieterv1.MailFolder_MAIL_FOLDER_ARCHIVE:
		return model.MailFolderArchive, nil
	case dieterv1.MailFolder_MAIL_FOLDER_TRASH:
		return model.MailFolderTrash, nil
	}
	return "", fault.New(fault.Invalid, "unknown mail folder")
}

func protoMailFolder(folder string) dieterv1.MailFolder {
	switch folder {
	case model.MailFolderArchive:
		return dieterv1.MailFolder_MAIL_FOLDER_ARCHIVE
	case model.MailFolderTrash:
		return dieterv1.MailFolder_MAIL_FOLDER_TRASH
	}
	return dieterv1.MailFolder_MAIL_FOLDER_INBOX
}

func protoMailHeader(header model.MailHeader) *dieterv1.MailHeader {
	sender := header.Sender
	kind := dieterv1.MailSenderKind_MAIL_SENDER_KIND_OPERATOR
	if sender.Kind == model.MailSenderAgent {
		kind = dieterv1.MailSenderKind_MAIL_SENDER_KIND_AGENT
	}
	importance := dieterv1.MailImportance_MAIL_IMPORTANCE_NORMAL
	if header.Importance == model.MailImportanceHigh {
		importance = dieterv1.MailImportance_MAIL_IMPORTANCE_HIGH
	}
	return &dieterv1.MailHeader{
		Id: header.ID, Subject: header.Subject, Preview: header.Preview, Importance: importance, SentAt: header.SentAt,
		BodyBytes: uint32(header.BodyBytes), BodyDigest: header.BodyDigest, Read: header.Read, Flagged: header.Flagged,
		Folder: protoMailFolder(header.Folder), StateChangedAt: header.StateChangedAt,
		Sender: &dieterv1.MailSender{
			Kind: kind, CardId: sender.CardID, TurnId: sender.TurnID, Scope: sender.Scope, Title: sender.Title,
			ProjectId: sender.ProjectID, ProjectName: sender.ProjectName, CheckoutId: sender.CheckoutID,
			ScheduleId: sender.ScheduleID, ScheduleName: sender.ScheduleName, Harness: sender.Harness, Model: sender.Model,
			DeviceId: sender.DeviceID, Label: sender.Label,
		},
	}
}
