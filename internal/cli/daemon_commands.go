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

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

func wantsHelp(args []string) bool {
	for _, argument := range args {
		if argument == "--help" || argument == "-h" {
			return true
		}
	}
	return false
}

func groupHelp(args []string) bool { return len(args) == 0 || args[0] == "--help" || args[0] == "-h" }

func protoJSONOut(out io.Writer, value any) error {
	if message, ok := value.(proto.Message); ok {
		raw, err := (protojson.MarshalOptions{Indent: "  ", UseProtoNames: false}).Marshal(message)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(out, "%s\n", raw)
		return err
	}
	return jsonOut(out, value)
}

func protoJSONLine(out io.Writer, value proto.Message) error {
	raw, err := (protojson.MarshalOptions{UseProtoNames: false}).Marshal(value)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(out, "%s\n", raw)
	return err
}

func (c *CLI) runDaemonCommand(args []string) (bool, error) {
	if len(args) == 0 {
		return false, nil
	}
	switch args[0] {
	case "setup", "serve", "daemon", "version":
		return false, nil
	case "auth":
		return true, c.auth(args[1:])
	case "machine", "machines":
		return true, c.machineCommand(args[1:])
	case "status":
		return true, c.daemonBackedStatus(args[1:])
	case "storage":
		return true, c.daemonBackedStorage(args[1:])
	case "harness", "harnesses":
		return true, c.harnessCommand(args[1:])
	case "project", "projects":
		return true, c.rpcProject(args[1:])
	case "board", "boards":
		return true, c.rpcBoard(args[1:])
	case "card", "cards":
		return true, c.rpcCard(args[1:], false)
	case "chat", "chats":
		return true, c.rpcCard(args[1:], true)
	case "workspace", "workspaces", "git":
		return true, c.rpcWorkspace(args[1:])
	case "schedule", "schedules":
		return true, c.rpcSchedule(args[1:])
	case "settings":
		return true, c.rpcSettings(args[1:])
	case "prompt", "prompts":
		return true, c.rpcPrompt(args[1:])
	case "file", "files":
		return true, c.rpcFile(args[1:])
	case "terminal", "terminals":
		return true, c.rpcTerminal(args[1:])
	case "screen", "screens":
		return true, c.rpcScreen(args[1:])
	case "watch":
		return true, c.rpcWatch(args[1:])
	default:
		return false, nil
	}
}

func (c *CLI) daemonBackedStatus(args []string) error {
	const usage = "Usage: dieter status [--format table|json]\n"
	set := flags("status")
	format := set.String("format", "json", "table or json")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("status does not accept positional arguments")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	health, err := client.Health(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	runtimeStatus, err := client.GetRuntimeStatus(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	state, err := client.GetState(rpcCtx, &dieterv1.GetStateRequest{})
	if err != nil {
		return err
	}
	if *format == "table" {
		fmt.Fprintf(c.Out, "STATUS\t%s\nVERSION\t%s\nROUTE\t%s\nPROJECTS\t%d\nCARDS\t%d\nCHATS\t%d\n", health.GetStatus(), health.GetVersion(), c.transport.route, len(state.GetProjects()), len(state.GetCards()), len(state.GetChats()))
		return nil
	}
	return jsonOut(c.Out, map[string]any{
		"health": health, "runtime": runtimeStatus, "route": c.transport.route,
		"projects": len(state.GetProjects()), "boards": len(state.GetBoards()),
		"cards": len(state.GetCards()), "chats": len(state.GetChats()),
	})
}

func (c *CLI) daemonBackedStorage(args []string) error {
	const usage = "Usage: dieter storage\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 0 {
		return errors.New("storage does not accept arguments")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	health, err := client.Health(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	fmt.Fprintln(c.Out, health.GetStorePath())
	return nil
}

const machineHelp = `Usage: dieter machine <action>

Actions:
  list [--format table|json|jsonl|ids]       List enrolled machines
  watch [--count N]                          Stream gateway presence as JSON Lines
  show [MACHINE]                             Show gateway presence and route
  info [MACHINE]                             Show live host telemetry (local by default)
  rename --name NAME [MACHINE]               Rename an enrolled machine
  revoke --confirm MACHINE_ID [MACHINE]       Revoke an enrolled machine
  restart --confirm RESTART [MACHINE]
  shutdown --confirm "SHUT DOWN" [MACHINE]
  rtc [MACHINE]                              Get signed WebRTC configuration

Pass MACHINE or global --machine to select a remote daemon. Info, restart, and
shutdown target the local daemon when MACHINE is omitted.
`

func (c *CLI) machineReference(setArguments []string) (string, error) {
	if len(setArguments) > 1 {
		return "", errors.New("at most one MACHINE is accepted")
	}
	if len(setArguments) == 1 {
		return setArguments[0], nil
	}
	if strings.TrimSpace(c.Machine) == "" {
		return "", errors.New("MACHINE or the global --machine flag is required")
	}
	return c.Machine, nil
}

func (c *CLI) gatewayMachine(ctx context.Context, reference string) (*gatewayTransport, *gatewayv1.Daemon, error) {
	gateway, err := c.dialGateway(ctx)
	if err != nil {
		return nil, nil, err
	}
	directory, err := gateway.client.ListDaemons(ctx, &emptypb.Empty{})
	if err != nil {
		return nil, nil, err
	}
	machine, err := resolveDaemon(directory.GetDaemons(), reference)
	return gateway, machine, err
}

func (c *CLI) machineCommand(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, machineHelp)
		return nil
	}
	switch args[0] {
	case "list", "ls":
		const usage = "Usage: dieter machine list [--format table|json|jsonl|ids]\n"
		set := flags("machine list")
		format := set.String("format", "table", "table, json, jsonl, or ids")
		help, err := parse(set, args[1:], usage, c.Out)
		if help || err != nil {
			return err
		}
		ctx, cancel := c.commandContext()
		defer cancel()
		gateway, err := c.dialGateway(ctx)
		if err != nil {
			return err
		}
		response, err := gateway.client.ListDaemons(ctx, &emptypb.Empty{})
		if err != nil {
			return err
		}
		if *format == "json" {
			return protoJSONOut(c.Out, response)
		}
		writer := tabwriter.NewWriter(c.Out, 0, 3, 2, ' ', 0)
		if *format == "table" {
			fmt.Fprintln(writer, "ID\tSTATUS\tVERSION\tNAME")
		}
		for _, item := range response.GetDaemons() {
			switch *format {
			case "jsonl":
				if err := protoJSONLine(c.Out, item); err != nil {
					return err
				}
			case "ids":
				fmt.Fprintln(c.Out, item.GetId())
			default:
				state := "offline"
				if item.GetOnline() {
					state = "online"
				}
				fmt.Fprintf(writer, "%s\t%s\t%s\t%s\n", item.GetId(), state, item.GetVersion(), item.GetName())
			}
		}
		return writer.Flush()
	case "watch":
		const usage = "Usage: dieter machine watch [--count N]\n"
		set := flags("machine watch")
		count := set.Int("count", 0, "stop after N frames; zero streams until interrupted")
		help, err := parse(set, args[1:], usage, c.Out)
		if help || err != nil {
			return err
		}
		if set.NArg() != 0 {
			return errors.New("machine watch does not accept positional arguments")
		}
		ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer cancel()
		gateway, err := c.dialGateway(ctx)
		if err != nil {
			return err
		}
		stream, err := gateway.client.WatchDaemons(ctx, &gatewayv1.WatchDaemonsRequest{HeartbeatSeconds: 15})
		if err != nil {
			return err
		}
		for emitted := 0; ; emitted++ {
			value, receiveErr := stream.Recv()
			if receiveErr != nil {
				return streamEnd(receiveErr, ctx)
			}
			if err := protoJSONLine(c.Out, value); err != nil {
				return err
			}
			if *count > 0 && emitted+1 >= *count {
				return nil
			}
		}
	case "show", "route", "info", "rename", "revoke", "restart", "shutdown", "rtc":
		return c.machineAction(args[0], args[1:])
	default:
		return fmt.Errorf("unknown machine action %q; run `dieter machine --help`", args[0])
	}
}

func (c *CLI) machineAction(action string, args []string) error {
	usage := fmt.Sprintf("Usage: dieter machine %s [options] [MACHINE]\n", action)
	set := flags("machine " + action)
	name := set.String("name", "", "new machine name")
	confirmation := set.String("confirm", "", "required destructive-action confirmation")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	if set.NArg() == 0 && strings.TrimSpace(c.Machine) == "" && (action == "info" || action == "restart" || action == "shutdown") {
		client, rpcCtx, err := c.rpc(ctx)
		if err != nil {
			return err
		}
		return c.machineRPCAction(client, rpcCtx, action, *confirmation)
	}
	reference, err := c.machineReference(set.Args())
	if err != nil {
		return err
	}
	gateway, machine, err := c.gatewayMachine(ctx, reference)
	if err != nil {
		return err
	}
	switch action {
	case "show":
		return protoJSONOut(c.Out, machine)
	case "route":
		route, err := gateway.client.ResolveDaemonRoute(ctx, &gatewayv1.DaemonRef{DaemonId: machine.GetId()})
		if err != nil {
			return err
		}
		return jsonOut(c.Out, map[string]any{"machine": machine, "route": route})
	case "rename":
		if strings.TrimSpace(*name) == "" {
			return errors.New("--name is required")
		}
		value, err := gateway.client.RenameDaemon(ctx, &gatewayv1.RenameDaemonRequest{DaemonId: machine.GetId(), Name: *name})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, value)
	case "revoke":
		if *confirmation != machine.GetId() {
			return fmt.Errorf("--confirm must exactly equal machine ID %q", machine.GetId())
		}
		_, err := gateway.client.RevokeDaemon(ctx, &gatewayv1.DaemonRef{DaemonId: machine.GetId()})
		return err
	case "rtc":
		value, err := gateway.client.GetRTCConfiguration(ctx, &gatewayv1.DaemonRef{DaemonId: machine.GetId()})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, value)
	case "info", "restart", "shutdown":
		previous := c.Machine
		c.Machine = machine.GetId()
		defer func() { c.Machine = previous }()
		client, rpcCtx, err := c.rpc(ctx)
		if err != nil {
			return err
		}
		return c.machineRPCAction(client, rpcCtx, action, *confirmation)
	}
	return nil
}

func (c *CLI) machineRPCAction(client dieterv1.DieterServiceClient, ctx context.Context, action, confirmation string) error {
	if action == "info" {
		value, err := client.GetMachineInformation(ctx, &emptypb.Empty{})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, value)
	}
	wireAction := dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_RESTART
	if action == "shutdown" {
		wireAction = dieterv1.MachineOperationAction_MACHINE_OPERATION_ACTION_SHUTDOWN
	}
	value, err := client.PerformMachineOperation(ctx, &dieterv1.MachineOperationRequest{Action: wireAction, Confirmation: confirmation})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) harnessCommand(args []string) error {
	const usage = "Usage: dieter harness list [--format table|json|jsonl|ids]\n"
	if groupHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if args[0] != "list" && args[0] != "ls" {
		return fmt.Errorf("unknown harness action %q", args[0])
	}
	set := flags("harness list")
	format := set.String("format", "table", "table, json, jsonl, or ids")
	help, err := parse(set, args[1:], usage, c.Out)
	if help || err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	catalog, err := client.GetHarnesses(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, catalog)
	}
	for _, item := range catalog.GetHarnesses() {
		switch *format {
		case "jsonl":
			if err := protoJSONLine(c.Out, item); err != nil {
				return err
			}
		case "ids":
			fmt.Fprintln(c.Out, item.GetId())
		default:
			fmt.Fprintf(c.Out, "%s\t%s\t%s\n", item.GetId(), item.GetDefaultModel(), item.GetName())
		}
	}
	return nil
}

func (c *CLI) rpcWatch(args []string) error {
	const usage = `Usage: dieter watch state [--interval MS] [--count N]
       dieter watch sync [--count N]

Stream daemon state or durable sync frames as JSON Lines until interrupted.
`
	if groupHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	set := flags("watch " + args[0])
	interval := set.Int("interval", 1000, "state polling interval in milliseconds")
	count := set.Int("count", 0, "stop after N frames; zero streams until interrupted")
	help, err := parse(set, args[1:], usage, c.Out)
	if help || err != nil {
		return err
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	emitted := 0
	switch args[0] {
	case "state":
		stream, err := client.WatchState(rpcCtx, &dieterv1.WatchStateRequest{IntervalMs: int32(*interval)})
		if err != nil {
			return err
		}
		for {
			value, err := stream.Recv()
			if err != nil {
				return streamEnd(err, ctx)
			}
			if err := protoJSONLine(c.Out, value); err != nil {
				return err
			}
			emitted++
			if *count > 0 && emitted >= *count {
				return nil
			}
		}
	case "sync":
		stream, err := client.WatchSync(rpcCtx, &dieterv1.SyncRequest{HeartbeatMs: 15_000})
		if err != nil {
			return err
		}
		for {
			value, err := stream.Recv()
			if err != nil {
				return streamEnd(err, ctx)
			}
			if err := protoJSONLine(c.Out, value); err != nil {
				return err
			}
			emitted++
			if *count > 0 && emitted >= *count {
				return nil
			}
		}
	default:
		return fmt.Errorf("unknown watch action %q", args[0])
	}
}

func streamEnd(err error, ctx context.Context) error {
	if errors.Is(err, io.EOF) || ctx.Err() != nil {
		return nil
	}
	if value, ok := status.FromError(err); ok && value.Code() == codes.Canceled {
		return nil
	}
	return err
}
