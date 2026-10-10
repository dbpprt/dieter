package cli

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"google.golang.org/protobuf/types/known/emptypb"
)

const designHelp = `Usage: dieter [--machine ID|NAME] design <action>

Connect Claude Code turns on a daemon machine to Claude Design (claude.ai/design).
Claude Code keeps the claude.ai login and the design credential in its own secure
storage on that machine; Dieter never copies them or sends them to the gateway.

Actions:
  status                     Show availability, sign-in and access on the machine
  login [--json]             Sign in to Claude Design on the machine
  code SIGN_IN_ID CODE       Submit an authorization code to a running sign-in
  access on|off [--revoke]   Allow or stop Claude Design in Claude Code turns

Access is off until enabled. "access on" also grants the Claude account's agent
access to Design projects, because headless turns cannot confirm it. "access off"
only stops Dieter's turns; add --revoke to withdraw that account-wide grant, which
affects every Claude Code session of the account.
`

const designLoginUsage = `Usage: dieter [--machine ID|NAME] design login [--json]

Starts Claude Code's Claude Design sign-in on the target machine and follows it
until it finishes or fails. The sign-in stays open on the machine for about five
minutes even if this command is interrupted, so a code can still complete it with
"dieter design code"; a newer sign-in replaces it.

The first page completes in a browser on the target machine. The second page works
from any device: it shows an authorization code, which you paste at the prompt.
With --json, events are printed as JSON Lines and the prompt is skipped; submit the
code with "dieter design code SIGN_IN_ID CODE" while the sign-in is running.
`

func (c *CLI) rpcDesign(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, designHelp)
		return nil
	}
	switch args[0] {
	case "status":
		const usage = "Usage: dieter [--machine ID|NAME] design status\n\nPrints the target machine's Claude Design status as JSON.\n"
		if wantsHelp(args[1:]) {
			fmt.Fprint(c.Out, usage)
			return nil
		}
		if len(args) != 1 {
			return errors.New("design status does not accept arguments; use global --machine")
		}
		ctx, cancel := context.WithTimeout(context.Background(), max(c.connectionTimeout(), time.Minute))
		defer cancel()
		client, rpcCtx, err := c.rpc(ctx)
		if err != nil {
			return err
		}
		value, err := client.GetClaudeDesignStatus(rpcCtx, &emptypb.Empty{})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, value)
	case "login", "sign-in":
		return c.rpcDesignLogin(args[1:])
	case "code":
		const usage = "Usage: dieter [--machine ID|NAME] design code SIGN_IN_ID CODE\n\nSubmits the authorization code shown by the sign-in page to the running sign-in.\n"
		if wantsHelp(args[1:]) {
			fmt.Fprint(c.Out, usage)
			return nil
		}
		if len(args) != 3 {
			return fmt.Errorf("design code requires SIGN_IN_ID and CODE\n\n%s", usage)
		}
		ctx, cancel := c.commandContext()
		defer cancel()
		client, rpcCtx, err := c.rpc(ctx)
		if err != nil {
			return err
		}
		value, err := client.SubmitClaudeDesignSignInCode(rpcCtx, &dieterv1.SubmitClaudeDesignSignInCodeRequest{SignInId: args[1], Code: args[2]})
		if err != nil {
			return err
		}
		return protoJSONOut(c.Out, value)
	case "access":
		return c.rpcDesignAccess(args[1:])
	default:
		return fmt.Errorf("unknown design action %q; run `dieter design --help`", args[0])
	}
}

func (c *CLI) rpcDesignAccess(args []string) error {
	const usage = `Usage: dieter [--machine ID|NAME] design access on|off [--revoke]

on   Allow Claude Code turns on the machine to use Claude Design. This also grants
     the Claude account's agent access to Design projects.
off  Stop Claude Code turns on the machine from using Claude Design. With --revoke,
     also withdraw the account-wide agent access for every Claude Code session.
`
	if groupHelp(args) {
		fmt.Fprint(c.Out, usage)
		return nil
	}
	action := args[0]
	if action != "on" && action != "off" {
		return fmt.Errorf("design access requires on or off\n\n%s", usage)
	}
	set := flags("design access " + action)
	revoke := set.Bool("revoke", false, "also revoke the Claude account's agent access (off only)")
	help, err := parse(set, args[1:], usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("design access does not accept positional arguments; use global --machine")
	}
	if action == "on" && *revoke {
		return errors.New("--revoke applies only to design access off")
	}
	// Granting or revoking runs Claude Code on the target machine.
	ctx, cancel := context.WithTimeout(context.Background(), max(c.connectionTimeout(), 3*time.Minute))
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.SetClaudeDesignAccess(rpcCtx, &dieterv1.SetClaudeDesignAccessRequest{Enabled: action == "on", RevokeGrant: *revoke})
	if err != nil {
		return err
	}
	return protoJSONOut(c.Out, value)
}

func (c *CLI) rpcDesignLogin(args []string) error {
	set := flags("design login")
	jsonLines := set.Bool("json", false, "print events as JSON Lines without prompting for a code")
	help, err := parse(set, args, designLoginUsage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return errors.New("design login does not accept positional arguments; use global --machine")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	stream, err := client.SignInClaudeDesign(rpcCtx, &dieterv1.SignInClaudeDesignRequest{})
	if err != nil {
		return err
	}
	prompted := false
	for {
		event, err := stream.Recv()
		if err != nil {
			if endErr := streamEnd(err, ctx); endErr != nil || ctx.Err() != nil {
				return endErr
			}
			return errors.New("the Claude Design sign-in stream ended before the sign-in finished")
		}
		if *jsonLines {
			if err := protoJSONLine(c.Out, event); err != nil {
				return err
			}
		}
		switch {
		case event.GetDone():
			if !*jsonLines && event.GetMessage() != "" {
				fmt.Fprintln(c.Out, event.GetMessage())
			}
			if !event.GetOk() {
				return errors.New("Claude Design sign-in did not complete")
			}
			return nil
		case event.GetPreparing() && !*jsonLines:
			fmt.Fprintln(c.Out, event.GetMessage())
		case (event.GetUrl() != "" || event.GetManualUrl() != "") && !*jsonLines && !prompted:
			prompted = true
			if event.GetUrl() != "" {
				fmt.Fprintf(c.Out, "Open this page in a browser on the target machine to finish automatically:\n  %s\n", event.GetUrl())
			}
			if event.GetManualUrl() != "" {
				fmt.Fprintf(c.Out, "Or open this page on any device and paste the code it shows below:\n  %s\nCode: ", event.GetManualUrl())
				go c.submitDesignCodes(ctx, event.GetSignInId())
			}
		}
	}
}

// submitDesignCodes forwards pasted codes until the sign-in ends. Each code is
// a separate bounded request; a rejected code leaves the sign-in running.
func (c *CLI) submitDesignCodes(ctx context.Context, signInID string) {
	if c.In == nil {
		return
	}
	scanner := bufio.NewScanner(c.In)
	for scanner.Scan() {
		code := strings.TrimSpace(scanner.Text())
		if code == "" || ctx.Err() != nil {
			continue
		}
		requestCtx, cancel := context.WithTimeout(ctx, c.connectionTimeout())
		client, rpcCtx, err := c.rpc(requestCtx)
		if err == nil {
			_, err = client.SubmitClaudeDesignSignInCode(rpcCtx, &dieterv1.SubmitClaudeDesignSignInCodeRequest{SignInId: signInID, Code: code})
		}
		cancel()
		if err != nil && ctx.Err() == nil {
			fmt.Fprintf(c.Err, "The code was not accepted: %v\nCode: ", err)
		}
	}
}
