package cli

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"text/tabwriter"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/security/roster"
	"google.golang.org/protobuf/types/known/emptypb"
)

const deviceHelp = `Usage: dieter device <action> [options]

The account's devices: a signed, append-only roster of device keys that every
machine and app verifies itself. Remote calls run mutually authenticated TLS
between roster devices, so the gateway relays bytes but can neither read them,
impersonate a device, nor add one. A new device shows a one-time code; type
that code on a trusted device to approve it. Never share a code you did not
just see on your own new device.

Actions:
  status    Show trust state, roster head, pairing code and devices
  roster    List the verified roster entries
  sync      Refresh the roster from the gateway; offer ours with --machine
  init      Start the account's roster on this machine; prints a recovery key
  requests  List devices waiting for approval (names only, never codes)
  approve   Approve the device that shows CODE
  revoke    Remove a device from the roster
  recover   Rejoin this machine with the recovery key

status, roster, sync, requests, approve and revoke accept --machine ID|NAME.
init and recover run only on the machine itself. Agent turns cannot change
device trust.
`

func (c *CLI) rpcDevice(args []string) error {
	if groupHelp(args) {
		fmt.Fprint(c.Out, deviceHelp)
		return nil
	}
	actions := map[string]func([]string) error{
		"status": c.deviceStatus, "roster": c.deviceRoster, "sync": c.deviceSync, "init": c.deviceInit,
		"requests": c.deviceRequests, "approve": c.deviceApprove, "revoke": c.deviceRevoke, "recover": c.deviceRecover,
	}
	action, ok := actions[args[0]]
	if !ok {
		return fmt.Errorf("unknown device action %q; run `dieter device --help`", args[0])
	}
	return action(args[1:])
}

// deviceMutation refuses agent turns before contacting any daemon: a turn
// token is only sent to the local daemon, so --machine would otherwise hide it.
func (c *CLI) deviceMutation(localOnly bool, command string) error {
	if c.env.TurnToken != "" {
		return errors.New("agents cannot change device trust; ask the operator")
	}
	if localOnly && strings.TrimSpace(c.Machine) != "" {
		return fmt.Errorf("dieter device %s runs only on the machine itself; omit --machine", command)
	}
	return nil
}

func trustStateLabel(state dieterv1.TrustState) string {
	return strings.TrimPrefix(state.String(), "TRUST_STATE_")
}

func deviceKindLabel(kind gatewayv1.DeviceKind) string {
	switch kind {
	case gatewayv1.DeviceKind_DEVICE_KIND_DAEMON:
		return "machine"
	case gatewayv1.DeviceKind_DEVICE_KIND_CLIENT:
		return "app"
	case gatewayv1.DeviceKind_DEVICE_KIND_RECOVERY:
		return "recovery"
	}
	return "unknown"
}

func trustStatusTable(out io.Writer, value *dieterv1.TrustStatus) error {
	writer := tabwriter.NewWriter(out, 0, 4, 2, ' ', 0)
	fmt.Fprintf(writer, "State:\t%s\n", trustStateLabel(value.GetState()))
	if value.GetDeviceId() != "" {
		fmt.Fprintf(writer, "This device:\t%s\n", value.GetDeviceId())
	}
	if value.GetRootHash() != "" {
		fmt.Fprintf(writer, "Roster:\troot %s, head %d (%s)\n", value.GetRootHash(), value.GetHeadSequence(), value.GetHeadHash())
	}
	if value.GetSyncedAt() != "" {
		fmt.Fprintf(writer, "Synced:\t%s\n", value.GetSyncedAt())
	}
	if value.GetDetail() != "" {
		fmt.Fprintf(writer, "Detail:\t%s\n", value.GetDetail())
	}
	if code := value.GetPairingCode(); code != "" {
		fmt.Fprintf(writer, "Pairing code:\t%s\n", code)
	}
	if len(value.GetDevices()) > 0 {
		fmt.Fprintln(writer, "\nDEVICE\tKIND\tPLATFORM\tNAME\tSTATE")
		for _, device := range value.GetDevices() {
			state := "active"
			if device.GetRevoked() {
				state = "removed"
			}
			if device.GetThisDevice() {
				state += " (this machine)"
			}
			fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\n", device.GetDeviceId(), deviceKindLabel(device.GetKind()), device.GetPlatform(), device.GetName(), state)
		}
	}
	if err := writer.Flush(); err != nil {
		return err
	}
	switch value.GetState() {
	case dieterv1.TrustState_TRUST_STATE_PENDING:
		fmt.Fprintln(out, "\nType this code on a trusted device: Devices → Add a device, or `dieter device approve CODE` on a trusted machine.")
	case dieterv1.TrustState_TRUST_STATE_NO_ROSTER:
		fmt.Fprintln(out, "\nNo device roster exists for this account yet. Start it on this machine with `dieter device init`.")
	case dieterv1.TrustState_TRUST_STATE_CONFLICT:
		fmt.Fprintln(out, "\nThe gateway or a peer presented a roster that conflicts with the pinned one; remote calls are refused. Your gateway may be compromised.")
	case dieterv1.TrustState_TRUST_STATE_REVOKED:
		fmt.Fprintln(out, "\nThis machine was removed from the roster; remote devices no longer connect to it.")
	}
	return nil
}

func (c *CLI) deviceStatus(args []string) error {
	const usage = `Usage: dieter device status [--format text|json]

Show the target machine's device trust: its state (NO_ROSTER, PENDING,
TRUSTED, REVOKED or CONFLICT), the pinned roster's root and head, the
devices of the account, and, while PENDING, the one-time code to type on a
trusted device.
`
	set := flags("device status")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.GetTrustStatus(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	return trustStatusTable(c.Out, value)
}

func (c *CLI) deviceRoster(args []string) error {
	const usage = `Usage: dieter device roster [--from SEQUENCE] [--format text|json]

List the entries of the target machine's verified device roster from
SEQUENCE: who added or removed which device, signed by which member.
`
	set := flags("device roster")
	from := set.Uint64("from", 0, "first sequence number")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.GetDeviceRoster(rpcCtx, &gatewayv1.GetDeviceRosterRequest{FromSequence: *from})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	writer := tabwriter.NewWriter(c.Out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "SEQ\tOPERATION\tDEVICE\tKIND\tNAME\tSIGNER\tCREATED")
	for _, entry := range value.GetEntries() {
		device := entry.GetDevice()
		operation := strings.ToLower(strings.TrimPrefix(entry.GetOperation().String(), "DEVICE_ROSTER_OPERATION_"))
		fmt.Fprintf(writer, "%d\t%s\t%s\t%s\t%s\t%s\t%s\n", entry.GetSequence(), operation, device.GetDeviceId(), deviceKindLabel(device.GetKind()), device.GetName(), entry.GetSigner(), entry.GetCreatedAt())
	}
	return writer.Flush()
}

func (c *CLI) deviceSync(args []string) error {
	const usage = `Usage: dieter device sync [--format text|json]

Refresh the target machine's roster from the gateway. With --machine, also
offer this machine's pinned roster to the target, so it learns entries the
gateway withholds; it adopts only entries that extend its own pinned chain.
`
	set := flags("device sync")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if err := c.deviceMutation(false, "sync"); err != nil {
		return err
	}
	request := &dieterv1.SyncDeviceRosterRequest{}
	if strings.TrimSpace(c.Machine) != "" {
		if pinned, err := link.PinnedRoster(c.Root); err == nil {
			request.Entries = pinned.Entries(0)
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.SyncDeviceRoster(rpcCtx, request)
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	return trustStatusTable(c.Out, value)
}

func (c *CLI) deviceInit(args []string) error {
	const usage = `Usage: dieter device init [--replace] [--format text|json]

Start the account's device roster with this machine as its first device and
print a one-time recovery key. Run it once, on the first machine. If other
devices already use Dieter, do not run it: pair this machine instead. Without
--replace it refuses an account that already has a roster; --replace starts a
new roster that every previously paired device rejects: apps reset and pair
again, other machines run ` + "`dieter daemon unenroll`" + ` and enroll again.
`
	set := flags("device init")
	replace := set.Bool("replace", false, "discard the account's existing roster")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if err := c.deviceMutation(true, "init"); err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.InitializeDeviceRoster(rpcCtx, &dieterv1.InitializeDeviceRosterRequest{Replace: *replace})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	printRecoveryKey(c.Out, value.GetRecoveryKey())
	return nil
}

func printRecoveryKey(out io.Writer, key string) {
	fmt.Fprintf(out, `Started the account's device roster on this machine.

Recovery key (shown once; store it offline, e.g. on paper):

  %s

Anyone with this key can add a machine to your account. If every trusted
device is lost, rejoin a machine with:
  dieter device recover --recovery-key -
Add more devices by typing the code they show here:
  dieter device approve CODE
`, key)
}

func (c *CLI) deviceRequests(args []string) error {
	const usage = `Usage: dieter device requests [--format text|json]

List the devices waiting to join the account, by name. Their codes are never
listed: approve a device only with the code its own screen shows you.
`
	set := flags("device requests")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.ListPairingRequests(rpcCtx, &emptypb.Empty{})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	if len(value.GetRequests()) == 0 {
		fmt.Fprintln(c.Out, "No device is waiting to join.")
		return nil
	}
	writer := tabwriter.NewWriter(c.Out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "NAME\tKIND\tPLATFORM\tDEVICE\tREQUESTED\tEXPIRES")
	for _, request := range value.GetRequests() {
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\n", request.GetName(), deviceKindLabel(request.GetKind()), request.GetPlatform(), request.GetDeviceId(), request.GetRequestedAt(), request.GetExpiresAt())
	}
	return writer.Flush()
}

func (c *CLI) deviceApprove(args []string) error {
	const usage = `Usage: dieter device approve [--format text|json] CODE

Approve the new device that shows CODE (16 characters, e.g. ABCD-EFGH-JKMN-PQRS;
case, spaces and hyphens do not matter). The code proves which key the new
device posted, so approving signs exactly that device into the roster. Only
type a code you see on your own new device.
`
	set := flags("device approve")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("device approve requires exactly one CODE")
	}
	if _, err := roster.ParsePairingCode(set.Arg(0)); err != nil {
		return err
	}
	if err := c.deviceMutation(false, "approve"); err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.ApproveDevice(rpcCtx, &dieterv1.ApproveDeviceRequest{Code: set.Arg(0)})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	fmt.Fprintf(c.Out, "Approved. The new device joins as soon as it sees the confirmation (roster head %d).\n", value.GetHeadSequence())
	return nil
}

func (c *CLI) deviceRevoke(args []string) error {
	const usage = `Usage: dieter device revoke [--format text|json] DEVICE_ID

Remove DEVICE_ID (dv_…, see dieter device status) from the roster. Machines
and apps stop accepting it as soon as they see the signed revocation; the last
device that can connect cannot be removed. Revoking this machine is allowed.
`
	set := flags("device revoke")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("device revoke requires exactly one DEVICE_ID")
	}
	if err := c.deviceMutation(false, "revoke"); err != nil {
		return err
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	value, err := client.RevokeDevice(rpcCtx, &dieterv1.RevokeDeviceRequest{DeviceId: set.Arg(0)})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, value)
	}
	return trustStatusTable(c.Out, value)
}

func (c *CLI) deviceRecover(args []string) error {
	const usage = `Usage: dieter device recover --recovery-key KEY|- [--format text|json]

Add this machine to the roster with the recovery key printed by
dieter device init, when no trusted device can approve it. "-" reads the key
from stdin, which keeps it out of shell history. The key commits to the
roster it was made for and never signs into another one.
`
	set := flags("device recover")
	key := set.String("recovery-key", "", "recovery key, or - to read it from stdin")
	format := set.String("format", "text", "text or json")
	if help, err := parse(set, args, usage, c.Out); help || err != nil {
		return err
	}
	if err := c.deviceMutation(true, "recover"); err != nil {
		return err
	}
	value := strings.TrimSpace(*key)
	if value == "-" {
		raw, err := io.ReadAll(io.LimitReader(c.In, 4<<10))
		if err != nil {
			return err
		}
		value = strings.TrimSpace(string(raw))
	}
	if value == "" {
		return errors.New("device recover requires --recovery-key KEY or --recovery-key -")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	client, rpcCtx, err := c.rpc(ctx)
	if err != nil {
		return err
	}
	status, err := client.RecoverDeviceTrust(rpcCtx, &dieterv1.RecoverDeviceTrustRequest{RecoveryKey: value})
	if err != nil {
		return err
	}
	if *format == "json" {
		return protoJSONOut(c.Out, status)
	}
	return trustStatusTable(c.Out, status)
}

// setupDeviceTrust starts the roster on the account's first machine or shows
// the code a new machine waits with, once the daemon reached the gateway.
func (c *CLI) setupDeviceTrust(timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	var value *dieterv1.TrustStatus
	for {
		ctx, cancel := c.commandContext()
		client, rpcCtx, err := c.rpc(ctx)
		if err == nil {
			value, err = client.GetTrustStatus(rpcCtx, &emptypb.Empty{})
		}
		cancel()
		if err != nil {
			return err
		}
		if value.GetState() != dieterv1.TrustState_TRUST_STATE_UNSPECIFIED || time.Now().After(deadline) {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	switch value.GetState() {
	case dieterv1.TrustState_TRUST_STATE_NO_ROSTER:
		fmt.Fprintln(c.Out, "No trusted devices exist for this account yet; this machine starts the device roster.")
		fmt.Fprintln(c.Out, "If you already use Dieter on other devices, stop and check your gateway: it may be compromised.")
		ctx, cancel := c.commandContext()
		defer cancel()
		client, rpcCtx, err := c.rpc(ctx)
		if err != nil {
			return err
		}
		initialized, err := client.InitializeDeviceRoster(rpcCtx, &dieterv1.InitializeDeviceRosterRequest{})
		if err != nil {
			return err
		}
		printRecoveryKey(c.Out, initialized.GetRecoveryKey())
	case dieterv1.TrustState_TRUST_STATE_PENDING:
		fmt.Fprintf(c.Out, "This machine waits to join the account's devices. Its one-time code:\n\n  %s\n\nType this code on a trusted device: Devices → Add a device, or `dieter device approve CODE` on a trusted machine.\n", value.GetPairingCode())
	case dieterv1.TrustState_TRUST_STATE_TRUSTED:
		fmt.Fprintln(c.Out, "This machine is a trusted device of the account.")
	case dieterv1.TrustState_TRUST_STATE_UNSPECIFIED:
		fmt.Fprintln(c.Out, "The daemon has not reached the gateway yet; check `dieter device status` shortly.")
	default:
		return trustStatusTable(c.Out, value)
	}
	return nil
}
