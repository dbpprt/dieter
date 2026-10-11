package cli

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/buildinfo"
	"github.com/dbpprt/dieter/internal/platform/config"
	"github.com/dbpprt/dieter/internal/security/linkauth"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

var Version = buildinfo.ReleaseVersion

type CLI struct {
	Out, Err io.Writer
	In       io.Reader
	// Root is the local DIETER_HOME holding this machine's enrollment and
	// local API credentials. Commands never read central storage directly.
	Root string
	env  config.Client

	GatewayURL string
	Machine    string
	Timeout    time.Duration
	transport  *dieterTransport
	gateway    *gatewayTransport
}

// New returns a CLI for the local DIETER_HOME root.
func New(root string) *CLI {
	return &CLI{Out: os.Stdout, Err: os.Stderr, In: os.Stdin, Root: config.ResolveHome(root), env: config.LoadClient(config.Environ())}
}

// Main runs one client command and returns the process exit code. The daemon
// entry points (serve, daemon start, and hidden workers) are dispatched to
// internal/daemon by cmd/dieter before Main is called.
func Main(args []string) int {
	globals, rest, err := config.ParseGlobals(args)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	client := New(globals.Home)
	client.GatewayURL, client.Machine, client.Timeout = globals.Gateway, globals.Machine, globals.Timeout
	defer client.Close()
	if globals.Help {
		client.rootHelp()
		return 0
	}
	if globals.Version {
		fmt.Fprintln(client.Out, Version)
		return 0
	}
	if err := client.Run(rest); err != nil {
		var remoteExit *remoteExitError
		if errors.As(err, &remoteExit) {
			return remoteExit.Code()
		}
		var childExit *exitStatusError
		if errors.As(err, &childExit) {
			return childExit.code
		}
		fmt.Fprintln(client.Err, "error:", err)
		return 1
	}
	return 0
}

func (c *CLI) Run(args []string) error {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" {
		c.rootHelp()
		return nil
	}
	if args[0] == "help" {
		if len(args) == 1 {
			c.rootHelp()
			return nil
		}
		args = append(append([]string(nil), args[1:]...), "--help")
	}
	for _, command := range commandTable() {
		if command.matches(args[0]) {
			return command.run(c, args[1:])
		}
	}
	return fmt.Errorf("unknown command %q; run dieter --help", args[0])
}

func (c *CLI) rootHelp() {
	fmt.Fprint(c.Out, `Dieter — control local or enrolled Dieter daemon machines

Usage:
  dieter [global options] <command> [options]

Global options:
  --store PATH             DIETER_HOME (default ~/.dieter)
  --gateway URL            Require this enrolled gateway origin
  --machine ID|NAME        Target an enrolled daemon; omit for the local daemon
  --timeout DURATION       Unary command and connection timeout (default 15s)
  --harness-config PATH    Local daemon harness registry YAML
  --help, -h               Show this help
  --version                Print the version

Commands:
`)
	for _, command := range commandTable() {
		fmt.Fprintf(c.Out, "  %-13s%s\n", command.name, command.summary)
	}
	fmt.Fprint(c.Out, `
Without --machine, operational commands use the running local daemon API. With
--machine, the CLI uses the local daemon's enrollment to authenticate to the
gateway, prefers direct TLS, then tries WebRTC (direct or TURN), and falls back
to the bounded gateway relay.
Status reports the selected route. It never reads a remote machine's storage.
Read watches renew credentials and resume after transient failures, with five
retries between delivered frames. Revocation stops recovery; mutations and
process starts are never replayed by watch recovery.

Run "dieter help <command> [action]" or append --help at any command depth.
`)
}

func flags(name string) *flag.FlagSet {
	set := flag.NewFlagSet(name, flag.ContinueOnError)
	set.SetOutput(io.Discard)
	return set
}
func parse(set *flag.FlagSet, args []string, usage string, out io.Writer) (bool, error) {
	for _, arg := range args {
		if arg == "--help" || arg == "-h" {
			fmt.Fprint(out, usage)
			return true, nil
		}
	}
	if err := set.Parse(interspersed(set, args)); err != nil {
		return false, fmt.Errorf("%w\n\n%s", err, usage)
	}
	return false, nil
}

type boolFlag interface{ IsBoolFlag() bool }

func interspersed(set *flag.FlagSet, args []string) []string {
	var opts, pos []string
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if strings.HasPrefix(arg, "-") && arg != "-" {
			opts = append(opts, arg)
			name := strings.TrimLeft(arg, "-")
			if strings.Contains(name, "=") {
				continue
			}
			field := set.Lookup(name)
			if field != nil {
				if b, ok := field.Value.(boolFlag); ok && b.IsBoolFlag() {
					continue
				}
				if i+1 < len(args) {
					i++
					opts = append(opts, args[i])
				}
			}
		} else {
			pos = append(pos, arg)
		}
	}
	return append(opts, pos...)
}
func textValue(value, path string, in io.Reader) (string, error) {
	if value != "" && path != "" {
		return "", errors.New("use either inline text or a file, not both")
	}
	if path == "" {
		return strings.TrimSpace(value), nil
	}
	var data []byte
	var err error
	if path == "-" {
		data, err = io.ReadAll(in)
	} else {
		data, err = os.ReadFile(path)
	}
	return strings.TrimSpace(string(data)), err
}

type repeatedStrings []string

func (values *repeatedStrings) String() string { return strings.Join(*values, ",") }
func (values *repeatedStrings) Set(value string) error {
	value = strings.TrimSpace(value)
	if value == "" {
		return errors.New("attachment path is required")
	}
	*values = append(*values, value)
	return nil
}

func attachmentParts(paths []string) ([]model.UIMessagePart, error) {
	if len(paths) == 0 {
		return nil, nil
	}
	parts := make([]model.UIMessagePart, 0, len(paths))
	for _, path := range paths {
		if path == "-" {
			return nil, errors.New("attachments must be local files; - is only supported for message text")
		}
		info, err := os.Stat(path)
		if err != nil {
			return nil, fmt.Errorf("read attachment %q: %w", path, err)
		}
		if !info.Mode().IsRegular() {
			return nil, fmt.Errorf("attachment %q is not a regular file", path)
		}
		if info.Size() > model.MaxAttachmentBytes {
			return nil, fmt.Errorf("attachment %q must be at most 5 MB", path)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read attachment %q: %w", path, err)
		}
		parts = append(parts, model.AttachmentPart(filepath.Base(path), "", data))
	}
	return model.NormalizeMessageParts(parts)
}
func jsonOut(out io.Writer, value any) error {
	enc := json.NewEncoder(out)
	enc.SetIndent("", "  ")
	return enc.Encode(value)
}

// errDaemonEntryPoint is returned when a daemon entry point reaches the
// client dispatcher; cmd/dieter routes those to internal/daemon.
var errDaemonEntryPoint = errors.New("the daemon runs through the dieter executable; use `dieter daemon start`")

func (c *CLI) daemon(args []string) error {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" {
		fmt.Fprint(c.Out, `Usage: dieter daemon <action>

Actions:
  start        Run the local data plane and persistent gateway tunnel
  service      Install and manage the platform daemon service
  enroll       Enroll this machine with the Dieter gateway
  recover      Restore a revoked local daemon ID with this replacement key
  unenroll     Revoke this machine and remove its local gateway credential
  status       Show service, local API, enrollment, and gateway health
  logs         Show or follow the daemon service log
  permissions  Verify screen/input permissions through the running daemon
`)
		return nil
	}
	switch args[0] {
	case "start":
		return errDaemonEntryPoint
	case "service":
		return c.daemonService(args[1:])
	case "enroll":
		return c.daemonEnroll(args[1:])
	case "recover":
		return c.daemonRecover(args[1:])
	case "unenroll":
		return c.daemonUnenroll(args[1:])
	case "status":
		return c.daemonStatus(args[1:])
	case "logs":
		return c.daemonLogs(args[1:])
	case "permissions":
		return c.daemonPermissions(args[1:])
	default:
		return fmt.Errorf("unknown daemon action %q", args[0])
	}
}

func (c *CLI) daemonEnroll(args []string) error {
	const usage = `Usage: dieter daemon enroll [--gateway URL] [--name NAME] [--no-open]

Enroll this machine with the GitHub account configured by the Dieter gateway.
Retry incomplete enrollment with --gateway to correct the origin without changing
the machine key. Completed enrollments retain their identity.
Gateway URLs require HTTPS; HTTP is allowed only on literal loopback addresses.
`
	set := flags("daemon enroll")
	gatewayURL := set.String("gateway", buildinfo.DefaultGatewayURL, "gateway origin")
	hostname, _ := os.Hostname()
	name := set.String("name", hostname, "machine display name")
	noOpen := set.Bool("no-open", false, "do not open the verification URL")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	identity, err := link.LoadOrCreateEnrollmentIdentity(c.Root, strings.TrimSpace(*name), strings.TrimRight(strings.TrimSpace(*gatewayURL), "/"))
	if err != nil {
		return err
	}
	if identity.Enrolled() {
		return fmt.Errorf("this daemon is already enrolled as %s", identity.ID)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Minute)
	defer cancel()
	fmt.Fprintf(c.Out, "Enrollment gateway: %s\n", identity.GatewayURL)
	enrollment, err := link.BeginEnrollment(ctx, identity)
	if err != nil {
		return fmt.Errorf("begin enrollment at %s: %w", identity.GatewayURL, err)
	}
	fmt.Fprintf(c.Out, "Authorize this daemon with GitHub:\n%s\n\nCode: %s\n", enrollment.GetVerificationUrl(), enrollment.GetUserCode())
	if !*noOpen {
		command := "xdg-open"
		if runtime.GOOS == "darwin" {
			command = "open"
		}
		_ = exec.Command(command, enrollment.GetVerificationUrl()).Start()
	}
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		credential, completeErr := link.CompleteEnrollment(ctx, identity, enrollment.GetEnrollmentId(), enrollment.GetEnrollmentSecret())
		if completeErr == nil {
			identity.GatewayIssuer = credential.GetGatewayIssuer()
			if err := identity.SaveCredential(credential.GetDaemonId(), credential.GetDaemonName(), credential.GetCertificatePem(), credential.GetDaemonCaPem(), credential.GetGatewaySigningPublicKey(), credential.GetExpiresAt(), credential.GetGeneration()); err != nil {
				return err
			}
			fmt.Fprintf(c.Out, "Enrolled %s as %s.\n", credential.GetDaemonName(), credential.GetDaemonId())
			return nil
		}
		if status.Code(completeErr) != codes.FailedPrecondition {
			return fmt.Errorf("complete daemon enrollment: %w", completeErr)
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("daemon enrollment timed out: %w", ctx.Err())
		case <-ticker.C:
		}
	}
}

func (c *CLI) daemonRecover(args []string) error {
	const usage = `Usage: dieter daemon recover --old-id ID --confirm RECOVER

Restore a revoked daemon ID using this enrolled replacement's matching key.
This changes the saved local credential only after the gateway accepts and the
returned certificate is verified. Restart the daemon service manually afterward;
verify the restored daemon before revoking the replacement ID.
`
	set := flags("daemon recover")
	oldID := set.String("old-id", "", "revoked daemon ID to restore")
	confirm := set.String("confirm", "", "must be RECOVER")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if c.Machine != "" {
		return errors.New("daemon recover is local-only; omit --machine")
	}
	if set.NArg() != 0 {
		return fmt.Errorf("daemon recover does not accept positional arguments\n\n%s", usage)
	}
	if strings.TrimSpace(*oldID) == "" {
		return errors.New("daemon recover requires --old-id ID")
	}
	if *confirm != "RECOVER" {
		return errors.New("daemon recover requires --confirm RECOVER")
	}
	identity, _, err := c.gatewayIdentity()
	if err != nil {
		return err
	}
	replacementID := identity.ID
	if *oldID == replacementID {
		return errors.New("--old-id must differ from the current replacement daemon ID")
	}
	ctx, cancel := c.commandContext()
	defer cancel()
	gateway, err := c.dialGateway(ctx)
	if err != nil {
		return fmt.Errorf("connect to Dieter gateway for recovery: %w", err)
	}
	state, err := gateway.client.InspectDaemonRecovery(ctx, &gatewayv1.DaemonRecoveryRef{
		RevokedDaemonId: *oldID, ReplacementDaemonId: replacementID,
	})
	if err != nil {
		return fmt.Errorf("inspect daemon %s recovery at gateway: %w", *oldID, err)
	}
	if state.GetRevokedGeneration() < 2 || state.GetReplacementGeneration() != identity.Generation {
		return errors.New("gateway recovery generations do not match this revoked ID and replacement credential")
	}
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		return fmt.Errorf("create daemon recovery nonce: %w", err)
	}
	credential, err := gateway.client.RecoverDaemon(ctx, &gatewayv1.RecoverDaemonRequest{
		RevokedDaemonId: *oldID, ReplacementDaemonId: replacementID, Nonce: nonce,
		RevokedGeneration: state.GetRevokedGeneration(), ReplacementGeneration: state.GetReplacementGeneration(),
		Signature: linkauth.SignRecovery(identity.PrivateKey, identity.Issuer(), *oldID, replacementID, state.GetRevokedGeneration(), state.GetReplacementGeneration(), nonce),
	})
	if err != nil {
		return fmt.Errorf("recover daemon %s at gateway (local credential unchanged; retry is safe): %w", *oldID, err)
	}
	if err := validateRecoveredCredential(identity, *oldID, state.GetRevokedGeneration(), credential); err != nil {
		return fmt.Errorf("gateway returned invalid recovered credential (local credential unchanged): %w", err)
	}
	if err := identity.SaveCredential(credential.GetDaemonId(), credential.GetDaemonName(), credential.GetCertificatePem(), credential.GetDaemonCaPem(), credential.GetGatewaySigningPublicKey(), credential.GetExpiresAt(), credential.GetGeneration()); err != nil {
		return fmt.Errorf("save recovered daemon credential: %w", err)
	}
	fmt.Fprintf(c.Out, "Recovered %s from replacement %s. Restart the daemon service manually, verify %s is connected and working, then use `dieter machine revoke %s` only after that verification. The replacement is still active until revoked.\n", *oldID, replacementID, *oldID, replacementID)
	return nil
}

func validateRecoveredCredential(identity *link.Identity, oldID string, expectedGeneration uint64, credential *gatewayv1.DaemonCredential) error {
	if credential == nil || credential.GetDaemonId() != oldID || expectedGeneration < 2 || credential.GetGeneration() != expectedGeneration {
		return errors.New("daemon ID or generation does not match the revoked identity")
	}
	if credential.GetGatewayIssuer() != identity.Issuer() {
		return errors.New("gateway issuer does not match this enrollment")
	}
	if !bytes.Equal(credential.GetDaemonCaPem(), identity.DaemonCAPEM) ||
		!bytes.Equal(credential.GetGatewaySigningPublicKey(), identity.GatewaySigningPublicKey) {
		return errors.New("gateway trust anchors do not match this enrollment")
	}
	block, rest := pem.Decode(credential.GetCertificatePem())
	if block == nil || block.Type != "CERTIFICATE" || len(rest) != 0 {
		return errors.New("recovered daemon certificate is invalid")
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return fmt.Errorf("parse recovered daemon certificate: %w", err)
	}
	public, ok := certificate.PublicKey.(ed25519.PublicKey)
	if !ok || !public.Equal(identity.PublicKey) || certificate.Subject.CommonName != oldID ||
		len(certificate.URIs) != 1 || certificate.URIs[0].String() != "spiffe://board/daemon/"+oldID {
		return errors.New("recovered daemon certificate does not match the old ID and local key")
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(identity.DaemonCAPEM) {
		return errors.New("saved gateway daemon CA is invalid")
	}
	if _, err := certificate.Verify(x509.VerifyOptions{Roots: roots, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}); err != nil {
		return fmt.Errorf("recovered daemon certificate is not valid under gateway CA: %w", err)
	}
	expires, err := time.Parse(time.RFC3339Nano, credential.GetExpiresAt())
	if err != nil || !expires.Equal(certificate.NotAfter) || !expires.After(time.Now()) {
		return errors.New("recovered daemon certificate expiry is invalid")
	}
	return nil
}

func (c *CLI) daemonUnenroll(args []string) error {
	const usage = `Usage: dieter daemon unenroll

Revoke this machine at its Dieter gateway and remove the local enrollment
credential. Projects, conversations, schedules, and harness settings remain.
`
	set := flags("daemon unenroll")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 0 {
		return fmt.Errorf("daemon unenroll does not accept arguments\n\n%s", usage)
	}
	identity, err := link.LoadIdentity(c.Root)
	if errors.Is(err, os.ErrNotExist) {
		return errors.New("this daemon is not enrolled")
	}
	if err != nil {
		return err
	}
	if !identity.Enrolled() {
		return errors.New("this daemon is not enrolled")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	name, id := identity.Name, identity.ID
	if err := link.Unenroll(ctx, identity); err != nil {
		return fmt.Errorf("unenroll daemon: %w", err)
	}
	if err := identity.ClearCredential(); err != nil {
		return fmt.Errorf("remove local daemon credential after gateway unenrollment: %w", err)
	}
	fmt.Fprintf(c.Out, "Unenrolled %s (%s). Restart the daemon before enrolling it again.\n", name, id)
	return nil
}

type optional struct {
	value string
	set   bool
}

func (o *optional) String() string     { return o.value }
func (o *optional) Set(v string) error { o.value, o.set = v, true; return nil }
func (o *optional) ptr() *string {
	if !o.set {
		return nil
	}
	return &o.value
}

func splitCSV(value string) []string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	parts := strings.Split(value, ",")
	result := make([]string, 0, len(parts))
	for _, part := range parts {
		if part = strings.TrimSpace(part); part != "" {
			result = append(result, part)
		}
	}
	return result
}
