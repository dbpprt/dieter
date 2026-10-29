package cli

import (
	"errors"
	"flag"
	"fmt"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

const virtualDisplayHelp = `Usage: dieter screen virtual <status|set|presented|restore> SESSION [options]

Experimental macOS virtual desktop, owned by the controlling session.
Enable DIETER_SCREEN_VIRTUAL_DISPLAY=1 on the host before starting its daemon.
set requires --width PIXELS --height PIXELS [--scale 1|2] [--disable-physical].
Dimensions must fit H.264 3840x2160 or HEVC 1920x1080, with even logical pixels.
The actual host desktop changes. Only one controlling session can own it.
presented requires --display ID --generation N: send ONLY after rendering a frame
from that exact display/media generation. An unseen desktop restores after 15s.
Physical disabling additionally requires DIETER_SCREEN_VIRTUAL_DISABLE=1 and
hardware qualification; the physical main is disabled only after presentation.
restore re-enables physical output before removing the virtual display. Control
handoff, disconnect, helper failure, and local display changes also restore it.
Supports local, verified direct TLS, and gateway relay with --machine ID|NAME.
`

func (c *CLI) rpcVirtualDisplay(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, virtualDisplayHelp)
		return nil
	}
	action := args[0]
	if action != "status" && action != "set" && action != "presented" && action != "restore" {
		return errors.New(virtualDisplayHelp)
	}
	set := flags("screen virtual " + action)
	width := set.Int("width", 0, "backing pixel width")
	height := set.Int("height", 0, "backing pixel height")
	scale := set.Int("scale", 2, "macOS UI scale: 1 or 2")
	disable := set.Bool("disable-physical", false, "disable original physical main after presentation")
	display := set.String("display", "", "presented virtual display ID")
	generation := set.Uint64("generation", 0, "presented display/media generation")
	help, err := parse(set, args[1:], virtualDisplayHelp, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(virtualDisplayHelp)
	}
	if (action == "status" || action == "restore") && set.NFlag() != 0 {
		return errors.New("flags apply only to virtual set or presented")
	}
	if action == "set" && (*width < 320 || *width > 3840 || *height < 180 || *height > 2160 || (*scale != 1 && *scale != 2) || *width%(2**scale) != 0 || *height%(2**scale) != 0 || *display != "" || *generation != 0) {
		return errors.New(virtualDisplayHelp)
	}
	if action == "presented" && (*display == "" || *generation == 0 || *width != 0 || *height != 0 || *disable) {
		return errors.New(virtualDisplayHelp)
	}
	if action == "presented" {
		invalid := false
		set.Visit(func(f *flag.Flag) {
			if f.Name != "display" && f.Name != "generation" {
				invalid = true
			}
		})
		if invalid {
			return errors.New(virtualDisplayHelp)
		}
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	var result *dieterv1.RemoteDesktopVirtualDisplay
	ref := &dieterv1.RemoteDesktopRef{SessionId: set.Arg(0)}
	switch action {
	case "status":
		result, err = client.GetRemoteDesktopVirtualDisplay(rpcCtx, ref)
	case "restore":
		result, err = client.RestoreRemoteDesktopVirtualDisplay(rpcCtx, ref)
	case "set":
		result, err = client.SetRemoteDesktopVirtualDisplay(rpcCtx, &dieterv1.SetRemoteDesktopVirtualDisplayRequest{SessionId: ref.SessionId, PixelWidth: int32(*width), PixelHeight: int32(*height), Scale: int32(*scale), DisablePhysical: *disable})
	case "presented":
		result, err = client.ConfirmRemoteDesktopVirtualDisplay(rpcCtx, &dieterv1.ConfirmRemoteDesktopVirtualDisplayRequest{SessionId: ref.SessionId, DisplayId: *display, DisplayGeneration: *generation})
	}
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, result)
}
