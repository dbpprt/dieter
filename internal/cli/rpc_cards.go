package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"slices"
	"strings"
	"syscall"
	"text/tabwriter"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/model"
)

const cardHelp = `Usage: dieter card <action>

Actions:
  create       Create a board conversation
  list         Search board conversations
  show         Show card metadata and comments
  context      Print bounded agent context
  transcript   Read the durable conversation
  poll         Fetch one bounded conversation update
  watch        Stream conversation updates as JSON Lines
  tool-output  Fetch a full tool input/output payload
  fork         Fork a completed conversation into a standalone chat
  send         Submit a human message to the daemon-owned turn lifecycle
  comment      Add a non-triggering annotation
  move         Move a card between workflow lanes
  start        Start a draft card idempotently
  labels       Replace board-label assignments
  cancel       Cancel the active turn
  rename       Rename a card
  update       Update title and initial prompt
  archive      Archive a card
  unarchive    Restore a card
  workspace    Select the project directory or an isolated worktree
`

const chatHelp = `Usage: dieter chat <action>

Actions:
  create, list, show, context, transcript, watch, tool-output, fork, send,
  comment, cancel, rename, update, archive, unarchive, workspace, pin, unpin

Standalone chats use the same durable conversation and workspace operations as
cards but are not assigned to a board lane.
`

func (c *CLI) rpcCard(args []string, chat bool) error {
	if groupHelp(args) {
		if chat {
			fmt.Fprint(c.Out, chatHelp)
		} else {
			fmt.Fprint(c.Out, cardHelp)
		}
		return nil
	}
	switch args[0] {
	case "create":
		return c.rpcCardCreate(args[1:], chat)
	case "list", "ls":
		return c.rpcCardList(args[1:], chat)
	case "show":
		return c.rpcCardShow(args[1:], false)
	case "context":
		return c.rpcCardShow(args[1:], true)
	case "transcript":
		return c.rpcCardTranscript(args[1:])
	case "poll":
		return c.rpcCardPoll(args[1:])
	case "watch":
		return c.rpcCardWatch(args[1:])
	case "tool-output":
		return c.rpcCardToolOutput(args[1:])
	case "fork":
		return c.rpcCardFork(args[1:])
	case "send":
		return c.rpcCardSend(args[1:])
	case "comment":
		return c.rpcCardComment(args[1:])
	case "move":
		if chat {
			return errors.New("standalone chats do not have board lanes")
		}
		return c.rpcCardMove(args[1:])
	case "start":
		return c.rpcCardStart(args[1:])
	case "labels":
		return c.rpcCardLabels(args[1:])
	case "cancel":
		return c.rpcCardCancel(args[1:])
	case "rename":
		return c.rpcCardRename(args[1:])
	case "update":
		return c.rpcCardUpdate(args[1:])
	case "archive":
		return c.rpcCardArchive(args[1:], true)
	case "unarchive":
		return c.rpcCardArchive(args[1:], false)
	case "workspace":
		return c.rpcCardWorkspace(args[1:])
	case "pin":
		if !chat {
			return errors.New("only standalone chats can be pinned")
		}
		return c.rpcChatPin(args[1:], true)
	case "unpin":
		if !chat {
			return errors.New("only standalone chats can be unpinned")
		}
		return c.rpcChatPin(args[1:], false)
	default:
		group := "card"
		if chat {
			group = "chat"
		}
		return fmt.Errorf("unknown %s action %q; run `dieter %s --help`", group, args[0], group)
	}
}

func messageParts(parts []model.UIMessagePart) []*dieterv1.MessagePart {
	result := make([]*dieterv1.MessagePart, 0, len(parts))
	for _, part := range parts {
		result = append(result, &dieterv1.MessagePart{
			Type: part.Type, Text: part.Text, MediaType: part.MediaType, Filename: part.Filename,
			Url: part.URL, State: part.State, ToolCallId: part.ToolCallID, ToolName: part.ToolName,
			InputJson: append([]byte(nil), part.Input...), OutputJson: append([]byte(nil), part.Output...), ErrorText: part.ErrorText,
		})
	}
	return result
}

func (c *CLI) rpcCardCreate(args []string, chat bool) error {
	group := "card"
	usage := `Usage: dieter card create --project PROJECT --board BOARD --title TITLE --workspace project|worktree [options]

Options:
  --lane todo|running       Todo creates a draft; Running starts immediately
  --prompt TEXT             Initial task brief
  --prompt-file FILE        Read the task brief from FILE or -
  --attach FILE             Attach a file; repeat up to four times
  --provider HARNESS        Harness provider
  --model MODEL             Model for the first turn
  --effort EFFORT           Reasoning or thinking effort
  --provider-option K=V     Provider option; repeat as needed
  --labels LABELS           Comma-separated label IDs
  --workspace MODE          project or worktree
  --branch BRANCH           Optional worktree branch
  --base-branch BRANCH      Optional worktree base branch
  --format json|id          Output format
`
	if chat {
		group = "chat"
		usage = strings.Replace(usage, "card create --project PROJECT --board BOARD", "chat create --project PROJECT", 1)
	}
	set := flags(group + " create")
	projectRef := set.String("project", "", "project ID or name")
	boardRef := set.String("board", "", "board ID or name")
	title := set.String("title", "", "conversation title")
	lane := set.String("lane", "todo", "todo or running")
	prompt := set.String("prompt", "", "initial task brief")
	promptFile := set.String("prompt-file", "", "initial task brief file")
	var attachmentFiles repeatedStrings
	set.Var(&attachmentFiles, "attach", "attachment file")
	provider := set.String("provider", "", "harness provider")
	modelName := set.String("model", "", "model")
	effort := set.String("effort", "", "reasoning effort")
	providerOptions := parameterFlags{}
	set.Var(&providerOptions, "provider-option", "provider option KEY=VALUE")
	labels := set.String("labels", "", "comma-separated label IDs")
	workspaceMode := set.String("workspace", "", "project or worktree")
	branch := set.String("branch", "", "worktree branch")
	baseBranch := set.String("base-branch", "", "worktree base branch")
	format := set.String("format", "json", "json or id")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 || strings.TrimSpace(*projectRef) == "" || strings.TrimSpace(*title) == "" || strings.TrimSpace(*workspaceMode) == "" {
		return errors.New("--project, --title, and --workspace are required")
	}
	if !chat && strings.TrimSpace(*boardRef) == "" {
		return errors.New("--board is required")
	}
	promptValue, err := textValue(*prompt, *promptFile, c.In)
	if err != nil {
		return err
	}
	attachments, err := attachmentParts(attachmentFiles)
	if err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	project, state, err := c.projectState(ctx, *projectRef)
	if err != nil {
		return err
	}
	boardID := ""
	if !chat {
		board, err := resolveProtoBoard(state, project.GetId(), *boardRef)
		if err != nil {
			return err
		}
		boardID = board.GetId()
	}
	commandID, err := newCLICardCommandID()
	if err != nil {
		return err
	}
	request := &dieterv1.CreateConversationRequest{
		ProjectId: project.GetId(), BoardId: boardID, Lane: *lane, Title: *title, Prompt: promptValue,
		Provider: *provider, Model: *modelName, Effort: *effort, ProviderOptions: providerOptions,
		LabelIds: splitCSV(*labels), DeferStart: !chat && *lane != "running", Attachments: messageParts(attachments),
		ClientId: "dieter-cli", CommandId: commandID, WorkspaceMode: *workspaceMode,
		WorkspaceBranch: *branch, WorkspaceBaseBranch: *baseBranch,
	}
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	var value *dieterv1.Card
	if chat {
		value, err = client.CreateChat(rpcCtx, request)
	} else {
		value, err = client.CreateCard(rpcCtx, request)
	}
	if err != nil {
		return err
	}
	if *format == "id" {
		fmt.Fprintln(c.Out, value.GetId())
		return nil
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcCardList(args []string, chat bool) error {
	group := "card"
	usage := "Usage: dieter card list [--project PROJECT] [--board BOARD] [--lane LANE] [--label LABEL] [--status STATUS] [--query TEXT] [--archived] [--limit N] [--format table|json|jsonl|ids]\n"
	if chat {
		group = "chat"
		usage = "Usage: dieter chat list [--archived] [--format table|json|jsonl|ids]\n"
	}
	set := flags(group + " list")
	project := set.String("project", "", "project ID")
	board := set.String("board", "", "board ID")
	lane := set.String("lane", "", "workflow lane")
	label := set.String("label", "", "label ID")
	runtimeStatus := set.String("status", "", "runtime status")
	query := set.String("query", "", "search query")
	archived := set.Bool("archived", false, "include archived conversations")
	limit := set.Int("limit", 0, "maximum results")
	format := set.String("format", "table", "table, json, jsonl, or ids")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	var items []*dieterv1.Card
	if chat {
		value, err := client.ListChats(rpcCtx, &dieterv1.ListChatsRequest{IncludeArchived: *archived})
		if err != nil {
			return err
		}
		items = value.GetChats()
	} else {
		value, err := client.GetState(rpcCtx, &dieterv1.GetStateRequest{
			ProjectId: *project, BoardId: *board, Lane: *lane, Runtime: *runtimeStatus,
			Query: *query, LabelId: *label, Limit: int32(*limit),
		})
		if err != nil {
			return err
		}
		items = value.GetCards()
		if *archived {
			items = nil
			projectID := ""
			if *project != "" {
				projectValue, resolveErr := resolveProtoProject(value, *project)
				if resolveErr != nil {
					return resolveErr
				}
				projectID = projectValue.GetId()
			}
			boards := value.GetBoards()
			if *board != "" {
				boardValue, resolveErr := resolveProtoBoard(value, projectID, *board)
				if resolveErr != nil {
					return resolveErr
				}
				boards = []*dieterv1.Board{boardValue}
			}
			for _, boardValue := range boards {
				if projectID != "" && boardValue.GetProjectId() != projectID {
					continue
				}
				archivedCards, err := client.ListArchivedCards(rpcCtx, &dieterv1.BoardRef{BoardId: boardValue.GetId()})
				if err != nil {
					return err
				}
				items = append(items, archivedCards.GetCards()...)
			}
			filtered := items[:0]
			for _, item := range items {
				if *lane != "" && item.GetLane() != *lane || *runtimeStatus != "" && item.GetRuntime() != *runtimeStatus || *label != "" && !slices.Contains(item.GetLabelIds(), *label) {
					continue
				}
				if *query != "" && !strings.Contains(strings.ToLower(item.GetTitle()+"\n"+item.GetInitialPrompt()), strings.ToLower(*query)) {
					continue
				}
				filtered = append(filtered, item)
				if *limit > 0 && len(filtered) >= *limit {
					break
				}
			}
			items = filtered
		}
	}
	if *format == "json" {
		return jsonOut(c.Out, items)
	}
	writer := tabwriter.NewWriter(c.Out, 0, 3, 2, ' ', 0)
	for _, item := range items {
		switch *format {
		case "jsonl":
			if err := protoJSONLine(c.Out, item); err != nil {
				return err
			}
		case "ids":
			fmt.Fprintln(c.Out, item.GetId())
		default:
			fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\n", item.GetId(), item.GetLane(), item.GetRuntime(), item.GetProvider(), item.GetTitle())
		}
	}
	return writer.Flush()
}

func (c *CLI) getCard(ctx context.Context, reference string) (*dieterv1.CardDetail, error) {
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return nil, err
	}
	return client.GetCard(rpcCtx, &dieterv1.GetCardRequest{CardId: reference})
}

func (c *CLI) rpcCardShow(args []string, compact bool) error {
	action := "show"
	if compact {
		action = "context"
	}
	usage := fmt.Sprintf("Usage: dieter card %s CARD\n", action)
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one CARD is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	detail, err := c.getCard(ctx, args[0])
	if err != nil {
		return err
	}
	if compact {
		return jsonOut(c.Out, map[string]any{
			"cardId": detail.GetCard().GetId(), "project": detail.GetProject().GetName(),
			"projectPrompt": detail.GetProject().GetPrompt(), "board": detail.GetBoard().GetName(),
			"workflow": detail.GetBoard().GetWorkflow(), "lane": detail.GetCard().GetLane(),
			"task": detail.GetCard().GetInitialPrompt(), "comments": detail.GetComments(),
		})
	}
	return protoJSONOut(c.Out, detail)
}

func (c *CLI) rpcCardTranscript(args []string) error {
	const usage = "Usage: dieter card transcript [--last N] [--before INDEX] CARD\n"
	set := flags("card transcript")
	last := set.Int("last", 30, "message count")
	before := set.Int("before", -1, "exclusive message index")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one CARD is required")
	}
	request := &dieterv1.GetConversationRequest{CardId: set.Arg(0), Limit: int32(*last)}
	if *before >= 0 {
		value := int32(*before)
		request.Before = &value
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.GetConversation(rpcCtx, request)
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcCardWatch(args []string) error {
	const usage = "Usage: dieter card watch [--last N] [--after-seq N] [--count N] CARD\n"
	set := flags("card watch")
	last := set.Int("last", 30, "message count")
	after := set.Int64("after-seq", 0, "resume sequence")
	count := set.Int("count", 0, "stop after N frames")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one CARD is required")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	stream, err := client.WatchConversation(rpcCtx, &dieterv1.WatchConversationRequest{CardId: set.Arg(0), Limit: int32(*last), AfterSeq: *after})
	if err != nil {
		return err
	}
	for emitted := 0; ; emitted++ {
		value, err := stream.Recv()
		if err != nil {
			return streamEnd(err, ctx)
		}
		if err := protoJSONLine(c.Out, value); err != nil {
			return err
		}
		if *count > 0 && emitted+1 >= *count {
			return nil
		}
	}
}

func (c *CLI) rpcCardPoll(args []string) error {
	const usage = "Usage: dieter card poll [--last N] [--after-seq N] CARD\n"
	set := flags("card poll")
	last := set.Int("last", 30, "message count")
	after := set.Int64("after-seq", 0, "wait for changes after this sequence")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one CARD is required")
	}
	request := &dieterv1.PollConversationRequest{CardId: set.Arg(0), Limit: int32(*last)}
	set.Visit(func(item *flag.Flag) {
		if item.Name == "after-seq" {
			request.AfterSeq = after
		}
	})
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.PollConversation(rpcCtx, request)
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcCardToolOutput(args []string) error {
	const usage = "Usage: dieter card tool-output --message MESSAGE --tool-call TOOL [--revision REVISION] CARD\n"
	set := flags("card tool-output")
	messageID := set.String("message", "", "message ID")
	toolCallID := set.String("tool-call", "", "tool-call ID")
	revision := set.String("revision", "", "payload revision")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || *messageID == "" || *toolCallID == "" {
		return errors.New("CARD, --message, and --tool-call are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.GetToolOutput(rpcCtx, &dieterv1.GetToolOutputRequest{CardId: set.Arg(0), MessageId: *messageID, ToolCallId: *toolCallID, Revision: *revision})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcCardFork(args []string) error {
	const usage = "Usage: dieter card fork [--at MESSAGE_ID] [--title TITLE] [--format json|id] CARD\n"
	set := flags("card fork")
	messageID := set.String("at", "", "message boundary")
	title := set.String("title", "", "fork title")
	format := set.String("format", "json", "json or id")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one CARD is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.ForkChat(rpcCtx, &dieterv1.ForkChatRequest{SourceCardId: set.Arg(0), MessageId: *messageID, Title: *title})
	if err != nil {
		return err
	}
	if *format == "id" {
		fmt.Fprintln(c.Out, value.GetId())
		return nil
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcCardSend(args []string) error {
	const usage = "Usage: dieter card send [--message TEXT|--file FILE] [--attach FILE ...] [--provider P] [--model M] [--effort E] [--provider-option K=V] CARD\n"
	set := flags("card send")
	message := set.String("message", "", "message text")
	file := set.String("file", "", "message file or -")
	var attachmentFiles repeatedStrings
	set.Var(&attachmentFiles, "attach", "attachment file")
	provider := set.String("provider", "", "harness provider")
	modelName := set.String("model", "", "model")
	effort := set.String("effort", "", "reasoning effort")
	providerOptions := parameterFlags{}
	set.Var(&providerOptions, "provider-option", "provider option KEY=VALUE")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one CARD is required")
	}
	value, err := textValue(*message, *file, c.In)
	if err != nil {
		return err
	}
	parts := []model.UIMessagePart{}
	if value != "" {
		parts = append(parts, model.UIMessagePart{Type: "text", Text: value})
	}
	attachments, err := attachmentParts(attachmentFiles)
	if err != nil {
		return err
	}
	parts = append(parts, attachments...)
	if len(parts) == 0 {
		return errors.New("a message or attachment is required")
	}
	commandID, err := newCLICardCommandID()
	if err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	response, err := client.SendMessage(rpcCtx, &dieterv1.SendMessageRequest{
		CardId: set.Arg(0), Parts: messageParts(parts), Provider: *provider, Model: *modelName,
		Effort: *effort, ProviderOptions: providerOptions, ClientId: "dieter-cli", CommandId: commandID,
	})
	if err != nil {
		return err
	}
	if response.GetQueued() {
		fmt.Fprintln(c.Out, "queued")
	} else {
		fmt.Fprintln(c.Out, "sent")
	}
	return nil
}

func (c *CLI) rpcCardComment(args []string) error {
	const usage = "Usage: dieter card comment [--message TEXT|--file FILE] [--author NAME] CARD\n\nComments never wake the agent or count as approval.\n"
	set := flags("card comment")
	message := set.String("message", "", "comment text")
	file := set.String("file", "", "comment file or -")
	author := set.String("author", "Dieter CLI", "display author")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one CARD is required")
	}
	value, err := textValue(*message, *file, c.In)
	if err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	comment, err := client.AddComment(rpcCtx, &dieterv1.AddCommentRequest{CardId: set.Arg(0), Message: value, Name: *author})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, comment)
}

func (c *CLI) rpcCardMove(args []string) error {
	const usage = "Usage: dieter card move --lane todo|running|review|done [--position N] CARD\n"
	set := flags("card move")
	lane := set.String("lane", "", "workflow lane")
	position := set.Int64("position", -1, "fixed lane position")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || *lane == "" {
		return errors.New("CARD and --lane are required")
	}
	request := &dieterv1.MoveCardRequest{CardId: set.Arg(0), Lane: *lane}
	if *position >= 0 {
		request.Position = position
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.MoveCard(rpcCtx, request)
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcCardStart(args []string) error {
	const usage = "Usage: dieter card start CARD\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one CARD is required")
	}
	commandID, err := newCLICardCommandID()
	if err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.StartCard(rpcCtx, &dieterv1.StartCardRequest{CardId: args[0], ClientId: "dieter-cli", CommandId: commandID})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcCardLabels(args []string) error {
	const usage = "Usage: dieter card labels --set LABELS CARD\n\nLABELS is a comma-separated list of board label IDs; empty clears labels.\n"
	set := flags("card labels")
	labels := set.String("set", "", "comma-separated label IDs")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one CARD is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.SetCardLabels(rpcCtx, &dieterv1.SetCardLabelsRequest{CardId: set.Arg(0), LabelIds: splitCSV(*labels)})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcCardCancel(args []string) error {
	const usage = "Usage: dieter card cancel CARD\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one CARD is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	_, err = client.CancelCard(rpcCtx, &dieterv1.GetCardRequest{CardId: args[0]})
	return err
}

func (c *CLI) rpcCardRename(args []string) error {
	const usage = "Usage: dieter card rename --title TITLE CARD\n"
	set := flags("card rename")
	title := set.String("title", "", "new title")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || strings.TrimSpace(*title) == "" {
		return errors.New("CARD and --title are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.RenameCard(rpcCtx, &dieterv1.RenameCardRequest{CardId: set.Arg(0), Title: *title})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcCardUpdate(args []string) error {
	const usage = "Usage: dieter card update [--title TITLE] [--prompt TEXT|--prompt-file FILE] CARD\n"
	set := flags("card update")
	title, prompt := &optional{}, &optional{}
	set.Var(title, "title", "title")
	set.Var(prompt, "prompt", "initial prompt")
	promptFile := set.String("prompt-file", "", "initial prompt file")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one CARD is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	detail, err := c.getCard(ctx, set.Arg(0))
	if err != nil {
		return err
	}
	titleValue := detail.GetCard().GetTitle()
	if title.set {
		titleValue = title.value
	}
	promptValue := detail.GetCard().GetInitialPrompt()
	if *promptFile != "" {
		promptValue, err = textValue("", *promptFile, c.In)
		if err != nil {
			return err
		}
	} else if prompt.set {
		promptValue = prompt.value
	}
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.UpdateCard(rpcCtx, &dieterv1.UpdateCardRequest{CardId: detail.GetCard().GetId(), Title: titleValue, InitialPrompt: promptValue})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcCardArchive(args []string, archived bool) error {
	action := "archive"
	if !archived {
		action = "unarchive"
	}
	usage := fmt.Sprintf("Usage: dieter card %s CARD\n", action)
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one CARD is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.ArchiveCard(rpcCtx, &dieterv1.ArchiveCardRequest{CardId: args[0], Archived: archived})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcCardWorkspace(args []string) error {
	const usage = "Usage: dieter card workspace --mode project|worktree [--branch BRANCH] [--base-branch BRANCH] CARD\n"
	set := flags("card workspace")
	mode := set.String("mode", "", "project or worktree")
	branch := set.String("branch", "", "worktree branch")
	baseBranch := set.String("base-branch", "", "worktree base branch")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || *mode == "" {
		return errors.New("CARD and --mode are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.UpdateConversationWorkspace(rpcCtx, &dieterv1.UpdateConversationWorkspaceRequest{CardId: set.Arg(0), Mode: *mode, Branch: *branch, BaseBranch: *baseBranch})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcChatPin(args []string, pinned bool) error {
	action := "pin"
	if !pinned {
		action = "unpin"
	}
	usage := fmt.Sprintf("Usage: dieter chat %s CHAT\n", action)
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one CHAT is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.PinChat(rpcCtx, &dieterv1.PinChatRequest{CardId: args[0], Pinned: pinned})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}
