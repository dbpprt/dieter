package cli

import (
	"errors"
	"fmt"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
)

const resolutionHelp = `Usage: dieter screen resolution <modes|set|restore> SESSION [options]

Experimental physical desktop resolution, independent of video stream ceilings.
"modes" lists the selected display's supported modes and current mode ID.
"set" requires --display ID --mode ID --expected-current ID from a fresh modes
response. It requires the controlling session and temporarily changes the actual
remote monitor for everyone using it. "restore" restores the leased original mode.
Control handoff, display selection, session closure, and helper exit also restore
the mode. A later local display change takes precedence. Supports --machine ID|NAME.
`

func (c *CLI) rpcScreenResolution(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, resolutionHelp)
		return nil
	}
	action := args[0]
	if action != "modes" && action != "set" && action != "restore" {
		return errors.New(resolutionHelp)
	}
	usage := "Usage: dieter screen resolution " + action + " SESSION"
	if action == "set" {
		usage += " --display ID --mode ID --expected-current ID"
	}
	usage += "\n\n" + resolutionHelp
	set := flags("screen resolution " + action)
	display := set.String("display", "", "display ID returned by modes")
	mode := set.String("mode", "", "supported mode ID returned by modes")
	expected := set.String("expected-current", "", "current mode ID returned by modes")
	help, err := parse(set, args[1:], usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New(usage)
	}
	if action == "set" && (*display == "" || *mode == "" || *expected == "") {
		return errors.New(usage)
	}
	if action != "set" && set.NFlag() != 0 {
		return errors.New("mode flags apply only to resolution set")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	var result *dieterv1.RemoteDesktopDisplayModes
	ref := &dieterv1.RemoteDesktopRef{SessionId: set.Arg(0)}
	switch action {
	case "modes":
		result, err = client.ListRemoteDesktopDisplayModes(rpcCtx, ref)
	case "restore":
		result, err = client.RestoreRemoteDesktopDisplayMode(rpcCtx, ref)
	case "set":
		result, err = client.SetRemoteDesktopDisplayMode(rpcCtx, &dieterv1.SetRemoteDesktopDisplayModeRequest{SessionId: ref.SessionId, DisplayId: *display, ModeId: *mode, ExpectedCurrentModeId: *expected})
	}
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, result)
}
