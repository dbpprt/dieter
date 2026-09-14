package cli

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

const screenHelp = `Usage: dieter screen <action>

Actions:
  capabilities                 Inspect displays, codecs, permissions, and readiness
  permissions [--request-control] Probe capture and input permission through the daemon
  settings                     Show screen-viewing and control policy
  update [options]             Enable/disable viewing and remote control
  start --request FILE         Start WebRTC signaling; stream daemon signals as JSON Lines
  signal --file FILE           Send one trickle ICE/heartbeat signal to a session
  status SESSION               Show current stream configuration and performance
  configure SESSION [options]  Change display, quality and stream ceilings live
  refresh SESSION              Request a fresh keyframe, including an idle screen
  close SESSION                Close a remote-desktop session

"start" accepts protobuf JSON from FILE or stdin (-). It can also consume
additional RemoteDesktopSignal JSON Lines from --signal-input FILE while the
daemon response stream remains open. Use "dieter machine rtc" to obtain signed
ICE configuration for remote sessions. Media and encrypted control travel over
the negotiated WebRTC connection, never through the CLI RPC transport.
`

func (c *CLI) rpcScreen(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, screenHelp)
		return nil
	}
	switch args[0] {
	case "capabilities", "capability":
		return c.rpcScreenCapabilities(args[1:])
	case "permissions":
		return c.rpcScreenPermissions(args[1:])
	case "settings":
		return c.rpcScreenSettings(args[1:])
	case "update", "set":
		return c.rpcScreenUpdate(args[1:])
	case "start", "connect":
		return c.rpcScreenStart(args[1:])
	case "signal", "send":
		return c.rpcScreenSignal(args[1:])
	case "status", "configure", "refresh":
		return c.rpcScreenSession(args[0], args[1:])
	case "close", "stop":
		return c.rpcScreenClose(args[1:])
	default:
		return fmt.Errorf("unknown screen action %q; run `dieter screen --help`", args[0])
	}
}

func (c *CLI) rpcScreenPermissions(args []string) error {
	const usage = `Usage: dieter screen permissions [--request-control]

Ask the running daemon to discard one captured frame and check event-posting
permission. Prints the daemon/helper paths and both results as JSON. Does not
inject input or change settings. --request-control explicitly allows a macOS
Accessibility prompt on the daemon host. Supports --machine ID|NAME.
`
	set := flags("screen permissions")
	request := set.Bool("request-control", false, "allow a control-permission prompt on the daemon host")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New(usage)
	}
	value, err := c.probeRemoteDesktopPermissions(*request)
	if err != nil {
		return err
	}
	if err := protoJSONOut(c.Out, value); err != nil {
		return err
	}
	if !value.GetCaptureVerified() || !value.GetControlVerified() {
		return errors.New("running daemon screen-sharing permissions are not ready")
	}
	return nil
}

func (c *CLI) rpcScreenCapabilities(args []string) error {
	const usage = "Usage: dieter screen capabilities\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 0 {
		return errors.New("screen capabilities does not accept arguments")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.GetRemoteDesktopCapabilities(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcScreenSettings(args []string) error {
	const usage = "Usage: dieter screen settings\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 0 {
		return errors.New("screen settings does not accept arguments")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.GetRemoteDesktopSettings(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcScreenUpdate(args []string) error {
	const usage = "Usage: dieter screen update [--enabled=true|false] [--control=true|false]\n"
	set := flags("screen update")
	enabled := set.Bool("enabled", false, "allow screen viewing")
	control := set.Bool("control", false, "allow authenticated remote input")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("screen update does not accept positional arguments")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	current, err := client.GetRemoteDesktopSettings(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	set.Visit(func(item *flag.Flag) {
		switch item.Name {
		case "enabled":
			current.Enabled = *enabled
		case "control":
			current.ControlEnabled = *control
		}
	})
	value, err := client.UpdateRemoteDesktopSettings(rpcCtx, &dieterv1.UpdateRemoteDesktopSettingsRequest{Enabled: current.GetEnabled(), ControlEnabled: current.GetControlEnabled()})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func readProtoJSON(path string, in io.Reader, value proto.Message) error {
	var raw []byte
	var err error
	if path == "-" {
		raw, err = io.ReadAll(io.LimitReader(in, 16<<20))
	} else {
		raw, err = os.ReadFile(path)
	}
	if err != nil {
		return err
	}
	if err := (protojson.UnmarshalOptions{DiscardUnknown: false}).Unmarshal(raw, value); err != nil {
		return fmt.Errorf("decode protobuf JSON: %w", err)
	}
	return nil
}

func (c *CLI) rpcScreenStart(args []string) error {
	const usage = "Usage: dieter screen start --request FILE|- [--signal-input FILE|-] [--count N]\n"
	set := flags("screen start")
	requestFile := set.String("request", "", "StartRemoteDesktopRequest protobuf JSON")
	signalInput := set.String("signal-input", "", "RemoteDesktopSignal JSON Lines for trickle ICE/heartbeat")
	count := set.Int("count", 0, "stop after N daemon signals; zero streams until close")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 || strings.TrimSpace(*requestFile) == "" {
		return errors.New("--request is required")
	}
	if *requestFile == "-" && *signalInput == "-" {
		return errors.New("--request and --signal-input cannot both read stdin")
	}
	request := &dieterv1.StartRemoteDesktopRequest{}
	if err := readProtoJSON(*requestFile, c.In, request); err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	if strings.TrimSpace(*signalInput) != "" {
		var input io.Reader = c.In
		var file *os.File
		if *signalInput != "-" {
			file, err = os.Open(*signalInput)
			if err != nil {
				return err
			}
			defer file.Close()
			input = file
		}
		go func() {
			scanner := bufio.NewScanner(input)
			scanner.Buffer(make([]byte, 64<<10), 4<<20)
			for scanner.Scan() {
				signalValue := &dieterv1.RemoteDesktopSignal{}
				if (protojson.UnmarshalOptions{DiscardUnknown: false}).Unmarshal(scanner.Bytes(), signalValue) == nil {
					_, _ = client.SendRemoteDesktopSignal(rpcCtx, signalValue)
				}
			}
		}()
	}
	stream, err := client.StartRemoteDesktop(rpcCtx, request)
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
}

func (c *CLI) rpcScreenSignal(args []string) error {
	const usage = "Usage: dieter screen signal --file FILE|-\n"
	set := flags("screen signal")
	file := set.String("file", "", "RemoteDesktopSignal protobuf JSON")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 || strings.TrimSpace(*file) == "" {
		return errors.New("--file is required")
	}
	request := &dieterv1.RemoteDesktopSignal{}
	if err := readProtoJSON(*file, c.In, request); err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.SendRemoteDesktopSignal(rpcCtx, request)
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcScreenClose(args []string) error {
	const usage = "Usage: dieter screen close SESSION\n"
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 1 {
		return errors.New("exactly one SESSION is required")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	_, err = client.CloseRemoteDesktop(rpcCtx, &dieterv1.RemoteDesktopRef{SessionId: args[0]})
	return err
}

func (c *CLI) rpcScreenSession(action string, args []string) error {
	usage := "Usage: dieter screen " + action + " SESSION\n"
	if action == "configure" {
		usage = "Usage: dieter screen configure SESSION [--display ID] [--quality auto|detail|motion] [--width N] [--height N] [--fps N] [--bitrate N] [--embedded-cursor=true|false]\nCeilings are adaptive; unspecified values retain the current session configuration.\n"
	}
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) == 0 {
		return errors.New("exactly one SESSION is required")
	}
	id := args[0]
	set := flags("screen " + action)
	display := set.String("display", "", "display ID from screen capabilities")
	quality := set.String("quality", "auto", "auto, detail or motion")
	width := set.Int("width", 3840, "maximum pixel width")
	height := set.Int("height", 2160, "maximum pixel height")
	fps := set.Int("fps", 60, "maximum frames per second (1–60)")
	bitrate := set.Int("bitrate", 12000, "maximum video kilobits per second")
	cursor := set.Bool("embedded-cursor", false, "include cursor in video")
	if action != "configure" && len(args) != 1 {
		return errors.New("exactly one SESSION is required")
	}
	if _, err := parse(set, args[1:], usage, c.Out); err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("unexpected positional argument")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	state, err := client.GetRemoteDesktopSession(rpcCtx, &dieterv1.RemoteDesktopRef{SessionId: id})
	if err != nil {
		return err
	}
	if action == "status" {
		return protoJSONOut(c.Out, state)
	}
	request := &dieterv1.UpdateRemoteDesktopSessionRequest{SessionId: id, Refresh: true}
	if action == "configure" {
		config := state.GetConfiguration()
		if config == nil {
			config = &dieterv1.RemoteDesktopStreamConfiguration{}
		}
		var invalid error
		set.Visit(func(f *flag.Flag) {
			switch f.Name {
			case "display":
				config.DisplayId = *display
			case "width":
				if *width < 320 || *width > 3840 {
					invalid = errors.New("width must be between 320 and 3840")
				}
				config.MaxWidth = int32(*width)
			case "height":
				if *height < 180 || *height > 2160 {
					invalid = errors.New("height must be between 180 and 2160")
				}
				config.MaxHeight = int32(*height)
			case "fps":
				if *fps < 1 || *fps > 60 {
					invalid = errors.New("fps must be between 1 and 60")
				}
				config.MaxFps = int32(*fps)
			case "bitrate":
				if *bitrate < 100 || *bitrate > 100000 {
					invalid = errors.New("bitrate must be between 100 and 100000 kbps")
				}
				config.MaxBitrateKbps = int32(*bitrate)
			case "embedded-cursor":
				config.EmbeddedCursor = *cursor
			case "quality":
				switch *quality {
				case "auto":
					config.Quality = dieterv1.RemoteDesktopQuality_REMOTE_DESKTOP_QUALITY_AUTO
				case "detail":
					config.Quality = dieterv1.RemoteDesktopQuality_REMOTE_DESKTOP_QUALITY_DETAIL
				case "motion":
					config.Quality = dieterv1.RemoteDesktopQuality_REMOTE_DESKTOP_QUALITY_MOTION
				default:
					invalid = errors.New("quality must be auto, detail or motion")
				}
			}
		})
		if invalid != nil {
			return invalid
		}
		request.Configuration = config
	}
	state, err = client.UpdateRemoteDesktopSession(rpcCtx, request)
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, state)
}
