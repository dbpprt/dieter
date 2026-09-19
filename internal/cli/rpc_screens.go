package cli

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"io"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"unicode/utf8"

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
  sessions                     List viewers, controller, and capture resources
  control take|release SESSION  Transfer or release control
  status SESSION               Show current stream configuration and performance
  configure SESSION [options]  Change display, quality and stream ceilings live
  resolution ACTION SESSION    Experimental physical desktop modes: modes, set, restore
  refresh SESSION              Request a fresh keyframe, including an idle screen
  clipboard ACTION SESSION     Read, write, copy, paste, or toggle clipboard sharing
  close SESSION                Close a remote-desktop session

"start" accepts protobuf JSON from FILE or stdin (-). It can also consume
additional RemoteDesktopSignal JSON Lines from --signal-input FILE while the
daemon response stream remains open. Use "dieter machine rtc" to obtain signed
ICE configuration for remote sessions. Media and encrypted control travel over
the negotiated WebRTC connection, never through the CLI RPC transport.
Configure supports 1–120 fps; above 60 fps geometry is capped at 1920x1080.
Check capabilities.maxFps for older hosts. Motion trades pixels before cadence;
auto/detail preserve their cadence-first policy. All limits are adaptive.
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
	case "sessions":
		return c.rpcScreenSessions(args[1:])
	case "clipboard":
		return c.rpcScreenClipboard(args[1:])
	case "control":
		return c.rpcScreenControl(args[1:])
	case "resolution":
		return c.rpcScreenResolution(args[1:])
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
Accessibility prompt or verifies the Linux XTest/RemoteDesktop portal path on
the daemon host. A Linux portal prompt can remain open for up to two minutes.
Supports --machine ID|NAME.
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
	const usage = "Usage: dieter screen start --request FILE|- [--signal-input FILE|-] [--count N] [--codec auto|h264|hevc] [--reference-recovery]\nHEVC requires a compatible signed H265 offer and hardware at up to 1080p60; codec changes require a new session.\nReference recovery requires the generic RTP frame descriptor and acknowledgements after decoder completion. Omitted flags preserve request JSON.\n"
	set := flags("screen start")
	references := set.Bool("reference-recovery", false, "receiver supports decoded-reference feedback and generic RTP dependencies")
	codec := set.String("codec", "auto", "override request codec preference: auto, h264, or strict hevc")
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
	preference, ok := map[string]dieterv1.RemoteDesktopCodecPreference{
		"auto": dieterv1.RemoteDesktopCodecPreference_REMOTE_DESKTOP_CODEC_PREFERENCE_AUTO,
		"h264": dieterv1.RemoteDesktopCodecPreference_REMOTE_DESKTOP_CODEC_PREFERENCE_H264,
		"hevc": dieterv1.RemoteDesktopCodecPreference_REMOTE_DESKTOP_CODEC_PREFERENCE_HEVC,
	}[*codec]
	if !ok {
		return errors.New("codec must be auto, h264, or hevc")
	}
	if *requestFile == "-" && *signalInput == "-" {
		return errors.New("--request and --signal-input cannot both read stdin")
	}
	request := &dieterv1.StartRemoteDesktopRequest{}
	if err := readProtoJSON(*requestFile, c.In, request); err != nil {
		return err
	}
	set.Visit(func(f *flag.Flag) {
		if f.Name == "reference-recovery" {
			request.ReferenceRecovery = *references
		}
		if f.Name == "codec" {
			request.CodecPreference = preference
		}
	})
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
	if action == "status" {
		usage += "JSON includes paced sendMs, approximate captureToSendMs, receiver jitterBufferMs and renderMs; queueMs measures socket work only. Stages overlap and are not a glass-to-glass total.\n"
		usage += "renderMeasurement distinguishes Metal presentation from Android EGL submission. Optional decoder/encoder diagnostics report accepted configuration, not measured latency gains. mediaRtpBytes, repairRtpBytes, probeRtpBytes and fecRtpBytes exclude transport overhead. recoveryDiagnostics reports bounded packet history and repair decisions.\n"
	}
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
	fps := set.Int("fps", 60, "maximum frames per second (1–120; above 60 caps resolution at 1080p)")
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
				if *fps < 1 || *fps > 120 {
					invalid = errors.New("fps must be between 1 and 120")
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

func (c *CLI) rpcScreenSessions(args []string) error {
	const usage = `Usage: dieter screen sessions

List the connected viewers, active controller, four-client limit, shared capture
streams, and hardware encoders as JSON. Supports --machine ID|NAME.
`
	if wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 0 {
		return errors.New(usage)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.ListRemoteDesktopSessions(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcScreenControl(args []string) error {
	const usage = `Usage: dieter screen control take|release SESSION

Give a connected control-capable client exclusive keyboard/mouse control, or
release its current grant. Taking control first releases the previous client's
held input. Viewers keep streaming. Both clients must support protocol 3 for
handoff; older controlling clients must disconnect first. Prints session state
as JSON. Supports --machine ID|NAME.
`
	if groupHelp(args) || wantsHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	if len(args) != 2 || (args[0] != "take" && args[0] != "release") || strings.TrimSpace(args[1]) == "" {
		return errors.New(usage)
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.SetRemoteDesktopControl(rpcCtx, &dieterv1.RemoteDesktopControlRequest{SessionId: args[1], TakeControl: args[0] == "take"})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcScreenClipboard(args []string) error {
	const usage = `Usage: dieter screen clipboard read|write|paste|copy|cut|enable|disable SESSION [options]

Share text, images and regular files with an existing controlling screen session.
write updates the host clipboard; paste also invokes the native paste shortcut
once. copy/cut invoke the host shortcut and return the copied content. read returns
protobuf JSON (binary data is base64). enable/disable controls session sharing.

write/paste require exactly one format:
  --file FILE|-      UTF-8 text, at most 1 MiB (use - for stdin)
  --image FILE       PNG, JPEG, TIFF or WebP, at most 8 MiB
  --attach FILE      Regular file; repeat for up to 64 files, 8 MiB combined
read/copy/cut optionally accept:
  --output-dir DIR   Save binary items under a new private directory; never overwrite

Folders, links and duplicate filenames are rejected. Temporary native clipboard
files use DIETER_HOME/clipboard; the next transfer prunes old (24h) batches
and retains at most eight batches.
Mutations are never automatically retried. Supports global --machine ID|NAME
with direct TLS and relay fallback. Binary sharing requires an updated daemon.
`
	if groupHelp(args) || (len(args) > 1 && wantsHelp(args[1:])) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	action := args[0]
	actions := map[string]dieterv1.RemoteDesktopClipboardRequest_Action{"read": dieterv1.RemoteDesktopClipboardRequest_READ, "write": dieterv1.RemoteDesktopClipboardRequest_WRITE, "paste": dieterv1.RemoteDesktopClipboardRequest_PASTE, "copy": dieterv1.RemoteDesktopClipboardRequest_COPY, "cut": dieterv1.RemoteDesktopClipboardRequest_CUT, "enable": dieterv1.RemoteDesktopClipboardRequest_CONFIGURE, "disable": dieterv1.RemoteDesktopClipboardRequest_CONFIGURE}
	kind, ok := actions[action]
	if !ok {
		return errors.New(usage)
	}
	set := flags("screen clipboard " + action)
	file := set.String("file", "", "UTF-8 text file, or - for stdin")
	image := set.String("image", "", "PNG, JPEG, TIFF or WebP image")
	var attachments repeatedStrings
	set.Var(&attachments, "attach", "regular file (repeatable)")
	outputDir := set.String("output-dir", "", "new directory for received binary files")
	rest := args[1:]
	if len(rest) > 0 && !strings.HasPrefix(rest[0], "-") {
		rest = append(append([]string{}, rest[1:]...), rest[0])
	}
	help, err := parse(set, rest, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(usage)
	}
	var text string
	var items []*dieterv1.RemoteDesktopClipboardItem
	writing := action == "write" || action == "paste"
	formats := 0
	for _, present := range []bool{*file != "", *image != "", len(attachments) > 0} {
		if present {
			formats++
		}
	}
	if writing && formats != 1 {
		return errors.New("write/paste require exactly one of --file, --image, or --attach")
	}
	if !writing && formats != 0 {
		return errors.New("clipboard input flags require write or paste")
	}
	if *outputDir != "" && action != "read" && action != "copy" && action != "cut" {
		return errors.New("--output-dir requires read, copy or cut")
	}
	if *outputDir != "" {
		if _, err := os.Lstat(*outputDir); !os.IsNotExist(err) {
			return errors.New("--output-dir must not already exist")
		}
	}
	if writing && *file != "" {
		if *file == "" {
			return errors.New("write/paste require --file FILE or --file -")
		}
		var reader io.Reader = c.In
		if *file != "-" {
			f, e := os.Open(*file)
			if e != nil {
				return e
			}
			defer f.Close()
			reader = f
		}
		raw, e := io.ReadAll(io.LimitReader(reader, (1<<20)+1))
		if e != nil {
			return e
		}
		if len(raw) > 1<<20 || !utf8.Valid(raw) {
			return errors.New("clipboard requires UTF-8 text of at most 1 MiB")
		}
		text = string(raw)
	}
	if writing && *file == "" {
		paths := []string(attachments)
		if *image != "" {
			paths = []string{*image}
		}
		if len(paths) > 64 {
			return errors.New("clipboard accepts at most 64 files")
		}
		total := 0
		names := make(map[string]bool)
		for _, path := range paths {
			info, err := os.Lstat(path)
			if err != nil {
				return err
			}
			if !info.Mode().IsRegular() {
				return errors.New("clipboard requires regular files; folders and links are unsupported")
			}
			name := filepath.Base(path)
			if names[name] || len(name) > 255 || strings.ContainsAny(name, "/\\\x00") {
				return errors.New("invalid or duplicate clipboard filename")
			}
			names[name] = true
			if info.Size() > int64(remotedesktop.ClipboardBinaryMaxBytes-total) {
				return errors.New("clipboard files exceed 8 MiB")
			}
			f, err := os.Open(path)
			if err != nil {
				return err
			}
			raw, err := io.ReadAll(io.LimitReader(f, int64(remotedesktop.ClipboardBinaryMaxBytes-total+1)))
			_ = f.Close()
			if err != nil {
				return err
			}
			total += len(raw)
			if total > remotedesktop.ClipboardBinaryMaxBytes {
				return errors.New("clipboard files exceed 8 MiB")
			}
			item := &dieterv1.RemoteDesktopClipboardItem{Name: name, MimeType: screenClipboardMIME(raw), Data: raw}
			if *image != "" {
				item.Kind = dieterv1.RemoteDesktopClipboardItem_IMAGE
				if item.MimeType != "image/png" && item.MimeType != "image/jpeg" && item.MimeType != "image/tiff" && item.MimeType != "image/webp" {
					return errors.New("unsupported clipboard image format")
				}
			}
			items = append(items, item)
		}
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	state, err := client.GetRemoteDesktopSession(rpcCtx, &dieterv1.RemoteDesktopRef{SessionId: set.Arg(0)})
	if err != nil {
		return err
	}
	id := make([]byte, 16)
	if _, err = rand.Read(id); err != nil {
		return err
	}
	if len(items) > 0 {
		caps, err := client.GetRemoteDesktopCapabilities(rpcCtx, &emptypb.Empty{})
		if err != nil {
			return err
		}
		if !caps.BinaryClipboardSupported {
			return errors.New("update the daemon to share images and files")
		}
	}
	value, err := client.ExchangeRemoteDesktopClipboard(rpcCtx, &dieterv1.RemoteDesktopClipboardRequest{SessionId: set.Arg(0), OperationId: hex.EncodeToString(id), ControlGeneration: state.ControlGeneration, Action: kind, Text: text, Items: items, AcceptBinary: true, Enabled: action == "enable"})
	if err != nil {
		return err
	}
	if value.Error != "" {
		return errors.New(value.Error)
	}
	if *outputDir != "" && len(value.Items) > 0 {
		if err := os.Mkdir(*outputDir, 0700); err != nil {
			return err
		}
		for _, item := range value.Items {
			if item.Name == "" || item.Name == "." || item.Name == ".." || strings.ContainsAny(item.Name, "/\\\x00") {
				return errors.New("invalid received clipboard filename")
			}
			f, err := os.OpenFile(filepath.Join(*outputDir, item.Name), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
			if err != nil {
				return err
			}
			_, err = f.Write(item.Data)
			closeErr := f.Close()
			if err != nil {
				return err
			}
			if closeErr != nil {
				return closeErr
			}
			item.Data = nil
		}
	}
	return protoJSONOut(c.Out, value)
}

// net/http's browser-oriented sniff table omits TIFF, which is a native macOS
// pasteboard representation. Recognize its byte-order header explicitly.
func screenClipboardMIME(raw []byte) string {
	if len(raw) >= 4 && (string(raw[:4]) == "II*\x00" || string(raw[:4]) == "MM\x00*") {
		return "image/tiff"
	}
	return http.DetectContentType(raw)
}
