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

const terminalHelp = `Usage: dieter terminal <action>

Actions:
  list [scope]                 List daemon-owned terminal sessions
  create [scope]               Create a PTY on the target daemon
  attach TERMINAL              Stream output and forward stdin until exit
  watch TERMINAL               Stream terminal frames as content or JSON Lines
  write --data TEXT TERMINAL   Write bytes to a running PTY
  resize --columns N --rows N TERMINAL
  rename --name NAME TERMINAL
  close TERMINAL               Stop and remove a terminal session

Scope is exactly one of --project PROJECT or --card CARD.
`

func (c *CLI) rpcTerminal(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, terminalHelp)
		return nil
	}
	switch args[0] {
	case "list", "ls":
		return c.rpcTerminalList(args[1:])
	case "create", "new":
		return c.rpcTerminalCreate(args[1:])
	case "attach":
		return c.rpcTerminalAttach(args[1:])
	case "watch":
		return c.rpcTerminalWatch(args[1:])
	case "write", "send":
		return c.rpcTerminalWrite(args[1:])
	case "resize":
		return c.rpcTerminalResize(args[1:])
	case "rename":
		return c.rpcTerminalRename(args[1:])
	case "close", "delete", "remove", "rm":
		return c.rpcTerminalClose(args[1:])
	default:
		return fmt.Errorf("unknown terminal action %q; run `dieter terminal --help`", args[0])
	}
}

func (c *CLI) terminalScope(ctx context.Context, client dieterv1.DieterServiceClient, rpcCtx context.Context, projectRef, cardID string, optional bool) (string, string, error) {
	projectRef, cardID = strings.TrimSpace(projectRef), strings.TrimSpace(cardID)
	if optional && projectRef == "" && cardID == "" {
		return "", "", nil
	}
	return c.resolveFileScope(ctx, client, rpcCtx, projectRef, cardID)
}

func resolveTerminal(items []*dieterv1.Terminal, reference string) (*dieterv1.Terminal, error) {
	var matches []*dieterv1.Terminal
	for _, item := range items {
		if item.GetId() == reference || strings.EqualFold(item.GetName(), reference) {
			matches = append(matches, item)
		}
	}
	if len(matches) == 0 {
		return nil, fmt.Errorf("terminal %q was not found on the target daemon", reference)
	}
	if len(matches) > 1 {
		return nil, fmt.Errorf("terminal name %q is ambiguous; use its exact ID", reference)
	}
	return matches[0], nil
}

func (c *CLI) resolveTerminal(ctx context.Context, client dieterv1.DieterServiceClient, rpcCtx context.Context, reference string) (*dieterv1.Terminal, error) {
	value, err := client.ListTerminals(rpcCtx, &dieterv1.ListTerminalsRequest{})
	if err != nil {
		return nil, err
	}
	return resolveTerminal(value.GetTerminals(), reference)
}

func (c *CLI) rpcTerminalList(args []string) error {
	const usage = "Usage: dieter terminal list [--project PROJECT|--card CARD] [--format table|json|jsonl|ids]\n"
	set := flags("terminal list")
	project, card := addFileScopeFlags(set)
	format := set.String("format", "table", "table, json, jsonl, or ids")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 || (*project != "" && *card != "") {
		return errors.New("no positional arguments and at most one scope are accepted")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	projectID, cardID, err := c.terminalScope(ctx, client, rpcCtx, *project, *card, true)
	if err != nil {
		return err
	}
	value, err := client.ListTerminals(rpcCtx, &dieterv1.ListTerminalsRequest{ProjectId: projectID, CardId: cardID})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	writer := tabwriter.NewWriter(c.Out, 0, 3, 2, ' ', 0)
	if *format == "table" {
		fmt.Fprintln(writer, "ID\tSTATUS\tSIZE\tNAME\tDIRECTORY")
	}
	for _, item := range value.GetTerminals() {
		switch *format {
		case "jsonl":
			if err := protoJSONLine(c.Out, item); err != nil {
				return err
			}
		case "ids":
			fmt.Fprintln(c.Out, item.GetId())
		default:
			fmt.Fprintf(writer, "%s\t%s\t%dx%d\t%s\t%s\n", item.GetId(), item.GetStatus(), item.GetColumns(), item.GetRows(), item.GetName(), item.GetWorkingDirectory())
		}
	}
	return writer.Flush()
}

func (c *CLI) rpcTerminalCreate(args []string) error {
	const usage = "Usage: dieter terminal create (--project PROJECT|--card CARD) [--name NAME] [--shell PATH] [--directory PATH] [--columns N] [--rows N] [--format json|id]\n"
	set := flags("terminal create")
	project, card := addFileScopeFlags(set)
	name := set.String("name", "", "terminal display name")
	shell := set.String("shell", "", "shell executable; daemon default when empty")
	directory := set.String("directory", "", "working directory within project/workspace")
	columns := set.Int("columns", 120, "terminal columns")
	rows := set.Int("rows", 36, "terminal rows")
	format := set.String("format", "json", "json or id")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("terminal create does not accept positional arguments")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	projectID, cardID, err := c.terminalScope(ctx, client, rpcCtx, *project, *card, false)
	if err != nil {
		return err
	}
	value, err := client.CreateTerminal(rpcCtx, &dieterv1.CreateTerminalRequest{ProjectId: projectID, CardId: cardID, Name: *name, Shell: *shell, WorkingDirectory: *directory, Columns: int32(*columns), Rows: int32(*rows)})
	if err != nil {
		return err
	}
	if *format == "id" {
		fmt.Fprintln(c.Out, value.GetId())
		return nil
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcTerminalWatch(args []string) error {
	const usage = "Usage: dieter terminal watch [--after SEQUENCE] [--format content|jsonl] [--count N] TERMINAL\n"
	set := flags("terminal watch")
	after := set.Uint64("after", 0, "last received sequence")
	format := set.String("format", "content", "content or jsonl")
	count := set.Int("count", 0, "stop after N frames; zero streams through exit")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one TERMINAL is required")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	terminal, err := c.resolveTerminal(ctx, client, rpcCtx, set.Arg(0))
	if err != nil {
		return err
	}
	stream, err := client.WatchTerminal(rpcCtx, &dieterv1.WatchTerminalRequest{TerminalId: terminal.GetId(), AfterSequence: *after, HeartbeatMs: 1_000})
	if err != nil {
		return err
	}
	for emitted := 0; ; emitted++ {
		frame, receiveErr := stream.Recv()
		if receiveErr != nil {
			return streamEnd(receiveErr, ctx)
		}
		if *format == "jsonl" {
			if err := protoJSONLine(c.Out, frame); err != nil {
				return err
			}
		} else if _, err := c.Out.Write(frame.GetData()); err != nil {
			return err
		}
		if *count > 0 && emitted+1 >= *count {
			return nil
		}
		if frame.GetTerminal().GetStatus() != "running" && !frame.GetHeartbeat() {
			return nil
		}
	}
}

func (c *CLI) rpcTerminalAttach(args []string) error {
	const usage = "Usage: dieter terminal attach [--after SEQUENCE] [--no-input] TERMINAL\n"
	set := flags("terminal attach")
	after := set.Uint64("after", 0, "last received output sequence")
	noInput := set.Bool("no-input", false, "do not forward stdin")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one TERMINAL is required")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	terminal, err := c.resolveTerminal(ctx, client, rpcCtx, set.Arg(0))
	if err != nil {
		return err
	}
	if !*noInput {
		go func() {
			buffer := make([]byte, 32<<10)
			for {
				count, readErr := c.In.Read(buffer)
				if count > 0 {
					_, _ = client.WriteTerminal(rpcCtx, &dieterv1.TerminalInputRequest{TerminalId: terminal.GetId(), Data: append([]byte(nil), buffer[:count]...)})
				}
				if readErr != nil {
					return
				}
			}
		}()
	}
	stream, err := client.WatchTerminal(rpcCtx, &dieterv1.WatchTerminalRequest{TerminalId: terminal.GetId(), AfterSequence: *after, HeartbeatMs: 1_000})
	if err != nil {
		return err
	}
	for {
		frame, receiveErr := stream.Recv()
		if receiveErr != nil {
			return streamEnd(receiveErr, ctx)
		}
		if _, err := c.Out.Write(frame.GetData()); err != nil {
			return err
		}
		if frame.GetTerminal().GetStatus() != "running" && !frame.GetHeartbeat() {
			return nil
		}
	}
}

func (c *CLI) rpcTerminalWrite(args []string) error {
	const usage = "Usage: dieter terminal write (--data TEXT|--file FILE|--file -) TERMINAL\n"
	set := flags("terminal write")
	data := set.String("data", "", "input text")
	file := set.String("file", "", "read input bytes from FILE or stdin (-)")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one TERMINAL is required")
	}
	raw := []byte(*data)
	if *file != "" {
		if *file == "-" {
			raw, err = io.ReadAll(io.LimitReader(c.In, 4<<20))
		} else {
			raw, err = os.ReadFile(*file)
		}
		if err != nil {
			return err
		}
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	terminal, err := c.resolveTerminal(ctx, client, rpcCtx, set.Arg(0))
	if err != nil {
		return err
	}
	value, err := client.WriteTerminal(rpcCtx, &dieterv1.TerminalInputRequest{TerminalId: terminal.GetId(), Data: raw})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcTerminalResize(args []string) error {
	const usage = "Usage: dieter terminal resize --columns N --rows N TERMINAL\n"
	set := flags("terminal resize")
	columns := set.Int("columns", 0, "terminal columns")
	rows := set.Int("rows", 0, "terminal rows")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || *columns <= 0 || *rows <= 0 {
		return errors.New("TERMINAL, --columns, and --rows are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	terminal, err := c.resolveTerminal(ctx, client, rpcCtx, set.Arg(0))
	if err != nil {
		return err
	}
	value, err := client.ResizeTerminal(rpcCtx, &dieterv1.ResizeTerminalRequest{TerminalId: terminal.GetId(), Columns: int32(*columns), Rows: int32(*rows)})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcTerminalRename(args []string) error {
	const usage = "Usage: dieter terminal rename --name NAME TERMINAL\n"
	set := flags("terminal rename")
	name := set.String("name", "", "new display name")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || strings.TrimSpace(*name) == "" {
		return errors.New("TERMINAL and --name are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	terminal, err := c.resolveTerminal(ctx, client, rpcCtx, set.Arg(0))
	if err != nil {
		return err
	}
	value, err := client.RenameTerminal(rpcCtx, &dieterv1.RenameTerminalRequest{TerminalId: terminal.GetId(), Name: *name})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcTerminalClose(args []string) error {
	const usage = "Usage: dieter terminal close TERMINAL\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one TERMINAL is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	terminal, err := c.resolveTerminal(ctx, client, rpcCtx, args[0])
	if err != nil {
		return err
	}
	_, err = client.CloseTerminal(rpcCtx, &dieterv1.TerminalRef{TerminalId: terminal.GetId()})
	return err
}
