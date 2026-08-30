package cli

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/dbpprt/dieter/internal/app"
	"github.com/dbpprt/dieter/internal/attachments"
	dieterdaemon "github.com/dbpprt/dieter/internal/daemon"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/scheduler"
	"github.com/dbpprt/dieter/internal/server"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

var Version = "0.4.1-dev"

type CLI struct {
	Out, Err io.Writer
	In       io.Reader
	Store    *store.Store
	Runner   harness.Runner

	DaemonMode bool
	GatewayURL string
	Machine    string
	Timeout    time.Duration
	transport  *dieterTransport
	gateway    *gatewayTransport
}

func New(data *store.Store) *CLI {
	return &CLI{Out: os.Stdout, Err: os.Stderr, In: os.Stdin, Store: data, Runner: harness.NewSubprocessRunner(data.Root)}
}
func (c *CLI) service() *app.Service { return app.New(c.Store, c.Runner) }

func Main(args []string) int {
	global := flag.NewFlagSet("dieter", flag.ContinueOnError)
	global.SetOutput(io.Discard)
	root := global.String("store", store.DefaultRoot(), "DIETER_HOME data directory")
	short := global.String("s", "", "DIETER_HOME data directory")
	harnessConfig := global.String("harness-config", "", "harness registry YAML")
	gatewayURL := global.String("gateway", "", "gateway URL for authenticated remote commands")
	machine := global.String("machine", "", "target enrolled daemon ID or exact name")
	timeout := global.Duration("timeout", 15*time.Second, "command timeout")
	help := global.Bool("help", false, "help")
	global.BoolVar(help, "h", false, "help")
	version := global.Bool("version", false, "version")
	if err := global.Parse(args); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	if *short != "" {
		*root = *short
	}
	client := New(store.New(*root))
	client.DaemonMode, client.GatewayURL, client.Machine, client.Timeout = true, *gatewayURL, *machine, *timeout
	defer client.Close()
	if *help {
		client.rootHelp()
		return 0
	}
	if *version {
		fmt.Fprintln(client.Out, Version)
		return 0
	}
	if err := configureHarnessCatalog(client.Store.Root, *harnessConfig); err != nil {
		fmt.Fprintln(client.Err, "error:", err)
		return 1
	}
	if err := client.Run(global.Args()); err != nil {
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
	if err := c.Store.Ensure(); err != nil {
		return err
	}
	if c.DaemonMode {
		if handled, err := c.runDaemonCommand(args); handled {
			return err
		}
	}
	switch args[0] {
	case "setup":
		return c.setup(args[1:])
	case "serve":
		return c.daemonStart(args[1:])
	case "daemon":
		return c.daemon(args[1:])
	case "status":
		return c.status()
	case "project", "projects":
		return c.project(args[1:])
	case "board", "boards":
		return c.board(args[1:])
	case "card", "cards":
		return c.card(args[1:])
	case "workspace", "workspaces", "git":
		return c.workspace(args[1:])
	case "schedule", "schedules":
		return c.schedule(args[1:])
	case "settings":
		return c.settings(args[1:])
	case "storage":
		fmt.Fprintln(c.Out, c.Store.Root)
		return nil
	case "version":
		fmt.Fprintln(c.Out, Version)
		return nil
	default:
		return fmt.Errorf("unknown command %q; run dieter --help", args[0])
	}
}

func (c *CLI) rootHelp() {
	fmt.Fprint(c.Out, `Dieter — control local or enrolled Dieter daemon machines

Usage:
  dieter [global options] <command> [options]

Global options:
  --store PATH             DIETER_HOME (default ~/.dieter)
  --gateway URL            Gateway origin for account and remote commands
  --machine ID|NAME        Target an enrolled daemon; omit for the local daemon
  --timeout DURATION       Unary command and connection timeout (default 15s)
  --harness-config PATH    Local daemon harness registry YAML
  --help, -h               Show this help
  --version                Print the version

Commands:
  auth         Sign in to a gateway and manage the CLI session
  machine      List, route, rename, revoke, inspect, or control machines
  status       Show target daemon health, runtime, route, and state counts
  harness      List target daemon harnesses, models, and options
  project      Create, browse, open, relocate, archive, and restore projects
  board        Manage boards, retention, workflows, and board labels
  card         Fully manage durable board conversations
  chat         Fully manage standalone durable conversations
  workspace    Inspect changes and run durable Git/SCM operations
  file         Browse and edit project/workspace files with revision checks
  terminal     Create, attach, control, and close daemon-host PTYs
  screen       Inspect policy and drive authenticated WebRTC signaling
  schedule     Create, preview, dispatch, pause, and inspect schedules
  settings     Inspect and update parallel-session admission limits
  prompt       Inspect, update, scope, and preview prompt templates
  watch        Stream daemon state or sync frames as JSON Lines
  storage      Print the target daemon's central storage path
  setup        Authorize, enroll, and install this local daemon service
  daemon       Start, enroll, inspect, or manage this local daemon service
  serve        Alias for "dieter daemon start"
  version      Print the version

Without --machine, operational commands use the running local daemon API. With
--machine, the CLI authenticates to the gateway, prefers direct TLS, and falls
back to the bounded gateway relay. It never reads a remote machine's storage.

Run "dieter help <command> [action]" or append --help at any command depth.
`)
}

func configureHarnessCatalog(root, explicit string) error {
	path := strings.TrimSpace(explicit)
	if path == "" {
		path = strings.TrimSpace(os.Getenv("DIETER_HARNESS_CONFIG"))
	}
	if path == "" {
		candidate := filepath.Join(root, "harnesses.yaml")
		if _, err := os.Stat(candidate); err == nil {
			path = candidate
		} else if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("inspect harness config %q: %w", candidate, err)
		}
	}
	return harness.ConfigureCatalog(path)
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
			if before, _, ok := strings.Cut(name, "="); ok {
				name = before
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
		if info.Size() > attachments.MaxFileBytes {
			return nil, fmt.Errorf("attachment %q must be at most 5 MB", path)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return nil, fmt.Errorf("read attachment %q: %w", path, err)
		}
		parts = append(parts, attachments.FilePart(filepath.Base(path), "", data))
	}
	return attachments.NormalizeMessageParts(parts)
}
func jsonOut(out io.Writer, value any) error {
	enc := json.NewEncoder(out)
	enc.SetIndent("", "  ")
	return enc.Encode(value)
}
func jsonLine(out io.Writer, value any) error { return json.NewEncoder(out).Encode(value) }

func (c *CLI) serve(args []string) error {
	return c.daemonStart(args)
}

func (c *CLI) daemon(args []string) error {
	if len(args) == 0 || args[0] == "--help" || args[0] == "-h" {
		fmt.Fprint(c.Out, `Usage: dieter daemon <action>

Actions:
  start        Run the local data plane and persistent gateway tunnel
  enroll       Enroll this machine with the Dieter gateway
  unenroll     Revoke this machine and remove its local gateway credential
  status       Show service, local API, enrollment, and gateway health
  logs         Show or follow the daemon service log
  permissions  Guide and verify host screen-capture permissions
`)
		return nil
	}
	switch args[0] {
	case "start":
		return c.daemonStart(args[1:])
	case "enroll":
		return c.daemonEnroll(args[1:])
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

func (c *CLI) daemonStart(args []string) error {
	const usage = `Usage: dieter daemon start [--addr ADDRESS] [--direct-addr ADDRESS --direct-host HOST] [--env-file PATH] [--service] [--verbose]

Run the machine-local Dieter data plane and, when enrolled, its persistent
outbound gateway tunnel. The local API is always loopback-only. An enrolled
daemon automatically advertises an authenticated loopback route; direct flags
add an optional LAN, Tailscale, or public route.
`
	set := flags("daemon start")
	addr := set.String("addr", "127.0.0.1:4242", "listen address")
	directAddr := set.String("direct-addr", "", "optional authenticated TLS listen address")
	directHost := set.String("direct-host", "", "host advertised for the direct TLS route")
	directNetwork := set.String("direct-network", "lan", "direct route kind: loopback, lan, tailscale, or public")
	envFile := set.String("env-file", "", "environment file (default DIETER_HOME/.env)")
	serviceMode := set.Bool("service", false, "run as a managed service with bounded file logs")
	verbose := set.Bool("verbose", false, "verbose logs")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if err := server.LoadEnvFile(c.Store.Root, *envFile); err != nil {
		return err
	}
	host, _, splitErr := net.SplitHostPort(*addr)
	if splitErr != nil {
		return fmt.Errorf("invalid listen address: %w", splitErr)
	}
	ip := net.ParseIP(host)
	if host != "localhost" && (ip == nil || !ip.IsLoopback()) {
		return errors.New("unrestricted local harnesses require a loopback listen address")
	}
	logger, logPath, closeLog, err := daemonLogger(c.Store.Root, *serviceMode, *verbose, c.Err)
	if err != nil {
		return fmt.Errorf("open daemon log: %w", err)
	}
	defer closeLog()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	identity, identityErr := dieterdaemon.LoadIdentity(c.Store.Root)
	enrolled := identityErr == nil && identity.Enrolled()
	remoteDesktopOptions := remotedesktop.Options{Logger: logger, Source: remoteDesktopSourceOptions(logger)}
	if enrolled {
		remoteDesktopOptions.Identity = remotedesktop.Identity{
			DaemonID: identity.ID, GatewayURL: identity.GatewayURL, Generation: identity.Generation,
			PrivateKey: identity.PrivateKey, GatewaySigningPublicKey: identity.GatewaySigningPublicKey,
		}
	}
	remoteDesktop := remotedesktop.New(remoteDesktopOptions)
	remoteDesktopPresence := func() *gatewayv1.RemoteDesktopPresence {
		settings, settingsErr := c.Store.Settings()
		if settingsErr != nil {
			logger.Warn("read remote desktop settings for gateway presence", "error", settingsErr)
			return remoteDesktop.Presence(false, false)
		}
		return remoteDesktop.Presence(settings.RemoteDesktopEnabled, settings.RemoteDesktopControlEnabled)
	}
	startedAt := time.Now().UTC().Format(time.RFC3339Nano)
	gatewayState := dieterdaemon.GatewayNotEnrolled
	if enrolled {
		gatewayState = dieterdaemon.GatewayConnecting
	}
	runtimeStatus := dieterdaemon.RuntimeStatus{
		PID: os.Getpid(), Version: Version, State: "starting", StartedAt: startedAt,
		ListenAddress: *addr, ServiceManaged: *serviceMode, LogPath: logPath,
		Enrolled: enrolled, GatewayState: gatewayState,
	}
	if enrolled {
		runtimeStatus.DaemonID, runtimeStatus.DaemonName = identity.ID, identity.Name
		runtimeStatus.GatewayURL = identity.GatewayURL
	}
	statusWriter, err := dieterdaemon.NewStatusWriter(c.Store.Root, runtimeStatus)
	if err != nil {
		return fmt.Errorf("initialize daemon status: %w", err)
	}
	defer func() { _ = statusWriter.Stop() }()
	go runStatusHeartbeat(ctx, statusWriter)

	if enrolled {
		var routes []*gatewayv1.DirectCandidate
		loopback, loopbackErr := newDaemonDirectRoute(identity, *addr, "loopback", "127.0.0.1:0", "127.0.0.1", "loopback", 1000)
		if loopbackErr != nil {
			logger.Warn("automatic local route is unavailable; clients will use the gateway relay", "error", loopbackErr)
		} else {
			routes = append(routes, loopback.candidate)
			serveDaemonDirectRoute(ctx, cancel, logger, loopback)
			logger.Info("automatic authenticated local route enabled", "address", loopback.listener.Addr().String())
		}
		if strings.TrimSpace(*directAddr) != "" {
			if strings.TrimSpace(*directHost) == "" {
				return errors.New("--direct-host is required with --direct-addr")
			}
			direct, directErr := newDaemonDirectRoute(identity, *addr, "direct", *directAddr, *directHost, *directNetwork, 100)
			if directErr != nil {
				return directErr
			}
			routes = append(routes, direct.candidate)
			serveDaemonDirectRoute(ctx, cancel, logger, direct)
		}
		go func() {
			client := &dieterdaemon.GatewayClient{
				Identity: identity, LocalTarget: *addr, Version: Version, Routes: routes,
				Log: logger, OnStatus: statusWriter.Gateway, RemoteDesktopPresence: remoteDesktopPresence,
			}
			if tunnelErr := client.Run(ctx); tunnelErr != nil && ctx.Err() == nil {
				logger.Error("gateway tunnel stopped", "error", tunnelErr)
				cancel()
			}
		}()
	} else if identityErr != nil && !errors.Is(identityErr, os.ErrNotExist) {
		return identityErr
	} else {
		logger.Warn("daemon is not enrolled; serving the loopback API only", "command", "dieter daemon enroll")
	}
	if err := statusWriter.Update(func(value *dieterdaemon.RuntimeStatus) { value.State = "running" }); err != nil {
		return err
	}
	err = server.ListenDaemon(ctx, *addr, c.Store, c.Runner, logger, remoteDesktop)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func remoteDesktopSourceOptions(logger *slog.Logger) remotedesktop.SourceOptions {
	return remotedesktop.SourceOptions{
		Kind:       strings.TrimSpace(os.Getenv("DIETER_REMOTE_DESKTOP_SOURCE")),
		FFmpegPath: strings.TrimSpace(os.Getenv("DIETER_REMOTE_DESKTOP_FFMPEG")),
		HelperPath: strings.TrimSpace(os.Getenv("DIETER_REMOTE_DESKTOP_HELPER")),
		Display:    strings.TrimSpace(os.Getenv("DIETER_REMOTE_DESKTOP_DISPLAY")),
		Logger:     logger,
	}
}

type daemonDirectRoute struct {
	listener  net.Listener
	server    *dieterdaemon.DirectServer
	candidate *gatewayv1.DirectCandidate
}

func newDaemonDirectRoute(identity *dieterdaemon.Identity, localTarget, id, listenAddress, advertisedHost, network string, priority int32) (*daemonDirectRoute, error) {
	listener, err := net.Listen("tcp", strings.TrimSpace(listenAddress))
	if err != nil {
		return nil, err
	}
	closeListener := true
	defer func() {
		if closeListener {
			_ = listener.Close()
		}
	}()
	_, portText, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		return nil, fmt.Errorf("resolve direct listener port: %w", err)
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port < 1 || port > 65535 {
		return nil, fmt.Errorf("resolve direct listener port: invalid port %q", portText)
	}
	direct, err := dieterdaemon.NewDirectServer(identity, localTarget)
	if err != nil {
		return nil, err
	}
	closeListener = false
	return &daemonDirectRoute{
		listener: listener,
		server:   direct,
		candidate: &gatewayv1.DirectCandidate{
			Id:                  strings.TrimSpace(id),
			Host:                strings.TrimSpace(advertisedHost),
			Port:                uint32(port),
			Network:             strings.TrimSpace(network),
			Priority:            priority,
			CertificateIdentity: identity.ID,
		},
	}, nil
}

func serveDaemonDirectRoute(ctx context.Context, cancel context.CancelFunc, logger *slog.Logger, route *daemonDirectRoute) {
	go func() {
		if err := route.server.Serve(route.listener); err != nil && ctx.Err() == nil {
			logger.Error("direct daemon listener stopped", "route", route.candidate.GetId(), "error", err)
			cancel()
		}
	}()
	go func() {
		<-ctx.Done()
		route.server.Stop()
		_ = route.listener.Close()
	}()
}

func (c *CLI) daemonEnroll(args []string) error {
	const usage = `Usage: dieter daemon enroll [--gateway URL] [--name NAME] [--no-open]

Enroll this machine with the GitHub account configured by the Dieter gateway.
`
	set := flags("daemon enroll")
	gatewayURL := set.String("gateway", "https://board.dbpprt.com", "gateway origin")
	hostname, _ := os.Hostname()
	name := set.String("name", hostname, "machine display name")
	noOpen := set.Bool("no-open", false, "do not open the verification URL")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	identity, err := dieterdaemon.LoadOrCreateEnrollmentIdentity(c.Store.Root, strings.TrimSpace(*name), strings.TrimRight(strings.TrimSpace(*gatewayURL), "/"))
	if err != nil {
		return err
	}
	if identity.Enrolled() {
		return fmt.Errorf("this daemon is already enrolled as %s", identity.ID)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Minute)
	defer cancel()
	enrollment, err := dieterdaemon.BeginEnrollment(ctx, identity)
	if err != nil {
		return err
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
		credential, completeErr := dieterdaemon.CompleteEnrollment(ctx, identity, enrollment.GetEnrollmentId(), enrollment.GetEnrollmentSecret())
		if completeErr == nil {
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
	identity, err := dieterdaemon.LoadIdentity(c.Store.Root)
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
	if err := dieterdaemon.Unenroll(ctx, identity); err != nil {
		return fmt.Errorf("unenroll daemon: %w", err)
	}
	if err := identity.ClearCredential(); err != nil {
		return fmt.Errorf("remove local daemon credential after gateway unenrollment: %w", err)
	}
	fmt.Fprintf(c.Out, "Unenrolled %s (%s). Restart the daemon before enrolling it again.\n", name, id)
	return nil
}

func (c *CLI) status() error {
	projects, _ := c.Store.ListProjects()
	cards, _ := c.Store.ListCards(store.CardFilter{})
	_, nodeErr := exec.LookPath("node")
	return jsonOut(c.Out, map[string]any{"store": c.Store.Root, "harnessConfig": harness.CatalogSource(), "projects": len(projects), "cards": len(cards), "runtime": "local-host", "sandboxed": false, "nodeReady": nodeErr == nil})
}

func (c *CLI) project(args []string) error {
	if len(args) == 0 || args[0] == "--help" {
		fmt.Fprint(c.Out, `Usage: dieter project <action>

Actions:
  create PATH      Create and register a Git working tree
  open PATH        Register an existing Git working tree
  list             List project overlays; pass --removed to show hidden ones
  show PROJECT     Show project metadata and prompt
  update PROJECT   Update Dieter's project prompt, name, or summary
  workspace PROJECT Configure workspace defaults, Git base, and validation
  remove PROJECT   Hide a project, its boards, and its chats from Dieter
  restore PROJECT  Restore a removed project
`)
		return nil
	}
	switch args[0] {
	case "create":
		return c.projectRegister(args[1:], true)
	case "open", "add":
		return c.projectRegister(args[1:], false)
	case "list", "ls":
		return c.projectList(args[1:])
	case "show":
		return c.projectShow(args[1:])
	case "update":
		return c.projectUpdate(args[1:])
	case "workspace":
		return c.projectWorkspace(args[1:])
	case "remove", "archive":
		return c.projectArchive(args[1:], true)
	case "restore", "unarchive":
		return c.projectArchive(args[1:], false)
	default:
		return fmt.Errorf("unknown project action %q", args[0])
	}
}

func (c *CLI) projectRegister(args []string, create bool) error {
	usage := "Usage: dieter project open [--name NAME] [--prompt TEXT|--prompt-file FILE] PATH\n"
	if create {
		usage = "Usage: dieter project create [--name NAME] [--prompt TEXT|--prompt-file FILE] PATH\n"
	}
	set := flags("project")
	name := set.String("name", "", "name")
	summary := set.String("summary", "", "summary")
	prompt := set.String("prompt", "", "prompt")
	promptFile := set.String("prompt-file", "", "prompt file")
	format := set.String("format", "json", "json or table")
	baseRemote := set.String("base-remote", "", "base remote")
	baseBranch := set.String("base-branch", "", "base branch")
	validationFile := set.String("validation-file", "", "validation command JSON file")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("exactly one PATH is required")
	}
	value, err := textValue(*prompt, *promptFile, c.In)
	if err != nil {
		return err
	}
	validation, err := readValidationCommands(*validationFile)
	if err != nil {
		return err
	}
	project, err := c.service().RegisterProject(context.Background(), app.ProjectInput{
		Path: set.Arg(0), Name: *name, Summary: *summary, Prompt: value, Create: create,
		BaseRemote: *baseRemote, BaseBranch: *baseBranch, ValidationCommands: validation,
	})
	if err != nil {
		return err
	}
	if *format == "table" {
		fmt.Fprintf(c.Out, "%s\t%s\t%s\n", project.ID, project.Name, project.Path)
		return nil
	}
	return jsonOut(c.Out, project)
}

func (c *CLI) projectWorkspace(args []string) error {
	const usage = "Usage: dieter project workspace [--base-remote REMOTE] [--base-branch BRANCH] [--validation-file FILE] PROJECT\n"
	set := flags("project workspace")
	remote := set.String("base-remote", "", "base remote")
	branch := set.String("base-branch", "", "base branch")
	validationFile := set.String("validation-file", "", "validation command JSON file")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("PROJECT is required")
	}
	current, err := c.Store.ResolveProject(set.Arg(0))
	if err != nil {
		return err
	}
	if *remote == "" {
		*remote = current.BaseRemote
	}
	if *branch == "" {
		*branch = current.BaseBranch
	}
	validation := current.ValidationCommands
	if *validationFile != "" {
		validation, err = readValidationCommands(*validationFile)
		if err != nil {
			return err
		}
	}
	updated, err := c.Store.UpdateProjectWorkspaceSettings(current.ID, *remote, *branch, validation)
	if err != nil {
		return err
	}
	return jsonOut(c.Out, updated)
}

func (c *CLI) projectList(args []string) error {
	const usage = "Usage: dieter project list [--removed] [--format table|json|jsonl|ids]\n"
	set := flags("project list")
	format := set.String("format", "table", "output format")
	removed := set.Bool("removed", false, "show removed projects")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	var items []model.Project
	if *removed {
		items, err = c.Store.ListArchivedProjects()
	} else {
		items, err = c.Store.ListProjects()
	}
	if err != nil {
		return err
	}
	if *format == "json" {
		return jsonOut(c.Out, items)
	}
	for _, item := range items {
		if *format == "jsonl" {
			if err := jsonLine(c.Out, item); err != nil {
				return err
			}
		} else if *format == "ids" {
			fmt.Fprintln(c.Out, item.ID)
		} else {
			fmt.Fprintf(c.Out, "%s\t%s\t%d boards\t%s\n", item.ID, item.Name, item.BoardCount, item.Path)
		}
	}
	return nil
}

func (c *CLI) projectArchive(args []string, archived bool) error {
	action := "remove"
	if !archived {
		action = "restore"
	}
	if len(args) != 1 {
		return fmt.Errorf("Usage: dieter project %s PROJECT", action)
	}
	item, err := c.Store.ArchiveProject(args[0], archived)
	if err != nil {
		return err
	}
	return jsonOut(c.Out, item)
}

func (c *CLI) projectShow(args []string) error {
	if len(args) != 1 {
		return errors.New("Usage: dieter project show PROJECT")
	}
	item, err := c.Store.ResolveProject(args[0])
	if err != nil {
		return err
	}
	return jsonOut(c.Out, item)
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
func (c *CLI) projectUpdate(args []string) error {
	const usage = "Usage: dieter project update [--path PATH] [--name NAME] [--summary TEXT] [--prompt TEXT|--prompt-file FILE] PROJECT\n"
	set := flags("project update")
	path, name, summary, prompt := &optional{}, &optional{}, &optional{}, &optional{}
	set.Var(path, "path", "existing Git working tree")
	set.Var(name, "name", "name")
	set.Var(summary, "summary", "summary")
	set.Var(prompt, "prompt", "prompt")
	file := set.String("prompt-file", "", "prompt file")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("PROJECT is required")
	}
	var promptPtr *string
	if *file != "" {
		value, readErr := textValue("", *file, c.In)
		if readErr != nil {
			return readErr
		}
		promptPtr = &value
	} else {
		promptPtr = prompt.ptr()
	}
	var pathPtr *string
	if path.set {
		root, rootErr := gitWorkingTreeRoot(path.value)
		if rootErr != nil {
			return rootErr
		}
		pathPtr = &root
	}
	item, err := c.Store.UpdateProject(set.Arg(0), name.ptr(), summary.ptr(), promptPtr, pathPtr)
	if err != nil {
		return err
	}
	return jsonOut(c.Out, item)
}

func (c *CLI) board(args []string) error {
	if len(args) == 0 || args[0] == "--help" {
		fmt.Fprint(c.Out, `Usage: dieter board <action>

Actions:
  create   Create a fixed direct or review workflow board
  list     List boards
  label    Add, list, or remove board labels
  retention Configure when Done conversations are archived
`)
		return nil
	}
	switch args[0] {
	case "create":
		return c.boardCreate(args[1:])
	case "list", "ls":
		return c.boardList(args[1:])
	case "label":
		return c.boardLabel(args[1:])
	case "retention":
		return c.boardRetention(args[1:])
	default:
		return fmt.Errorf("unknown board action %q", args[0])
	}
}
func (c *CLI) boardLabel(args []string) error {
	if len(args) == 0 || args[0] == "--help" {
		fmt.Fprint(c.Out, "Usage: dieter board label add --board BOARD --name NAME [--color '#6558df']\n       board board label list --board BOARD\n       board board label remove --board BOARD LABEL\n")
		return nil
	}
	set := flags("board label " + args[0])
	board := set.String("board", "", "board")
	name := set.String("name", "", "name")
	color := set.String("color", "#6558df", "hex color")
	help, err := parse(set, args[1:], "Usage: dieter board label add|list|remove --board BOARD [options]\n", c.Out)
	if help || err != nil {
		return err
	}
	switch args[0] {
	case "add":
		item, err := c.Store.CreateBoardLabel(*board, *name, *color)
		if err != nil {
			return err
		}
		return jsonOut(c.Out, item.Labels)
	case "list":
		item, err := c.Store.ResolveBoard("", *board)
		if err != nil {
			return err
		}
		return jsonOut(c.Out, item.Labels)
	case "remove":
		if set.NArg() != 1 {
			return errors.New("LABEL is required")
		}
		_, err := c.Store.DeleteBoardLabel(*board, set.Arg(0))
		return err
	default:
		return fmt.Errorf("unknown board label action %q", args[0])
	}
}
func (c *CLI) boardCreate(args []string) error {
	const usage = "Usage: dieter board create --project PROJECT --name NAME [--workflow direct|review] [--archive-done POLICY]\n"
	set := flags("board create")
	project := set.String("project", "", "project")
	name := set.String("name", "", "name")
	workflow := set.String("workflow", model.WorkflowReview, "workflow")
	description := set.String("description", "", "description")
	archiveDone := set.String("archive-done", model.DoneArchiveNever, "Done archive policy")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	item, err := c.Store.CreateBoard(store.CreateBoardInput{Project: *project, Name: *name, Workflow: *workflow, Description: *description, DoneArchivePolicy: *archiveDone})
	if err != nil {
		return err
	}
	return jsonOut(c.Out, item)
}

func (c *CLI) boardRetention(args []string) error {
	const usage = "Usage: dieter board retention --archive-done POLICY BOARD\n\nPOLICY is never, immediately, after_1_day, after_7_days, after_30_days, or after_90_days.\n"
	set := flags("board retention")
	archiveDone := set.String("archive-done", "", "Done archive policy")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 || strings.TrimSpace(*archiveDone) == "" {
		return errors.New("BOARD and --archive-done are required")
	}
	item, err := c.Store.UpdateBoardDoneArchivePolicy(set.Arg(0), *archiveDone)
	if err != nil {
		return err
	}
	_, _ = c.Store.ArchiveDoneCards(time.Now())
	return jsonOut(c.Out, item)
}
func (c *CLI) boardList(args []string) error {
	const usage = "Usage: dieter board list [--project PROJECT] [--format table|json|jsonl|ids]\n"
	set := flags("board list")
	project := set.String("project", "", "project")
	format := set.String("format", "table", "format")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	items, err := c.Store.ListBoards(*project)
	if err != nil {
		return err
	}
	if *format == "json" {
		return jsonOut(c.Out, items)
	}
	for _, item := range items {
		if *format == "jsonl" {
			_ = jsonLine(c.Out, item)
		} else if *format == "ids" {
			fmt.Fprintln(c.Out, item.ID)
		} else {
			fmt.Fprintf(c.Out, "%s\t%s\t%s\n", item.ID, item.Name, item.Workflow)
		}
	}
	return nil
}

func (c *CLI) card(args []string) error {
	if len(args) == 0 || args[0] == "--help" {
		fmt.Fprint(c.Out, `Usage: dieter card <action>

Actions:
  create       Create a Dieter conversation card
  list         Search compact conversation cards
  show         Show Dieter card metadata and comments
  context      Print compact in-chat Dieter context
  transcript   Read Dieter's durable conversation
  fork         Fork a completed conversation into a new standalone chat
  send         Submit a message; the running daemon owns the agent turn
  comment      Add a non-triggering Dieter annotation
  move         Move to todo, running, review, or done
  labels       Assign board labels to a card
  cancel       Cancel an active local turn
  rename       Rename the card
  archive      Archive the card
  unarchive    Restore the card
  workspace    Select project directory or new worktree before the first turn
`)
		return nil
	}
	switch args[0] {
	case "create":
		return c.cardCreate(args[1:])
	case "list", "ls":
		return c.cardList(args[1:])
	case "show":
		return c.cardShow(args[1:], false)
	case "context":
		return c.cardShow(args[1:], true)
	case "transcript":
		return c.cardTranscript(args[1:])
	case "fork":
		return c.cardFork(args[1:])
	case "send":
		return c.cardSend(args[1:])
	case "comment":
		return c.cardComment(args[1:])
	case "move":
		return c.cardMove(args[1:])
	case "labels":
		return c.cardLabels(args[1:])
	case "cancel":
		return c.cardCancel(args[1:])
	case "rename":
		return c.cardRename(args[1:])
	case "archive":
		return c.cardArchive(args[1:], false)
	case "unarchive":
		return c.cardArchive(args[1:], true)
	case "workspace":
		return c.cardWorkspace(args[1:])
	default:
		return fmt.Errorf("unknown card action %q", args[0])
	}
}

func (c *CLI) cardFork(args []string) error {
	const usage = "Usage: dieter card fork [--at MESSAGE_ID] [--title TITLE] [--format json|id] CARD\n"
	set := flags("card fork")
	messageID := set.String("at", "", "message boundary")
	title := set.String("title", "", "fork title")
	format := set.String("format", "json", "format")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("CARD is required")
	}
	if *format != "json" && *format != "id" {
		return errors.New("format must be json or id")
	}
	item, err := c.Store.ForkChat(set.Arg(0), *messageID, *title)
	if err != nil {
		return err
	}
	if *format == "id" {
		fmt.Fprintln(c.Out, item.ID)
		return nil
	}
	return jsonOut(c.Out, item)
}

func (c *CLI) cardLabels(args []string) error {
	const usage = "Usage: dieter card labels --set LABELS CARD\n\nLABELS is a comma-separated list of board label IDs or names; empty clears labels.\n"
	set := flags("card labels")
	labels := set.String("set", "", "labels")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("CARD is required")
	}
	item, err := c.Store.SetCardLabels(set.Arg(0), splitCSV(*labels))
	if err != nil {
		return err
	}
	return jsonOut(c.Out, item)
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

func (c *CLI) cardCreate(args []string) error {
	const usage = `Usage: dieter card create --project PROJECT --board BOARD --title TITLE [options]

Options:
  --lane todo|running    Todo saves a draft; Running sends immediately
  --prompt TEXT          Initial task brief
  --prompt-file FILE     Read the task brief from a file or -
  --attach FILE          Attach an image or file (repeat up to 4 times)
  --provider HARNESS     Harness provider (codex, claude-code, pi, omp)
  --model MODEL          Model for the first turn
  --effort EFFORT        Reasoning or thinking effort for the first turn
  --labels LABELS        Comma-separated board label IDs or names
  --workspace MODE       project or worktree (required)
  --branch BRANCH        Optional worktree branch
  --base-branch BRANCH   Optional worktree base-branch override
  --format json|id       Output format
`
	set := flags("card create")
	project := set.String("project", "", "project")
	board := set.String("board", "", "board")
	title := set.String("title", "", "title")
	lane := set.String("lane", model.LaneTodo, "lane")
	prompt := set.String("prompt", "", "prompt")
	file := set.String("prompt-file", "", "prompt file")
	var attachmentFiles repeatedStrings
	set.Var(&attachmentFiles, "attach", "attachment file")
	provider := set.String("provider", "", "provider")
	modelName := set.String("model", "", "model")
	effort := set.String("effort", "", "reasoning or thinking effort")
	labels := set.String("labels", "", "labels")
	format := set.String("format", "json", "format")
	workspaceMode := set.String("workspace", "", "workspace mode")
	workspaceBranch := set.String("branch", "", "workspace branch")
	workspaceBaseBranch := set.String("base-branch", "", "workspace base branch")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if strings.TrimSpace(*workspaceMode) == "" {
		return errors.New("--workspace is required; choose project or worktree")
	}
	value, err := textValue(*prompt, *file, c.In)
	if err != nil {
		return err
	}
	parts, err := attachmentParts(attachmentFiles)
	if err != nil {
		return err
	}
	item, err := c.service().CreateCard(context.Background(), app.CardInput{
		Project: *project, Board: *board, Lane: *lane, Title: *title, Prompt: value,
		Provider: *provider, Model: *modelName, Effort: *effort, LabelIDs: splitCSV(*labels), Attachments: parts,
		WorkspaceMode: *workspaceMode, WorkspaceBranch: *workspaceBranch, WorkspaceBaseBranch: *workspaceBaseBranch,
	})
	if err != nil {
		return err
	}
	if *format == "id" {
		fmt.Fprintln(c.Out, item.ID)
		return nil
	}
	return jsonOut(c.Out, item)
}

func (c *CLI) cardWorkspace(args []string) error {
	const usage = "Usage: dieter card workspace --mode project|worktree [--branch BRANCH] [--base-branch BRANCH] CARD\n"
	set := flags("card workspace")
	mode := set.String("mode", "", "workspace mode")
	branch := set.String("branch", "", "workspace branch")
	baseBranch := set.String("base-branch", "", "base branch")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("CARD is required")
	}
	value, err := c.Store.UpdateCardWorkspaceSelection(set.Arg(0), *mode, *branch, *baseBranch, false)
	if err != nil {
		return err
	}
	return jsonOut(c.Out, value)
}

func (c *CLI) cardList(args []string) error {
	const usage = "Usage: dieter card list [--project PROJECT] [--board BOARD] [--lane LANE] [--label LABEL] [--status STATUS] [--query TEXT] [--archived] [--limit N] [--format table|json|jsonl|ids]\n"
	set := flags("card list")
	project := set.String("project", "", "project")
	board := set.String("board", "", "board")
	lane := set.String("lane", "", "lane")
	status := set.String("status", "", "runtime status")
	query := set.String("query", "", "query")
	label := set.String("label", "", "label")
	archived := set.Bool("archived", false, "show archived conversations")
	limit := set.Int("limit", 0, "limit")
	format := set.String("format", "table", "format")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	items, err := c.Store.ListCards(store.CardFilter{Project: *project, Board: *board, Lane: *lane, Runtime: *status, Query: *query, Label: *label, Limit: *limit, IncludeArchived: *archived})
	if err != nil {
		return err
	}
	if *archived {
		filtered := items[:0]
		for _, item := range items {
			if item.Archived {
				filtered = append(filtered, item)
			}
		}
		items = filtered
	}
	if *format == "json" {
		return jsonOut(c.Out, items)
	}
	writer := tabwriter.NewWriter(c.Out, 0, 2, 2, ' ', 0)
	for _, item := range items {
		if *format == "jsonl" {
			_ = jsonLine(c.Out, item)
		} else if *format == "ids" {
			fmt.Fprintln(c.Out, item.ID)
		} else {
			fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\n", item.ID, item.Lane, item.Runtime, item.Provider, item.Title)
		}
	}
	return writer.Flush()
}

func (c *CLI) cardShow(args []string, compact bool) error {
	if len(args) != 1 {
		return errors.New("Usage: dieter card show CARD")
	}
	detail, err := c.Store.CardDetail(args[0])
	if err != nil {
		return err
	}
	if compact {
		return jsonOut(c.Out, map[string]any{"cardId": detail.Card.ID, "project": detail.Project.Name, "projectPrompt": detail.Project.Prompt, "board": detail.Board.Name, "workflow": detail.Board.Workflow, "lane": detail.Card.Lane, "task": detail.Card.InitialPrompt, "comments": detail.Comments})
	}
	return jsonOut(c.Out, detail)
}
func (c *CLI) cardTranscript(args []string) error {
	const usage = "Usage: dieter card transcript [--last N] CARD\n"
	set := flags("transcript")
	last := set.Int("last", 30, "entries")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("CARD is required")
	}
	snapshot, err := c.Store.Conversation(set.Arg(0))
	if err != nil {
		return err
	}
	if *last > 0 && len(snapshot.Messages) > *last {
		snapshot.Messages = snapshot.Messages[len(snapshot.Messages)-*last:]
	}
	return jsonOut(c.Out, snapshot)
}
func (c *CLI) cardSend(args []string) error {
	const usage = "Usage: dieter card send [--message TEXT|--file FILE] [--attach FILE ...] [--provider P] [--model M] [--effort E] CARD\n"
	set := flags("send")
	message := set.String("message", "", "message")
	file := set.String("file", "", "file")
	var attachmentFiles repeatedStrings
	set.Var(&attachmentFiles, "attach", "attachment file")
	provider := set.String("provider", "", "provider")
	modelName := set.String("model", "", "model")
	effort := set.String("effort", "", "effort")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("CARD is required")
	}
	value, err := textValue(*message, *file, c.In)
	if err != nil {
		return err
	}
	parts := make([]model.UIMessagePart, 0, len(attachmentFiles)+1)
	if value != "" {
		parts = append(parts, model.UIMessagePart{Type: "text", Text: value})
	}
	files, err := attachmentParts(attachmentFiles)
	if err != nil {
		return err
	}
	parts = append(parts, files...)
	if submitted, queued, submitErr := c.sendCardThroughDaemon(context.Background(), set.Arg(0), parts, *provider, *modelName, *effort); submitted {
		if submitErr != nil {
			return submitErr
		}
		if queued {
			fmt.Fprintln(c.Out, "queued")
		} else {
			fmt.Fprintln(c.Out, "sent")
		}
		return nil
	} else if submitErr != nil {
		return submitErr
	}
	if err = c.service().SendCardParts(context.Background(), set.Arg(0), parts, *provider, *modelName, *effort); err != nil {
		return err
	}
	fmt.Fprintln(c.Out, "sent")
	return nil
}
func (c *CLI) cardComment(args []string) error {
	const usage = "Usage: dieter card comment --message TEXT CARD\n\nComments are visible Dieter annotations and never wake the agent.\n"
	set := flags("comment")
	message := set.String("message", "", "message")
	file := set.String("file", "", "file")
	name := set.String("author", "Dieter agent", "display author")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("CARD is required")
	}
	value, err := textValue(*message, *file, c.In)
	if err != nil {
		return err
	}
	card, err := c.Store.ResolveCard(set.Arg(0))
	if err != nil {
		return err
	}
	item, err := c.Store.AddComment(card.ID, value, model.Author{Kind: "agent", Name: *name, ProjectID: card.ProjectID, CardID: card.ID, Provider: card.Provider, Model: card.Model})
	if err != nil {
		return err
	}
	return jsonOut(c.Out, item)
}
func (c *CLI) cardMove(args []string) error {
	const usage = "Usage: dieter card move --lane todo|running|review|done CARD\n"
	set := flags("move")
	lane := set.String("lane", "", "lane")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("CARD is required")
	}
	before, err := c.Store.ResolveCard(set.Arg(0))
	if err != nil {
		return err
	}
	item, err := c.Store.MoveCard(before.ID, *lane, nil)
	if err != nil {
		return err
	}
	if item.Lane == model.LaneRunning && item.InitialPromptSentAt == "" {
		if err := c.service().SendCard(context.Background(), item.ID, "", item.Provider, item.Model, ""); err != nil {
			_, _ = c.Store.MoveCard(item.ID, before.Lane, nil)
			return err
		}
		item, _ = c.Store.ResolveCard(item.ID)
	}
	return jsonOut(c.Out, item)
}
func (c *CLI) cardCancel(args []string) error {
	if len(args) != 1 {
		return errors.New("Usage: dieter card cancel CARD")
	}
	return c.service().CancelCard(args[0])
}
func (c *CLI) cardRename(args []string) error {
	const usage = "Usage: dieter card rename --title TITLE CARD\n"
	set := flags("rename")
	title := set.String("title", "", "title")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if set.NArg() != 1 {
		return errors.New("CARD is required")
	}
	item, err := c.Store.RenameCard(set.Arg(0), *title)
	if err != nil {
		return err
	}
	return jsonOut(c.Out, item)
}
func (c *CLI) cardArchive(args []string, restore bool) error {
	if len(args) != 1 {
		return errors.New("CARD is required")
	}
	_, err := c.Store.ArchiveCard(args[0], !restore)
	return err
}

func (c *CLI) schedule(args []string) error {
	if len(args) == 0 || args[0] == "--help" {
		fmt.Fprint(c.Out, `Usage: dieter schedule <action>

Actions:
  create           Create a project schedule
  list             List schedules
  show SCHEDULE    Show a schedule and recent runs
  update SCHEDULE  Update a schedule
  run SCHEDULE     Create this occurrence now
  pause SCHEDULE   Pause automatic occurrences
  resume SCHEDULE  Resume automatic occurrences
  runs SCHEDULE    List occurrence history
  delete SCHEDULE  Delete the definition (cards and history remain)
`)
		return nil
	}
	switch args[0] {
	case "create", "add":
		return c.scheduleEdit(args[1:], nil)
	case "update", "edit":
		if len(args) < 2 {
			return errors.New("SCHEDULE is required")
		}
		current, err := c.Store.ResolveSchedule(args[1])
		if err != nil {
			return err
		}
		return c.scheduleEdit(append(args[2:], current.ID), &current)
	case "list", "ls":
		return c.scheduleList(args[1:])
	case "show":
		if len(args) != 2 {
			return errors.New("SCHEDULE is required")
		}
		item, err := c.Store.ResolveSchedule(args[1])
		if err != nil {
			return err
		}
		runs, _ := c.Store.ListScheduleRuns(item.ID, 10)
		return jsonOut(c.Out, map[string]any{"schedule": item, "runs": runs})
	case "run":
		if len(args) != 2 {
			return errors.New("SCHEDULE is required")
		}
		run, err := scheduler.New(c.Store, c.service()).RunNow(args[1])
		if err != nil {
			return err
		}
		for run.Status == model.ScheduleRunStarting || run.Status == model.ScheduleRunRunning {
			time.Sleep(25 * time.Millisecond)
			run, err = c.Store.ResolveScheduleRun(run.ID)
			if err != nil {
				return err
			}
		}
		return jsonOut(c.Out, run)
	case "pause", "resume":
		if len(args) != 2 {
			return errors.New("SCHEDULE is required")
		}
		item, err := scheduler.New(c.Store, c.service()).SetEnabled(args[1], args[0] == "resume")
		if err != nil {
			return err
		}
		return jsonOut(c.Out, item)
	case "runs":
		if len(args) != 2 {
			return errors.New("SCHEDULE is required")
		}
		items, err := c.Store.ListScheduleRuns(args[1], 0)
		if err != nil {
			return err
		}
		return jsonOut(c.Out, items)
	case "delete", "remove", "rm":
		if len(args) != 2 {
			return errors.New("SCHEDULE is required")
		}
		return c.Store.DeleteSchedule(args[1])
	default:
		return fmt.Errorf("unknown schedule action %q", args[0])
	}
}

func (c *CLI) scheduleEdit(args []string, current *model.Schedule) error {
	const usage = `Usage: dieter schedule create --project PROJECT --board BOARD --name NAME --cron "0 9 * * 1-5" --timezone AREA/LOCATION --title TITLE --prompt TEXT [options]
       dieter schedule update [options] SCHEDULE

Options:
  --action draft|run
  --workspace project|worktree
  --labels LABELS
  --provider AGENT --model MODEL --effort EFFORT
  --enabled=true|false
  --open-card skip_if_open|always
  --busy queue|skip
`
	defaults := model.Schedule{Enabled: true, Cron: "0 9 * * 1-5", Timezone: "UTC", Action: model.ScheduleActionDraft, OpenCardPolicy: "skip_if_open", MisfirePolicy: "latest", BusyPolicy: "queue", WorkspaceMode: model.WorkspaceModeWorktree}
	if current != nil {
		defaults = *current
	}
	set := flags("schedule edit")
	project := set.String("project", defaults.ProjectID, "project")
	board := set.String("board", defaults.BoardID, "board")
	name := set.String("name", defaults.Name, "name")
	description := set.String("description", defaults.Description, "description")
	expression := set.String("cron", defaults.Cron, "five-field cron")
	timezone := set.String("timezone", defaults.Timezone, "IANA timezone")
	action := set.String("action", defaults.Action, "draft or run")
	workspaceMode := set.String("workspace", defaults.WorkspaceMode, "project or worktree")
	title := set.String("title", defaults.TitleTemplate, "card title template")
	prompt := set.String("prompt", defaults.PromptTemplate, "card prompt template")
	promptFile := set.String("prompt-file", "", "card prompt template file")
	provider := set.String("provider", defaults.Provider, "agent provider")
	modelName := set.String("model", defaults.Model, "model")
	effort := set.String("effort", defaults.Effort, "reasoning effort")
	labels := set.String("labels", strings.Join(defaults.LabelIDs, ","), "labels")
	enabled := set.Bool("enabled", defaults.Enabled, "enabled")
	openCard := set.String("open-card", defaults.OpenCardPolicy, "open-card policy")
	busy := set.String("busy", defaults.BusyPolicy, "busy policy")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	if current != nil && (set.NArg() != 1 || set.Arg(0) != current.ID) {
		return errors.New("exactly one SCHEDULE is required")
	}
	promptInline := *prompt
	if *promptFile != "" {
		explicitPrompt := false
		set.Visit(func(item *flag.Flag) { explicitPrompt = explicitPrompt || item.Name == "prompt" })
		if !explicitPrompt {
			promptInline = ""
		}
	}
	promptValue, err := textValue(promptInline, *promptFile, c.In)
	if err != nil {
		return err
	}
	input := store.ScheduleInput{Project: *project, Board: *board, Name: *name, Description: *description, Cron: *expression, Timezone: *timezone, Action: *action, TitleTemplate: *title, PromptTemplate: promptValue, Provider: *provider, Model: *modelName, Effort: *effort, LabelIDs: splitCSV(*labels), Enabled: *enabled, OpenCardPolicy: *openCard, MisfirePolicy: "latest", BusyPolicy: *busy, WorkspaceMode: *workspaceMode}
	manager := scheduler.New(c.Store, c.service())
	var item model.Schedule
	if current == nil {
		item, err = manager.Create(input)
	} else {
		item, err = manager.Update(current.ID, input)
	}
	if err != nil {
		return err
	}
	return jsonOut(c.Out, item)
}

func (c *CLI) scheduleList(args []string) error {
	const usage = "Usage: dieter schedule list [--project PROJECT] [--format table|json|jsonl]\n"
	set := flags("schedule list")
	project := set.String("project", "", "project")
	format := set.String("format", "table", "format")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	items, err := scheduler.New(c.Store, c.service()).List(*project)
	if err != nil {
		return err
	}
	if *format == "json" {
		return jsonOut(c.Out, items)
	}
	if *format == "jsonl" {
		for _, item := range items {
			if err := jsonLine(c.Out, item); err != nil {
				return err
			}
		}
		return nil
	}
	writer := tabwriter.NewWriter(c.Out, 0, 4, 2, ' ', 0)
	fmt.Fprintln(writer, "ID\tSTATUS\tACTION\tCRON\tTIMEZONE\tNAME")
	for _, item := range items {
		status := "paused"
		if item.Enabled {
			status = "active"
		}
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%s\n", item.ID, status, item.Action, item.Cron, item.Timezone, item.Name)
	}
	return writer.Flush()
}

func (c *CLI) settings(args []string) error {
	if len(args) == 0 || args[0] == "show" || args[0] == "list" {
		value, err := c.Store.Settings()
		if err != nil {
			return err
		}
		return jsonOut(c.Out, value)
	}
	if args[0] != "set" && args[0] != "update" {
		return errors.New("Usage: dieter settings show | dieter settings set [--global N] [--agents ID=N,...] [--boards ID=N,...]")
	}
	current, err := c.Store.Settings()
	if err != nil {
		return err
	}
	set := flags("settings set")
	global := set.Int("global", current.GlobalParallelLimit, "global limit")
	agents := set.String("agents", "", "agent limits ID=N,...")
	boards := set.String("boards", "", "board limits ID=N,...")
	help, err := parse(set, args[1:], "Usage: dieter settings set [--global N] [--agents ID=N,...] [--boards ID=N,...]\n", c.Out)
	if help || err != nil {
		return err
	}
	current.GlobalParallelLimit = *global
	set.Visit(func(item *flag.Flag) {
		if err != nil {
			return
		}
		switch item.Name {
		case "agents":
			current.AgentParallelLimits, err = parseLimitMap(*agents)
		case "boards":
			current.BoardParallelLimits, err = parseLimitMap(*boards)
		}
	})
	if err != nil {
		return err
	}
	updated, err := c.Store.UpdateSettings(current)
	if err != nil {
		return err
	}
	return jsonOut(c.Out, updated)
}

func parseLimitMap(value string) (map[string]int, error) {
	result := map[string]int{}
	for _, part := range splitCSV(value) {
		id, raw, ok := strings.Cut(part, "=")
		if !ok || strings.TrimSpace(id) == "" {
			return nil, fmt.Errorf("invalid limit %q; expected ID=N", part)
		}
		limit, err := strconv.Atoi(strings.TrimSpace(raw))
		if err != nil || limit < 0 {
			return nil, fmt.Errorf("invalid limit %q; N must be non-negative", part)
		}
		result[strings.TrimSpace(id)] = limit
	}
	return result, nil
}
