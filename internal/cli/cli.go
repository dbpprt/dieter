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
	"time"

	"github.com/dbpprt/dieter/internal/app"
	"github.com/dbpprt/dieter/internal/attachments"
	"github.com/dbpprt/dieter/internal/buildinfo"
	"github.com/dbpprt/dieter/internal/controlrtc"
	dieterdaemon "github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/envfile"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/linkauth"
	"github.com/dbpprt/dieter/internal/machine"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/providerquota"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/server"
	"github.com/dbpprt/dieter/internal/serviceruntime"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

var Version = buildinfo.ReleaseVersion

type CLI struct {
	Out, Err io.Writer
	In       io.Reader
	Store    *store.Store
	Runner   harness.Runner

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
	if len(args) > 0 && args[0] == "__update-preflight" {
		if err := updatePreflight(args[1:], os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			return 1
		}
		return 0
	}

	if len(args) > 0 && args[0] == "__service-stage" {
		if err := stageServiceRuntime(args[1:], os.Stderr); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			return 1
		}
		return 0
	}
	if len(args) > 0 && args[0] == "__harness-prepare" {
		if err := prepareHarnessRuntime(args[1:], os.Stderr); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			return 1
		}
		return 0
	}
	if len(args) > 0 && args[0] == "__daemon-update-worker" {
		if err := machine.RunDaemonUpdateWorker(args[1:], os.Stderr); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			return 1
		}
		return 0
	}
	if len(args) > 0 && args[0] == "__linux-update-worker" {
		if err := machine.RunLinuxDaemonUpdateWorker(args[1:], os.Stderr); err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			return 1
		}
		return 0
	}
	global := flag.NewFlagSet("dieter", flag.ContinueOnError)
	global.SetOutput(io.Discard)
	root := global.String("store", store.DefaultRoot(), "DIETER_HOME data directory")
	short := global.String("s", "", "DIETER_HOME data directory")
	harnessConfig := global.String("harness-config", "", "harness registry YAML")
	gatewayURL := global.String("gateway", "", "gateway origin; must match the local daemon enrollment")
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
	client.GatewayURL, client.Machine, client.Timeout = *gatewayURL, *machine, *timeout
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
		var remoteExit *remoteExitError
		if errors.As(err, &remoteExit) {
			return remoteExit.Code()
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
	if handled, err := c.runDaemonCommand(args); handled {
		return err
	}
	switch args[0] {
	case "setup":
		return c.setup(args[1:])
	case "doctor":
		return c.doctor(args[1:])
	case "serve":
		return c.daemonStart(args[1:])
	case "daemon":
		return c.daemon(args[1:])
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
  --gateway URL            Require this enrolled gateway origin
  --machine ID|NAME        Target an enrolled daemon; omit for the local daemon
  --timeout DURATION       Unary command and connection timeout (default 15s)
  --harness-config PATH    Local daemon harness registry YAML
  --help, -h               Show this help
  --version                Print the version

Commands:
  machine      List, route, rename, revoke, inspect, or control machines
  status       Show target daemon health, runtime, route, and state counts
  harness      List target daemon harnesses, models, and options
  quota        Show, summarize, refresh, and reset provider-account quotas
  project      Create, browse, map hostnames, relocate, archive, and restore projects
  board        Manage boards, hostnames, retention, workflows, and labels
  card         Create, edit, present files, merge, and manage board conversations
  chat         Manage standalone conversations and present files or URLs
  workspace    Inspect changes and run durable Git/SCM operations
  file         Browse and edit project/workspace files with revision checks
  terminal     Create, attach, control, and close daemon-host PTYs
  remote       Run resumable commands and native shells on a daemon host
  screen       Share screens/clipboard, tune quality, inspect latency and recovery
  schedule     Create, preview, dispatch, pause, and inspect schedules
  kv           Shared portable JSON, ordering, and live account subscriptions
  peer         Inspect and edit account peer settings (leaderless sync)
  settings     Inspect and update prompt and daemon settings
  prompt       Inspect, update, scope, and preview prompt templates
  watch        Stream daemon state or sync frames as JSON Lines
  storage      Print the target daemon's central storage path
  doctor       Check local Linux/macOS runtime and service prerequisites
  setup        Authorize, enroll, and install this local daemon service
  daemon       Start, enroll, recover, inspect, or manage this local daemon service
  serve        Alias for "dieter daemon start"
  version      Print the version

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
		return c.daemonStart(args[1:])
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

func (c *CLI) daemonStart(args []string) error {
	const usage = `Usage: dieter daemon start [--addr ADDRESS] [--direct-addr ADDRESS --direct-host HOST] [--env-file PATH] [--service [--runtime PATH]] [--verbose]

Run the machine-local Dieter data plane and, when enrolled, its persistent
outbound gateway tunnel. The local API is always loopback-only. An enrolled
daemon automatically advertises an authenticated loopback route; direct flags
add an optional LAN, Tailscale, or public route.
A package manager may supply --runtime with a fixed executable directory.
Service startup activates a staged verified release there before workers begin.
An enrolled daemon also verifies any gateway-signed endpoint relocation at startup,
preserving its enrolled identity and shared account. Discovery failure retains
its current address. Status reports the selected network endpoint.
`
	set := flags("daemon start")
	addr := set.String("addr", "127.0.0.1:4242", "listen address")
	directAddr := set.String("direct-addr", "", "optional authenticated TLS listen address")
	directHost := set.String("direct-host", "", "host advertised for the direct TLS route")
	directNetwork := set.String("direct-network", "lan", "direct route kind: loopback, lan, tailscale, or public")
	envFile := set.String("env-file", "", "environment file (default DIETER_HOME/.env)")
	serviceMode := set.Bool("service", false, "run as a managed service with bounded file logs")
	runtimePath := set.String("runtime", "", "fixed service runtime; requires --service")
	verbose := set.Bool("verbose", false, "verbose logs")
	help, err := parse(set, args, usage, c.Out)
	if help || err != nil {
		return err
	}
	var serviceRuntime *serviceruntime.Service
	if *runtimePath != "" {
		if !*serviceMode {
			return errors.New("--runtime requires --service")
		}
		executable, err := os.Executable()
		if err != nil {
			return err
		}
		if executable != filepath.Join(*runtimePath, "bin", "dieter") {
			return errors.New("--runtime must be started directly from its fixed bin/dieter executable")
		}
		startupCtx, cancel := context.WithTimeout(context.Background(), time.Minute)
		var reexec bool
		serviceRuntime, reexec, err = serviceruntime.PlatformRuntime(*runtimePath).Start(startupCtx)
		cancel()
		if err != nil {
			return fmt.Errorf("start fixed service runtime: %w", err)
		}
		defer serviceRuntime.Close()
		if reexec {
			return serviceRuntime.Exec(os.Args)
		}
	}
	// Recover a failed activation before opening the data store. Otherwise a
	// candidate that rejects its schema can fail forever without rolling back.
	if err := c.Store.Ensure(); err != nil {
		return err
	}
	runtimeLock, err := dieterdaemon.AcquireRuntimeLock(c.Store.Root)
	if err != nil {
		return err
	}
	defer runtimeLock.Close()
	if err := envfile.Load(c.Store.Root, *envFile); err != nil {
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
	if enrolled {
		discovery, done := context.WithTimeout(ctx, 10*time.Second)
		endpoint, resolveErr := dieterdaemon.ResolveGatewayEndpoint(discovery, identity)
		done()
		if resolveErr != nil {
			logger.Warn("gateway endpoint discovery unavailable; retaining enrolled endpoint", "error", resolveErr)
		} else if endpoint != identity.GatewayURL {
			if err := c.Store.RelocateDaemonGateway(identity.ID, identity.GatewayURL, identity.Issuer(), endpoint, identity.GatewaySigningPublicKey); err != nil {
				return fmt.Errorf("persist verified gateway endpoint: %w", err)
			}
			identity, identityErr = dieterdaemon.LoadIdentity(c.Store.Root)
			if identityErr != nil {
				return identityErr
			}
			logger.Info("gateway endpoint relocated with enrollment preserved", "gateway", endpoint)
		}
	}
	remoteDesktopOptions := remotedesktop.Options{Logger: logger, Source: remoteDesktopSourceOptions(logger)}
	remoteDesktopOptions.Source.ClipboardDirectory = filepath.Join(c.Store.Root, "clipboard")
	if runtime.GOOS == "linux" {
		remoteDesktopOptions.Source.PortalStatePath = filepath.Join(c.Store.Root, "screen", "linux-portal-token")
	}
	if enrolled {
		remoteDesktopOptions.Identity = remotedesktop.Identity{
			DaemonID: identity.ID, GatewayURL: identity.Issuer(), Generation: identity.Generation,
			PrivateKey: identity.PrivateKey, GatewaySigningPublicKey: identity.GatewaySigningPublicKey,
		}
	}
	remoteDesktop := remotedesktop.New(remoteDesktopOptions)
	remoteDesktopPresence := remoteDesktop.Presence
	startedAt := time.Now().UTC().Format(time.RFC3339Nano)
	gatewayState := dieterdaemon.GatewayNotEnrolled
	if enrolled {
		gatewayState = dieterdaemon.GatewayConnecting
	}
	serviceManager := strings.TrimSpace(os.Getenv("DIETER_SERVICE_MANAGER"))
	if *serviceMode && serviceManager == "" {
		if runtime.GOOS == "darwin" && *runtimePath != "" {
			serviceManager = "homebrew"
		} else {
			serviceManager = "managed"
		}
	}
	runtimeStatus := dieterdaemon.RuntimeStatus{
		PID: os.Getpid(), Version: Version, State: "starting", StartedAt: startedAt,
		ListenAddress: *addr, ServiceManaged: *serviceMode, ServiceManager: serviceManager, LogPath: logPath,
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
	var quotaSource *providerquota.Manager

	var controlRTC *controlrtc.Manager
	if enrolled {
		var quotaRuntime interface {
			RuntimeDirectory(context.Context) (string, error)
		}
		if shared, ok := c.Runner.(interface {
			RuntimeDirectory(context.Context) (string, error)
		}); ok {
			quotaRuntime = shared
		}
		quotaSource = providerquota.NewWithRuntime(c.Store.Root, logger, quotaRuntime)
		var routes []*gatewayv1.DirectCandidate
		loopback, loopbackErr := newDaemonDirectRoute(identity, *addr, "loopback", "127.0.0.1:0", "127.0.0.1", "loopback", 1000)
		if loopbackErr != nil {
			logger.Warn("automatic local route is unavailable; clients will use the gateway relay", "error", loopbackErr)
		} else {
			routes = append(routes, loopback.candidate)
			controlRTC = controlrtc.New(controlrtc.Identity{DaemonID: identity.ID, GatewayURL: identity.Issuer(), Generation: identity.Generation, GatewaySigningPublicKey: identity.GatewaySigningPublicKey}, loopback.listener.Addr().String())
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
				Identity: identity, LocalTarget: *addr, Version: Version, APIVersion: server.APIVersion, Routes: routes,
				Log: logger, OnStatus: statusWriter.Gateway, OnAcknowledged: statusWriter.GatewayAcknowledged,
				RemoteDesktopPresence: remoteDesktopPresence, ProviderQuotas: quotaSource,
				ControlWebRTC: controlRTC != nil,
			}
			if tunnelErr := client.Run(ctx); tunnelErr != nil && ctx.Err() == nil {
				logger.Error("gateway tunnel stopped", "error", tunnelErr)
				cancel()
			}
		}()
		go (&dieterdaemon.PeerSync{Identity: identity, Store: c.Store, Log: logger}).Run(ctx)
	} else if identityErr != nil && !errors.Is(identityErr, os.ErrNotExist) {
		return identityErr
	} else {
		logger.Warn("daemon is not enrolled; serving the loopback API only", "command", "dieter daemon enroll")
	}
	if err := statusWriter.Update(func(value *dieterdaemon.RuntimeStatus) { value.State = "running" }); err != nil {
		return err
	}
	ready := func() error {
		if err := notifyServiceReady(serviceManager); err != nil {
			return err
		}
		return serviceRuntime.Ready()
	}
	var providerAccountKey func(string) string
	if quotaSource != nil {
		providerAccountKey = quotaSource.ActiveAccountKey
	}
	err = server.ListenDaemonReady(ctx, *addr, c.Store, c.Runner, logger, remoteDesktop, serviceRuntime.Activating(), ready, providerAccountKey, controlRTC)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

func remoteDesktopSourceOptions(logger *slog.Logger) remotedesktop.SourceOptions {
	return remotedesktop.SourceOptions{
		Kind:       strings.TrimSpace(os.Getenv("DIETER_REMOTE_DESKTOP_SOURCE")),
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
Gateway URLs require HTTPS; HTTP is allowed only on literal loopback addresses.
`
	set := flags("daemon enroll")
	gatewayURL := set.String("gateway", "https://gateway.getdieter.com", "gateway origin")
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

func validateRecoveredCredential(identity *dieterdaemon.Identity, oldID string, expectedGeneration uint64, credential *gatewayv1.DaemonCredential) error {
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
