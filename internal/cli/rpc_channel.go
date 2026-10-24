package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"text/tabwriter"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

const channelHelp = `Usage: dieter channel <list|messages|post|inbox|check|claims|release|pin|read|settings|watch|hook> [options]

Agent channels (experimental): one message channel per project on each
daemon, direct messages to cards, threads, pinned decisions and file claims
that keep agents sharing a checkout from overwriting each other. Inside an
agent turn (DIETER_TURN_TOKEN) the caller is that card's agent; otherwise you
act as a human. Channels are off until switched on with "channel settings".

  list      List this daemon's project channels with unread counts and members
  messages  Page a project channel or one thread
  post      Post to the project channel, a thread, or directly to cards
  inbox     Read a card's undelivered messages (an agent's own by default)
  check     Show who else is changing files, pinned decisions and recent notes
  claims    List live file claims
  release   Release a card's file claims
  pin       Pin a message as a decision, or remove the pin with --off
  read      Mark a project channel read for humans
  settings  Show or change the experimental switch (global, project, board)
  watch     Stream a project channel as JSON Lines
  hook      Harness hook adapter: reads hook JSON on stdin, prints the decision
`

type channelValues []string

func (values *channelValues) String() string { return strings.Join(*values, ",") }
func (values *channelValues) Set(value string) error {
	if value = strings.TrimSpace(value); value == "" {
		return errors.New("a value is required")
	}
	*values = append(*values, value)
	return nil
}

func (c *CLI) rpcChannel(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, channelHelp)
		return nil
	}
	action := args[0]
	usages := map[string]string{
		"list":     "[--format table|json]\nList this daemon's project channels: enabled state, unread count, live claims and members.",
		"messages": "--project PROJECT [--thread ID] [--after SEQ] [--before SEQ] [--limit N] [--format table|json]\nPage a project channel in sequence order (default: the newest 50 messages).",
		"post":     "[--project PROJECT] [--to CARD]... [--thread ID] [--kind note|request|done|decision] [--file PATH]... [--wake] [--operation ID] [--stdin] TEXT...\nPost at most 4096 bytes. Agents post to their own project; --to sends a direct message.\n--wake starts a turn for idle direct recipients within their wake budget. A decision is pinned.",
		"inbox":    "[--card CARD] [--peek] [--format text|json]\nPrint a card's undelivered messages and mark them delivered (--peek keeps them).\nAgents read their own inbox; humans name --card.",
		"check":    "[--card CARD] [--intent TEXT] [--format text|json] FILE...\nShow live claims by other cards on FILEs (relative to the card's workspace), pinned decisions\nand recent notes that mention them. An agent whose files are held is woken when they are free.",
		"claims":   "[--project PROJECT] [--format table|json]\nList live file claims: path, holder card, since when, and waiting cards.",
		"release":  "[--card CARD] [PATH...]\nRelease a card's claims (all without PATHs). Agents release their own; humans name --card.",
		"pin":      "--project PROJECT [--off] MESSAGE_ID\nPin a message as a decision that check returns for the files it mentions, or unpin it.",
		"read":     "--project PROJECT [--seq N]\nMark the project channel read for humans up to N (default: the newest message).",
		"settings": "[--global on|off | --project PROJECT --set on|off|inherit | --board BOARD --set on|off|inherit]\nShow or change the replicated experimental switch. A board overrides its project, a project\noverrides the global switch. Agents cannot change settings.",
		"watch":    "--project PROJECT [--after SEQ] [--count N]\nStream the project channel as JSON Lines: a reset frame with the newest page, then new and\nchanged messages, claims and the summary." + readRecoveryHelp,
		"hook":     "\nHarness hook adapter for agent channel file claims. Reads one hook JSON object (Claude Code or\nCodex PreToolUse format, at most 1 MiB) on stdin, prints the hook decision and exits 0.\nPrints nothing (no opinion) outside an agent turn or when the daemon is unavailable.",
	}
	detail, ok := usages[action]
	if !ok {
		return fmt.Errorf("unknown channel action %q", action)
	}
	usage := "Usage: dieter channel " + action
	if !strings.HasPrefix(detail, "\n") {
		usage += " "
	}
	usage += detail + "\n"
	if wantsHelp(args[1:]) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	set := flags("channel " + action)
	project := set.String("project", "", "project ID or name")
	board := set.String("board", "", "board ID")
	card := set.String("card", "", "card ID")
	thread := set.String("thread", "", "thread root message ID")
	kind := set.String("kind", "", "message kind")
	format := set.String("format", "", "output format")
	operation := set.String("operation", "", "stable post ID for retries")
	intent := set.String("intent", "", "what you are about to do")
	global := set.String("global", "", "global switch: on or off")
	value := set.String("set", "", "override: on, off or inherit")
	after := set.Int64("after", 0, "after sequence number")
	before := set.Int64("before", 0, "before sequence number")
	seq := set.Int64("seq", 0, "sequence number")
	limit := set.Int("limit", 0, "page size")
	count := set.Int("count", 0, "watch frame limit (zero watches until canceled)")
	wake := set.Bool("wake", false, "wake idle direct recipients")
	peek := set.Bool("peek", false, "do not mark delivered")
	off := set.Bool("off", false, "remove the pin")
	stdin := set.Bool("stdin", false, "read the message body from stdin")
	var to, files channelValues
	set.Var(&to, "to", "recipient card (repeatable)")
	set.Var(&files, "file", "related file (repeatable)")
	if _, err := parse(set, args[1:], usage, c.Out); err != nil {
		return err
	}
	if action == "hook" {
		return c.channelHook()
	}
	if c.env.TurnToken != "" && strings.TrimSpace(c.Machine) != "" {
		return errors.New("inside an agent turn, channel commands use the local daemon; omit --machine")
	}
	ctx, cancel := c.commandContext()
	if action == "watch" {
		cancel()
		ctx, cancel = signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	}
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	needProject := func() error {
		if *project == "" {
			return errors.New("--project is required\n\n" + usage)
		}
		return nil
	}
	switch action {
	case "list":
		response, err := client.ListChannels(rpcCtx, &dieterv1.ListChannelsRequest{})
		if err != nil {
			return err
		}
		if *format == "json" {
			return protoJSONOut(c.Out, response)
		}
		writer := tabwriter.NewWriter(c.Out, 0, 4, 2, ' ', 0)
		fmt.Fprintln(writer, "PROJECT\tNAME\tENABLED\tMESSAGES\tUNREAD\tCLAIMS\tMEMBERS")
		for _, channel := range response.GetChannels() {
			members := make([]string, 0, len(channel.GetMembers()))
			for _, member := range channel.GetMembers() {
				members = append(members, member.GetCardId()+"("+member.GetStatus()+")")
			}
			fmt.Fprintf(writer, "%s\t%s\t%t\t%d\t%d\t%d\t%s\n", channel.GetProjectId(), channel.GetProjectName(), channel.GetEnabled(), channel.GetLastSeq(), channel.GetUnread(), channel.GetClaims(), strings.Join(members, " "))
		}
		return writer.Flush()
	case "messages":
		if err := needProject(); err != nil {
			return err
		}
		page, err := client.ListChannelMessages(rpcCtx, &dieterv1.ListChannelMessagesRequest{ProjectId: *project, ThreadId: *thread, AfterSeq: *after, BeforeSeq: *before, Limit: int32(*limit)})
		if err != nil {
			return err
		}
		if *format == "json" {
			return protoJSONOut(c.Out, page)
		}
		return writeChannelMessages(c.Out, page.GetMessages())
	case "post":
		body := strings.Join(set.Args(), " ")
		if *stdin {
			raw, err := io.ReadAll(io.LimitReader(c.In, 4097))
			if err != nil {
				return err
			}
			body = string(raw)
		}
		if strings.TrimSpace(body) == "" {
			return errors.New("a message is required\n\n" + usage)
		}
		message, err := client.PostChannelMessage(rpcCtx, &dieterv1.PostChannelMessageRequest{
			ProjectId: *project, ToCardIds: to, ThreadId: *thread, Kind: *kind, Body: body, Files: files, Wake: *wake, OperationId: *operation,
		})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, message)
	case "inbox":
		page, err := client.GetChannelInbox(rpcCtx, &dieterv1.GetChannelInboxRequest{CardId: *card, Peek: *peek})
		if err != nil {
			return err
		}
		if *format == "json" {
			return protoJSONOut(c.Out, page)
		}
		if len(page.GetMessages()) == 0 {
			fmt.Fprintln(c.Out, "No unread channel messages.")
			return nil
		}
		return writeChannelMessages(c.Out, page.GetMessages())
	case "check":
		if set.NArg() == 0 {
			return errors.New("at least one FILE is required\n\n" + usage)
		}
		check, err := client.CheckChannelFiles(rpcCtx, &dieterv1.CheckChannelFilesRequest{CardId: *card, Files: set.Args(), Intent: *intent})
		if err != nil {
			return err
		}
		if *format == "json" {
			return protoJSONOut(c.Out, check)
		}
		fmt.Fprintln(c.Out, check.GetSummary())
		return nil
	case "claims":
		claims, err := client.ListChannelClaims(rpcCtx, &dieterv1.ListChannelClaimsRequest{ProjectId: *project})
		if err != nil {
			return err
		}
		if *format == "json" {
			return protoJSONOut(c.Out, claims)
		}
		writer := tabwriter.NewWriter(c.Out, 0, 4, 2, ' ', 0)
		fmt.Fprintln(writer, "PATH\tCARD\tTITLE\tSINCE\tWAITING")
		for _, claim := range claims.GetClaims() {
			fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\n", claim.GetPath(), claim.GetCardId(), claim.GetCardTitle(), claim.GetSince(), strings.Join(claim.GetWaitingCardIds(), ","))
		}
		return writer.Flush()
	case "release":
		released, err := client.ReleaseChannelClaims(rpcCtx, &dieterv1.ReleaseChannelClaimsRequest{CardId: *card, Paths: set.Args()})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, released)
	case "pin":
		if err := needProject(); err != nil {
			return err
		}
		if set.NArg() != 1 {
			return errors.New("exactly one MESSAGE_ID is required\n\n" + usage)
		}
		message, err := client.PinChannelMessage(rpcCtx, &dieterv1.PinChannelMessageRequest{ProjectId: *project, MessageId: set.Arg(0), Pinned: !*off})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, message)
	case "read":
		if err := needProject(); err != nil {
			return err
		}
		target := *seq
		if target == 0 {
			page, err := client.ListChannelMessages(rpcCtx, &dieterv1.ListChannelMessagesRequest{ProjectId: *project, Limit: 1})
			if err != nil {
				return err
			}
			target = page.GetLastSeq()
		}
		if _, err := client.MarkChannelRead(rpcCtx, &dieterv1.MarkChannelReadRequest{ProjectId: *project, Seq: target}); err != nil {
			return err
		}
		fmt.Fprintf(c.Out, "read through %d\n", target)
		return nil
	case "settings":
		var request *dieterv1.SetChannelSettingRequest
		switch {
		case *global != "":
			request = &dieterv1.SetChannelSettingRequest{Scope: "global", Value: *global}
		case *project != "":
			request = &dieterv1.SetChannelSettingRequest{Scope: "project", Id: *project, Value: *value}
		case *board != "":
			request = &dieterv1.SetChannelSettingRequest{Scope: "board", Id: *board, Value: *value}
		}
		if request == nil {
			settings, err := client.GetChannelSettings(rpcCtx, &dieterv1.GetChannelSettingsRequest{})
			if err != nil {
				return err
			}
			return protoJSONOut(c.Out, settings)
		}
		if request.Scope != "global" && request.Value == "" {
			return errors.New("--set on|off|inherit is required\n\n" + usage)
		}
		settings, err := client.SetChannelSetting(rpcCtx, request)
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, settings)
	case "watch":
		if err := needProject(); err != nil {
			return err
		}
		stream, err := client.WatchChannel(rpcCtx, &dieterv1.WatchChannelRequest{ProjectId: *project, AfterSeq: *after})
		if err != nil {
			return err
		}
		for n := 0; *count == 0 || n < *count; n++ {
			frame, err := stream.Recv()
			if err != nil {
				return streamEnd(err, ctx)
			}
			if err = protoJSONLine(c.Out, frame); err != nil {
				return streamEnd(err, ctx)
			}
		}
		return nil
	}
	return nil
}

// channelHook answers a harness hook. It never fails the hook: any problem
// prints a diagnostic to stderr and no decision, so the harness proceeds.
func (c *CLI) channelHook() error {
	event, err := io.ReadAll(io.LimitReader(c.In, 1<<20))
	if err != nil || len(strings.TrimSpace(string(event))) == 0 {
		return nil
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		fmt.Fprintf(c.Err, "dieter channel hook: %v\n", err)
		return nil
	}
	response, err := client.HandleChannelHook(rpcCtx, &dieterv1.ChannelHookRequest{EventJson: event})
	if err != nil {
		fmt.Fprintf(c.Err, "dieter channel hook: %v\n", err)
		return nil
	}
	if output := response.GetOutputJson(); len(output) > 0 {
		_, _ = c.Out.Write(output)
		fmt.Fprintln(c.Out)
	}
	return nil
}

func writeChannelMessages(out io.Writer, messages []*dieterv1.ChannelMessage) error {
	for _, message := range messages {
		author := message.GetAuthor()
		from := author.GetKind()
		if author.GetCardId() != "" {
			from = fmt.Sprintf("%s %s '%s'", author.GetKind(), author.GetCardId(), author.GetTitle())
		}
		header := fmt.Sprintf("#%d %s %s (%s)", message.GetSeq(), message.GetId(), from, message.GetKind())
		if len(message.GetToCardIds()) > 0 {
			header += " to " + strings.Join(message.GetToCardIds(), ",")
		}
		if message.GetThreadId() != "" {
			header += " in thread " + message.GetThreadId()
		}
		if message.GetPinned() {
			header += " [pinned]"
		}
		if _, err := fmt.Fprintf(out, "%s %s\n%s\n\n", header, message.GetCreatedAt(), message.GetBody()); err != nil {
			return err
		}
	}
	return nil
}
