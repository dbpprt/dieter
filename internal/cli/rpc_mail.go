package cli

import (
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"text/tabwriter"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
)

const mailHelp = `Usage: dieter mail <send|list|show|mark|delete> [options]

Dieter Mail: one-way Markdown reports for you. Messages stay on the machine
that received them, with their read, flag and folder state (Inbox, Archive,
Trash; the Trash empties after 30 days), and every client shows them in Mail.
There is no reply: mail never reaches an agent.

Inside an agent turn (DIETER_TURN_TOKEN) the caller is that conversation's
agent. It may only send, and only when its card, chat or schedule was created
with --mail. Anyone else is the operator: scripts and jobs send with an
optional --from label, and people read and organize the mailbox.

  send    Send a Markdown report
  list    List messages, newest first
  show    Print one message with its Markdown body
  mark    Mark messages read or unread, flag them, or move them to a folder
  delete  Delete messages for good, or empty the Trash
`

func (c *CLI) rpcMail(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, mailHelp)
		return nil
	}
	actions := map[string]func([]string) error{
		"send": c.mailSend, "list": c.mailList, "ls": c.mailList, "show": c.mailShow,
		"mark": c.mailMark, "delete": c.mailDelete, "rm": c.mailDelete,
	}
	action, ok := actions[args[0]]
	if !ok {
		return fmt.Errorf("unknown mail action %q; run `dieter mail --help`", args[0])
	}
	if !wantsHelp(args[1:]) && c.env.TurnToken != "" && strings.TrimSpace(c.Machine) != "" {
		return errors.New("inside an agent turn, mail goes through the local daemon; omit --machine")
	}
	return action(args[1:])
}

// mailBody reads --body or --body-file (a path or - for stdin), bounded.
func (c *CLI) mailBody(inline, path string) (string, error) {
	if inline != "" && path != "" {
		return "", errors.New("use either --body or --body-file, not both")
	}
	if path == "" {
		return inline, nil
	}
	var source io.Reader = c.In
	if path != "-" {
		file, err := os.Open(path)
		if err != nil {
			return "", err
		}
		defer file.Close()
		source = file
	}
	// Reading stops one byte past the limit, so an oversized file fails
	// without being read whole.
	raw, err := io.ReadAll(io.LimitReader(source, model.MailMaxBodyBytes+1))
	if err != nil {
		return "", err
	}
	if len(raw) > model.MailMaxBodyBytes {
		return "", fmt.Errorf("the body is larger than %d KiB", model.MailMaxBodyBytes>>10)
	}
	return string(raw), nil
}

func (c *CLI) mailSend(args []string) error {
	const usage = `Usage: dieter mail send --subject TEXT (--body TEXT | --body-file PATH|-) [options]

Send a Markdown report to Dieter Mail on the target machine.

Options:
  --subject TEXT          One line, at most 200 characters
  --body TEXT             The Markdown body
  --body-file PATH|-      Read the body from PATH or stdin
  --important             Mark a failure or finding that needs action
  --operation-id ID       Retry key (at most 128 characters): a repeated send
                          returns the original message instead of a duplicate
  --from LABEL            Operators only: who is sending, e.g. backup.sh
                          (at most 64 characters)
  --format text|json|id   Output format (default text)

The body is GitHub-flavored Markdown of at most 128 KiB and 4,000 lines (each
at most 8 KiB): headings, emphasis, inline code, links, lists, task lists,
quotes, rules, fenced code and tables. macOS, Android and iOS render mermaid,
vega-lite (or vegalite) and vega fences offline. Charts require inline JSON data;
external datasets and resource loads are blocked. Invalid or unsupported blocks
keep readable source. Raw HTML shows as text and images as links, never loaded.
Agent turns may send only when their conversation has mail access, at
most 10 messages per turn and 50 per conversation in any 24 hours.
`
	set := flags("mail send")
	subject := set.String("subject", "", "one-line subject")
	body := set.String("body", "", "Markdown body")
	bodyFile := set.String("body-file", "", "Markdown body file or -")
	important := set.Bool("important", false, "a failure that needs action")
	operation := set.String("operation-id", "", "retry key")
	from := set.String("from", "", "operator label")
	format := set.String("format", "text", "text, json or id")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("unexpected arguments; quote the subject and pass the body with --body or --body-file\n\n" + usage)
	}
	if strings.TrimSpace(*subject) == "" {
		return errors.New("--subject is required\n\n" + usage)
	}
	text, err := c.mailBody(*body, *bodyFile)
	if err != nil {
		return err
	}
	if strings.TrimSpace(text) == "" {
		return errors.New("a body is required: --body or --body-file\n\n" + usage)
	}
	request := &dieterv1.SendMailRequest{Subject: *subject, Body: text, OperationId: *operation, From: *from}
	if *important {
		request.Importance = dieterv1.MailImportance_MAIL_IMPORTANCE_HIGH
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	header, err := client.SendMail(rpcCtx, request)
	if err != nil {
		return err
	}
	switch *format {
	case "json":
		return protoJSONOut(c.Out, header)
	case "id":
		_, err = fmt.Fprintln(c.Out, header.GetId())
		return err
	}
	_, err = fmt.Fprintf(c.Out, "Sent %s: %s\n", header.GetId(), header.GetSubject())
	return err
}

func mailFolderFlag(value string, all bool) (dieterv1.MailFolder, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "inbox":
		return dieterv1.MailFolder_MAIL_FOLDER_INBOX, nil
	case "archive":
		return dieterv1.MailFolder_MAIL_FOLDER_ARCHIVE, nil
	case "trash":
		return dieterv1.MailFolder_MAIL_FOLDER_TRASH, nil
	case "all":
		if all {
			return dieterv1.MailFolder_MAIL_FOLDER_UNSPECIFIED, nil
		}
	case "":
		return dieterv1.MailFolder_MAIL_FOLDER_UNSPECIFIED, nil
	}
	if all {
		return 0, errors.New("--folder is inbox, archive, trash or all")
	}
	return 0, errors.New("--folder is inbox, archive or trash")
}

func mailFolderLabel(folder dieterv1.MailFolder) string {
	switch folder {
	case dieterv1.MailFolder_MAIL_FOLDER_ARCHIVE:
		return "archive"
	case dieterv1.MailFolder_MAIL_FOLDER_TRASH:
		return "trash"
	}
	return "inbox"
}

// mailFrom is the sender a row names: the schedule, the conversation, the
// operator's label, or the operator.
func mailFrom(sender *dieterv1.MailSender) string {
	switch {
	case sender.GetScheduleName() != "":
		return sender.GetScheduleName()
	case sender.GetTitle() != "":
		return sender.GetTitle()
	case sender.GetLabel() != "":
		return sender.GetLabel()
	case sender.GetDeviceId() != "":
		return "operator on " + sender.GetDeviceId()
	}
	return "operator"
}

func mailMarkers(header *dieterv1.MailHeader) string {
	markers := ""
	for _, marker := range []struct {
		on   bool
		text string
	}{
		{!header.GetRead(), "●"}, {header.GetFlagged(), "⚑"}, {header.GetImportance() == dieterv1.MailImportance_MAIL_IMPORTANCE_HIGH, "!"},
	} {
		if marker.on {
			markers += marker.text
		}
	}
	return markers
}

func mailTime(value string) string {
	at, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return value
	}
	return at.Local().Format("2006-01-02 15:04")
}

func writeMailRows(out io.Writer, headers []*dieterv1.MailHeader) error {
	writer := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "ID\tMARK\tSENT\tFOLDER\tFROM\tSUBJECT")
	for _, header := range headers {
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\n", header.GetId(), mailMarkers(header), mailTime(header.GetSentAt()),
			mailFolderLabel(header.GetFolder()), mailFrom(header.GetSender()), header.GetSubject())
	}
	return writer.Flush()
}

func (c *CLI) mailList(args []string) error {
	const usage = `Usage: dieter mail list [--folder inbox|archive|trash|all] [--unread] [--flagged] [--limit N] [--before ID] [--format table|json]

List the target machine's mail, newest first: the Inbox unless --folder names
another folder or all of them, at most --limit messages (default 50, at most
500). --before continues after a message ID. MARK shows ● unread, ⚑ flagged
and ! important.
`
	set := flags("mail list")
	folder := set.String("folder", "inbox", "inbox, archive, trash or all")
	unread := set.Bool("unread", false, "only unread messages")
	flagged := set.Bool("flagged", false, "only flagged messages")
	limit := set.Int("limit", 0, "page size")
	before := set.String("before", "", "continue after this message ID")
	format := set.String("format", "table", "table or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("unexpected arguments\n\n" + usage)
	}
	selected, err := mailFolderFlag(*folder, true)
	if err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	page, err := client.ListMail(rpcCtx, &dieterv1.ListMailRequest{Folder: selected, UnreadOnly: *unread, FlaggedOnly: *flagged, BeforeId: *before, Limit: int32(*limit)})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, page)
	}
	if len(page.GetMessages()) == 0 {
		_, err = fmt.Fprintln(c.Out, "No mail.")
		return err
	}
	if err := writeMailRows(c.Out, page.GetMessages()); err != nil {
		return err
	}
	if page.GetHasMore() {
		_, err = fmt.Fprintf(c.Out, "More: dieter mail list --before %s\n", page.GetMessages()[len(page.GetMessages())-1].GetId())
	}
	return err
}

func (c *CLI) mailShow(args []string) error {
	const usage = `Usage: dieter mail show [--raw] [--format text|json] ID

Print one message: its header, then its Markdown body. --raw prints only the
body. Showing a message does not mark it read; run dieter mail mark ID --read.
`
	set := flags("mail show")
	raw := set.Bool("raw", false, "print only the Markdown body")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one message ID is required\n\n" + usage)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	message, err := client.GetMail(rpcCtx, &dieterv1.MailRef{Id: set.Arg(0)})
	if err != nil {
		return err
	}
	switch {
	case *format == "json":
		return protoJSONOut(c.Out, message)
	case *raw:
		_, err = io.WriteString(c.Out, message.GetBody())
		return err
	}
	header, sender := message.GetHeader(), message.GetHeader().GetSender()
	writer := tabwriter.NewWriter(c.Out, 0, 4, 2, ' ', 0)
	fmt.Fprintf(writer, "Subject:\t%s\n", header.GetSubject())
	from := mailFrom(sender)
	var details []string
	if sender.GetScheduleName() != "" && sender.GetTitle() != "" {
		details = append(details, sender.GetTitle())
	}
	if sender.GetCardId() != "" {
		details = append(details, sender.GetScope()+" "+sender.GetCardId())
	}
	if sender.GetProjectName() != "" {
		details = append(details, "project "+sender.GetProjectName())
	}
	if sender.GetHarness() != "" {
		details = append(details, strings.TrimSpace(sender.GetHarness()+" "+sender.GetModel()))
	}
	if len(details) > 0 {
		from += " (" + strings.Join(details, ", ") + ")"
	}
	fmt.Fprintf(writer, "From:\t%s\n", from)
	fmt.Fprintf(writer, "Sent:\t%s\n", header.GetSentAt())
	state := []string{mailFolderLabel(header.GetFolder())}
	if header.GetRead() {
		state = append(state, "read")
	} else {
		state = append(state, "unread")
	}
	if header.GetFlagged() {
		state = append(state, "flagged")
	}
	if header.GetImportance() == dieterv1.MailImportance_MAIL_IMPORTANCE_HIGH {
		state = append(state, "important")
	}
	fmt.Fprintf(writer, "State:\t%s\n", strings.Join(state, ", "))
	fmt.Fprintf(writer, "ID:\t%s\n", header.GetId())
	if err := writer.Flush(); err != nil {
		return err
	}
	body := message.GetBody()
	if !strings.HasSuffix(body, "\n") {
		body += "\n"
	}
	_, err = fmt.Fprintf(c.Out, "\n%s", body)
	return err
}

// missingMail fails for the requested IDs a response did not return.
func missingMail(requested, found []string) error {
	var missing []string
	for _, id := range requested {
		if !slices.Contains(found, id) && !slices.Contains(missing, id) {
			missing = append(missing, id)
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("mail not found: %s", strings.Join(missing, ", "))
	}
	return nil
}

func (c *CLI) mailMark(args []string) error {
	const usage = `Usage: dieter mail mark [--read|--unread] [--flag|--unflag] [--folder inbox|archive|trash] [--format table|json] ID...

Change the state of up to 500 messages: read or unread, flagged or not, and
the folder. Combine the changes as needed; at least one is required. Move a
message to the Trash with --folder trash, and back with --folder inbox.
`
	set := flags("mail mark")
	read := set.Bool("read", false, "mark read")
	unread := set.Bool("unread", false, "mark unread")
	flag := set.Bool("flag", false, "flag")
	unflag := set.Bool("unflag", false, "remove the flag")
	folder := set.String("folder", "", "inbox, archive or trash")
	format := set.String("format", "table", "table or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if *read && *unread || *flag && *unflag {
		return errors.New("pass --read or --unread and --flag or --unflag, not both of a pair")
	}
	selected, err := mailFolderFlag(*folder, false)
	if err != nil {
		return err
	}
	request := &dieterv1.UpdateMailRequest{Ids: set.Args(), Folder: selected}
	if *read || *unread {
		value := *read
		request.Read = &value
	}
	if *flag || *unflag {
		value := *flag
		request.Flagged = &value
	}
	if len(request.Ids) == 0 {
		return errors.New("at least one message ID is required\n\n" + usage)
	}
	if request.Read == nil && request.Flagged == nil && selected == dieterv1.MailFolder_MAIL_FOLDER_UNSPECIFIED {
		return errors.New("nothing to change: pass --read, --unread, --flag, --unflag or --folder\n\n" + usage)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	response, err := client.UpdateMail(rpcCtx, request)
	if err != nil {
		return err
	}
	var found []string
	for _, header := range response.GetMessages() {
		found = append(found, header.GetId())
	}
	if *format == "json" {
		err = protoJSONOut(c.Out, response)
	} else if len(found) > 0 {
		err = writeMailRows(c.Out, response.GetMessages())
	}
	return errors.Join(err, missingMail(request.Ids, found))
}

func (c *CLI) mailDelete(args []string) error {
	const usage = `Usage: dieter mail delete (ID... | --empty-trash) [--format text|json]

Delete up to 500 messages for good, or every message in the Trash. To keep a
way back, move messages to the Trash instead: dieter mail mark ID --folder
trash. The Trash empties itself after 30 days.
`
	set := flags("mail delete")
	emptyTrash := set.Bool("empty-trash", false, "delete every message in the Trash")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if (set.NArg() == 0) == !*emptyTrash {
		return errors.New("name message IDs or pass --empty-trash\n\n" + usage)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	response, err := client.DeleteMail(rpcCtx, &dieterv1.DeleteMailRequest{Ids: set.Args(), EmptyTrash: *emptyTrash})
	if err != nil {
		return err
	}
	if *format == "json" {
		err = protoJSONOut(c.Out, response)
	} else {
		_, err = fmt.Fprintf(c.Out, "Deleted %d %s.\n", len(response.GetDeletedIds()), map[bool]string{true: "message", false: "messages"}[len(response.GetDeletedIds()) == 1])
	}
	return errors.Join(err, missingMail(set.Args(), response.GetDeletedIds()))
}
