package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"text/tabwriter"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

const remoteHelp = `Usage: dieter remote <action>

Agent-oriented remote execution uses exact argv values, explicit exit status,
separate stdout/stderr, bounded resumable output, and optional PTY input. Every
action honors global --machine and uses verified direct TLS before relay.

Actions:
  exec SCOPE -- COMMAND [ARG...]     Run exact argv and wait for its exit
  shell SCOPE                        Open and attach a native remote PTY shell
  list [SCOPE]                       List retained executions
  show EXECUTION                     Show execution state
  watch EXECUTION                    Resume output from a sequence
  wait EXECUTION                     Wait for exit and propagate its exit code
  attach EXECUTION                   Watch output and forward stdin
  input EXECUTION                    Write bounded stdin bytes or EOF
  signal EXECUTION                   Send interrupt, terminate, kill, or hangup
  resize EXECUTION                   Resize a PTY execution
  cancel EXECUTION                   Gracefully terminate an execution
  close EXECUTION                    Stop and remove an execution

SCOPE is exactly one of --project PROJECT or --card CARD. Use IDs rather than
names in automation. A disconnected watch never cancels the remote process.
`

type remoteExitError struct {
	execution *dieterv1.Execution
}

func (e *remoteExitError) Error() string {
	if e == nil || e.execution == nil {
		return "remote execution failed"
	}
	if e.execution.ExitCode != nil {
		return fmt.Sprintf("remote execution %s exited with status %d", e.execution.GetId(), e.execution.GetExitCode())
	}
	return fmt.Sprintf("remote execution %s ended with status %s", e.execution.GetId(), e.execution.GetStatus())
}

func (e *remoteExitError) Code() int {
	if e != nil && e.execution != nil && e.execution.ExitCode != nil {
		code := int(e.execution.GetExitCode())
		if code > 0 && code <= 255 {
			return code
		}
	}
	return 255
}

func (c *CLI) rpcRemote(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, remoteHelp)
		return nil
	}
	switch args[0] {
	case "exec", "run":
		return c.rpcRemoteExec(args[1:])
	case "shell":
		return c.rpcRemoteShell(args[1:])
	case "list", "ls":
		return c.rpcRemoteList(args[1:])
	case "show", "get":
		return c.rpcRemoteShow(args[1:])
	case "watch":
		return c.rpcRemoteWatch(args[1:], false, false)
	case "wait":
		return c.rpcRemoteWatch(args[1:], false, true)
	case "attach":
		return c.rpcRemoteWatch(args[1:], true, true)
	case "input", "write", "send":
		return c.rpcRemoteInput(args[1:])
	case "signal":
		return c.rpcRemoteSignal(args[1:])
	case "resize":
		return c.rpcRemoteResize(args[1:])
	case "cancel":
		return c.rpcRemoteCancel(args[1:])
	case "close", "delete", "remove", "rm":
		return c.rpcRemoteClose(args[1:])
	default:
		return fmt.Errorf("unknown remote action %q; run `dieter remote --help`", args[0])
	}
}

type repeatedRemoteValues []string

func (values *repeatedRemoteValues) String() string { return strings.Join(*values, ",") }
func (values *repeatedRemoteValues) Set(value string) error {
	if strings.TrimSpace(value) == "" {
		return errors.New("value is required")
	}
	*values = append(*values, value)
	return nil
}

func splitRemoteCommand(args []string) ([]string, []string, bool) {
	for index, argument := range args {
		if argument == "--" {
			return args[:index], args[index+1:], true
		}
	}
	return args, nil, false
}

func (c *CLI) rpcRemoteExec(args []string) error {
	const usage = "Usage: dieter remote exec (--project PROJECT|--card CARD) [options] -- COMMAND [ARG...]\n\nOptions: --name NAME --directory PATH --env KEY=VALUE --input TEXT --input-file FILE|- --stdin --keep-input --timeout DURATION --idempotency-key KEY --pty --columns N --rows N --max-output BYTES --detach --format content|jsonl|json|id\n"
	flagArgs, argv, separated := splitRemoteCommand(args)
	set := flags("remote exec")
	project, card := addFileScopeFlags(set)
	name := set.String("name", "", "execution display name")
	directory := set.String("directory", "", "working directory within project/workspace")
	var environment repeatedRemoteValues
	set.Var(&environment, "env", "environment KEY=VALUE; repeatable")
	input := set.String("input", "", "initial stdin text")
	inputFile := set.String("input-file", "", "read initial stdin from FILE or -")
	readStdin := set.Bool("stdin", false, "read initial stdin from the CLI stdin stream")
	keepInput := set.Bool("keep-input", false, "leave stdin open after initial input")
	timeout := set.Duration("timeout", 0, "remote process timeout; zero disables")
	idempotency := set.String("idempotency-key", "", "return the existing execution when this exact request was admitted")
	ptyMode := set.Bool("pty", false, "merge output into a remote PTY")
	columns := set.Int("columns", 120, "PTY columns")
	rows := set.Int("rows", 36, "PTY rows")
	maxOutput := set.Int64("max-output", 8<<20, "retained output bytes")
	detach := set.Bool("detach", false, "return immediately after admission")
	format := set.String("format", "content", "content, jsonl, json, or id")
	help, err := parse(set, flagArgs, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 || !separated || len(argv) == 0 {
		return errors.New("remote exec requires exact argv after --")
	}
	raw, err := remoteInitialInput(c.In, *input, *inputFile, *readStdin)
	if err != nil {
		return err
	}
	environmentMap, err := remoteEnvironment(environment)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	projectID, cardID, err := c.resolveFileScope(ctx, client, rpcCtx, *project, *card)
	if err != nil {
		return err
	}
	value, err := client.StartExecution(rpcCtx, &dieterv1.StartExecutionRequest{
		ProjectId: projectID, CardId: cardID, Name: *name, Argv: append([]string(nil), argv...), WorkingDirectory: *directory,
		Environment: environmentMap, Stdin: raw, StdinEof: !*keepInput, TimeoutMs: timeout.Milliseconds(),
		IdempotencyKey: *idempotency, Pty: *ptyMode, Columns: int32(*columns), Rows: int32(*rows), MaxOutputBytes: *maxOutput,
	})
	if err != nil {
		return err
	}
	if *detach {
		switch *format {
		case "id", "content":
			fmt.Fprintln(c.Out, value.GetId())
			return nil
		case "json":
			return protoJSONOut(c.Out, value)
		default:
			return errors.New("detached execution format must be id or json")
		}
	}
	if *format != "content" && *format != "jsonl" {
		return errors.New("attached execution format must be content or jsonl")
	}
	return c.watchRemoteExecution(ctx, client, rpcCtx, value, 0, *format, 0, false, true)
}

func (c *CLI) rpcRemoteShell(args []string) error {
	const usage = "Usage: dieter remote shell (--project PROJECT|--card CARD) [--name NAME] [--shell PATH] [--directory PATH] [--env KEY=VALUE] [--columns N] [--rows N] [--timeout DURATION] [--idempotency-key KEY] [--detach] [--format content|jsonl|json|id]\n"
	set := flags("remote shell")
	project, card := addFileScopeFlags(set)
	name := set.String("name", "shell", "execution display name")
	shell := set.String("shell", "/bin/sh", "shell executable on the daemon host")
	directory := set.String("directory", "", "working directory within project/workspace")
	var environment repeatedRemoteValues
	set.Var(&environment, "env", "environment KEY=VALUE; repeatable")
	columns := set.Int("columns", 120, "PTY columns")
	rows := set.Int("rows", 36, "PTY rows")
	timeout := set.Duration("timeout", 0, "remote shell timeout; zero disables")
	idempotency := set.String("idempotency-key", "", "idempotent admission key")
	detach := set.Bool("detach", false, "return immediately after admission")
	format := set.String("format", "content", "content, jsonl, json, or id")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 || strings.TrimSpace(*shell) == "" {
		return errors.New("remote shell accepts flags only and requires a shell path")
	}
	environmentMap, err := remoteEnvironment(environment)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	projectID, cardID, err := c.resolveFileScope(ctx, client, rpcCtx, *project, *card)
	if err != nil {
		return err
	}
	value, err := client.StartExecution(rpcCtx, &dieterv1.StartExecutionRequest{
		ProjectId: projectID, CardId: cardID, Name: *name, Argv: []string{*shell, "-l"}, WorkingDirectory: *directory,
		Environment: environmentMap, TimeoutMs: timeout.Milliseconds(), IdempotencyKey: *idempotency,
		Pty: true, Columns: int32(*columns), Rows: int32(*rows), MaxOutputBytes: 8 << 20,
	})
	if err != nil {
		return err
	}
	if *detach {
		if *format == "json" {
			return protoJSONOut(c.Out, value)
		}
		if *format != "id" && *format != "content" {
			return errors.New("detached shell format must be id or json")
		}
		fmt.Fprintln(c.Out, value.GetId())
		return nil
	}
	if *format != "content" && *format != "jsonl" {
		return errors.New("attached shell format must be content or jsonl")
	}
	return c.watchRemoteExecution(ctx, client, rpcCtx, value, 0, *format, 0, true, true)
}

func remoteInitialInput(in io.Reader, inline, path string, readStdin bool) ([]byte, error) {
	selected := 0
	if inline != "" {
		selected++
	}
	if path != "" {
		selected++
	}
	if readStdin {
		selected++
	}
	if selected > 1 {
		return nil, errors.New("use only one of --input, --input-file, or --stdin")
	}
	if selected == 0 {
		return nil, nil
	}
	if inline != "" {
		return []byte(inline), nil
	}
	var reader io.Reader
	var file *os.File
	if readStdin || path == "-" {
		reader = in
	} else {
		var err error
		file, err = os.Open(path)
		if err != nil {
			return nil, err
		}
		defer file.Close()
		reader = file
	}
	raw, err := io.ReadAll(io.LimitReader(reader, (64<<10)+1))
	if err == nil && len(raw) > 64<<10 {
		return nil, errors.New("initial remote input exceeds 64 KiB")
	}
	return raw, err
}

func remoteEnvironment(values []string) (map[string]string, error) {
	result := make(map[string]string, len(values))
	for _, value := range values {
		key, item, ok := strings.Cut(value, "=")
		key = strings.TrimSpace(key)
		if !ok || key == "" {
			return nil, fmt.Errorf("environment %q must be KEY=VALUE", value)
		}
		result[key] = item
	}
	return result, nil
}

func resolveExecution(items []*dieterv1.Execution, reference string) (*dieterv1.Execution, error) {
	var matches []*dieterv1.Execution
	for _, item := range items {
		if item.GetId() == reference || strings.EqualFold(item.GetName(), reference) {
			matches = append(matches, item)
		}
	}
	if len(matches) == 0 {
		return nil, fmt.Errorf("execution %q was not found on the target daemon", reference)
	}
	if len(matches) > 1 {
		return nil, fmt.Errorf("execution name %q is ambiguous; use its exact ID", reference)
	}
	return matches[0], nil
}

func (c *CLI) resolveExecution(rpcCtx context.Context, client dieterv1.DieterServiceClient, reference string) (*dieterv1.Execution, error) {
	if strings.HasPrefix(reference, "exec_") {
		return client.GetExecution(rpcCtx, &dieterv1.ExecutionRef{ExecutionId: reference})
	}
	value, err := client.ListExecutions(rpcCtx, &dieterv1.ListExecutionsRequest{})
	if err != nil {
		return nil, err
	}
	return resolveExecution(value.GetExecutions(), reference)
}

func (c *CLI) rpcRemoteList(args []string) error {
	const usage = "Usage: dieter remote list [--project PROJECT|--card CARD] [--status STATUS] [--format table|json|jsonl|ids]\n"
	set := flags("remote list")
	project, card := addFileScopeFlags(set)
	requestedStatus := set.String("status", "", "filter by exact execution status")
	format := set.String("format", "table", "table, json, jsonl, or ids")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 || (*project != "" && *card != "") {
		return errors.New("remote list accepts no positional arguments and at most one scope")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	projectID, cardID := "", ""
	if *project != "" || *card != "" {
		projectID, cardID, err = c.terminalScope(ctx, client, rpcCtx, *project, *card, false)
		if err != nil {
			return err
		}
	}
	value, err := client.ListExecutions(rpcCtx, &dieterv1.ListExecutionsRequest{ProjectId: projectID, CardId: cardID, Status: *requestedStatus})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	writer := tabwriter.NewWriter(c.Out, 0, 3, 2, ' ', 0)
	if *format == "table" {
		fmt.Fprintln(writer, "ID\tSTATUS\tEXIT\tPTY\tNAME\tDIRECTORY")
	}
	for _, item := range value.GetExecutions() {
		switch *format {
		case "jsonl":
			if err := protoJSONLine(c.Out, item); err != nil {
				return err
			}
		case "ids":
			fmt.Fprintln(c.Out, item.GetId())
		case "table":
			exit := "-"
			if item.ExitCode != nil {
				exit = strconv.Itoa(int(item.GetExitCode()))
			}
			fmt.Fprintf(writer, "%s\t%s\t%s\t%t\t%s\t%s\n", item.GetId(), item.GetStatus(), exit, item.GetPty(), item.GetName(), item.GetWorkingDirectory())
		default:
			return errors.New("format must be table, json, jsonl, or ids")
		}
	}
	return writer.Flush()
}

func (c *CLI) rpcRemoteShow(args []string) error {
	const usage = "Usage: dieter remote show EXECUTION\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one EXECUTION is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := c.resolveExecution(rpcCtx, client, args[0])
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcRemoteWatch(args []string, attach, propagateExit bool) error {
	usage := "Usage: dieter remote watch [--after SEQUENCE] [--format content|jsonl] [--count N] EXECUTION\n"
	if attach {
		usage = "Usage: dieter remote attach [--after SEQUENCE] [--format content|jsonl] EXECUTION\n"
	} else if propagateExit {
		usage = "Usage: dieter remote wait [--after SEQUENCE] [--format content|jsonl] EXECUTION\n"
	}
	set := flags("remote watch")
	after := set.Uint64("after", 0, "last received sequence")
	format := set.String("format", "content", "content or jsonl")
	count := set.Int("count", 0, "stop after N events; zero streams through exit")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || (*format != "content" && *format != "jsonl") || *count < 0 {
		return errors.New("EXECUTION and a valid format/count are required")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := c.resolveExecution(rpcCtx, client, set.Arg(0))
	if err != nil {
		return err
	}
	return c.watchRemoteExecution(ctx, client, rpcCtx, value, *after, *format, *count, attach, propagateExit)
}

func (c *CLI) watchRemoteExecution(ctx context.Context, client dieterv1.DieterServiceClient, rpcCtx context.Context, execution *dieterv1.Execution, after uint64, format string, count int, attach, propagateExit bool) error {
	if attach && execution.GetStatus() == "running" {
		go c.forwardRemoteInput(rpcCtx, client, execution.GetId())
	}
	stream, err := client.WatchExecution(rpcCtx, &dieterv1.WatchExecutionRequest{ExecutionId: execution.GetId(), AfterSequence: after, HeartbeatMs: 1_000})
	if err != nil {
		return err
	}
	latest := execution
	emitted := 0
	for {
		event, receiveErr := stream.Recv()
		if receiveErr != nil {
			if endErr := streamEnd(receiveErr, ctx); endErr != nil {
				return endErr
			}
			break
		}
		if event.GetExecution() != nil {
			latest = event.GetExecution()
		}
		if format == "jsonl" {
			if err := protoJSONLine(c.Out, event); err != nil {
				return err
			}
		} else {
			switch event.GetStream() {
			case dieterv1.ExecutionStream_EXECUTION_STREAM_STDERR:
				if _, err := c.Err.Write(event.GetData()); err != nil {
					return err
				}
			default:
				if _, err := c.Out.Write(event.GetData()); err != nil {
					return err
				}
			}
		}
		if !event.GetHeartbeat() {
			emitted++
		}
		if count > 0 && emitted >= count {
			return nil
		}
		if event.GetEof() {
			break
		}
	}
	if propagateExit && !remoteExecutionSucceeded(latest) {
		return &remoteExitError{execution: latest}
	}
	return nil
}

func remoteExecutionSucceeded(value *dieterv1.Execution) bool {
	return value != nil && value.GetStatus() == "exited" && value.ExitCode != nil && value.GetExitCode() == 0
}

func (c *CLI) forwardRemoteInput(rpcCtx context.Context, client dieterv1.DieterServiceClient, id string) {
	buffer := make([]byte, 32<<10)
	for {
		count, err := c.In.Read(buffer)
		if count > 0 {
			if _, writeErr := client.WriteExecutionInput(rpcCtx, &dieterv1.ExecutionInputRequest{ExecutionId: id, Data: append([]byte(nil), buffer[:count]...)}); writeErr != nil {
				return
			}
		}
		if err != nil {
			_, _ = client.WriteExecutionInput(rpcCtx, &dieterv1.ExecutionInputRequest{ExecutionId: id, Eof: true})
			return
		}
	}
}

func (c *CLI) rpcRemoteInput(args []string) error {
	const usage = "Usage: dieter remote input [--data TEXT|--file FILE|-] [--eof] EXECUTION\n"
	set := flags("remote input")
	data := set.String("data", "", "input text")
	file := set.String("file", "", "read input bytes from FILE or -")
	eof := set.Bool("eof", false, "close stdin after writing")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || (*data == "" && *file == "" && !*eof) || (*data != "" && *file != "") {
		return errors.New("EXECUTION and exactly one input source or --eof are required")
	}
	raw, err := remoteInitialInput(c.In, *data, *file, false)
	if err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := c.resolveExecution(rpcCtx, client, set.Arg(0))
	if err != nil {
		return err
	}
	updated, err := client.WriteExecutionInput(rpcCtx, &dieterv1.ExecutionInputRequest{ExecutionId: value.GetId(), Data: raw, Eof: *eof})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, updated)
}

func (c *CLI) rpcRemoteSignal(args []string) error {
	const usage = "Usage: dieter remote signal --signal interrupt|terminate|kill|hangup EXECUTION\n"
	set := flags("remote signal")
	requested := set.String("signal", "interrupt", "interrupt, terminate, kill, or hangup")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one EXECUTION is required")
	}
	signalValue, err := protoRemoteSignal(*requested)
	if err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := c.resolveExecution(rpcCtx, client, set.Arg(0))
	if err != nil {
		return err
	}
	updated, err := client.SignalExecution(rpcCtx, &dieterv1.SignalExecutionRequest{ExecutionId: value.GetId(), Signal: signalValue})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, updated)
}

func protoRemoteSignal(value string) (dieterv1.ExecutionSignal, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "interrupt", "int", "sigint":
		return dieterv1.ExecutionSignal_EXECUTION_SIGNAL_INTERRUPT, nil
	case "terminate", "term", "sigterm":
		return dieterv1.ExecutionSignal_EXECUTION_SIGNAL_TERMINATE, nil
	case "kill", "sigkill":
		return dieterv1.ExecutionSignal_EXECUTION_SIGNAL_KILL, nil
	case "hangup", "hup", "sighup":
		return dieterv1.ExecutionSignal_EXECUTION_SIGNAL_HANGUP, nil
	default:
		return 0, fmt.Errorf("unknown execution signal %q", value)
	}
}

func (c *CLI) rpcRemoteResize(args []string) error {
	const usage = "Usage: dieter remote resize --columns N --rows N EXECUTION\n"
	set := flags("remote resize")
	columns := set.Int("columns", 0, "PTY columns")
	rows := set.Int("rows", 0, "PTY rows")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || *columns <= 0 || *rows <= 0 {
		return errors.New("EXECUTION, --columns, and --rows are required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := c.resolveExecution(rpcCtx, client, set.Arg(0))
	if err != nil {
		return err
	}
	updated, err := client.ResizeExecution(rpcCtx, &dieterv1.ResizeExecutionRequest{ExecutionId: value.GetId(), Columns: int32(*columns), Rows: int32(*rows)})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, updated)
}

func (c *CLI) rpcRemoteCancel(args []string) error {
	const usage = "Usage: dieter remote cancel EXECUTION\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one EXECUTION is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := c.resolveExecution(rpcCtx, client, args[0])
	if err != nil {
		return err
	}
	updated, err := client.CancelExecution(rpcCtx, &dieterv1.ExecutionRef{ExecutionId: value.GetId()})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, updated)
}

func (c *CLI) rpcRemoteClose(args []string) error {
	const usage = "Usage: dieter remote close EXECUTION\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one EXECUTION is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := c.resolveExecution(rpcCtx, client, args[0])
	if err != nil {
		return err
	}
	_, err = client.CloseExecution(rpcCtx, &dieterv1.ExecutionRef{ExecutionId: value.GetId()})
	return err
}
