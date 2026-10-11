package daemon

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/host/machine"
	"github.com/dbpprt/dieter/internal/host/serviceruntime"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/platform/buildinfo"
	"github.com/dbpprt/dieter/internal/platform/config"
	"github.com/dbpprt/dieter/internal/platform/version"
	"github.com/dbpprt/dieter/internal/providerquota"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/replication/peersync"
	"github.com/dbpprt/dieter/internal/security/localauth"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/daemonstate"
	"github.com/dbpprt/dieter/internal/transport/controlrtc"
)

// Run serves one daemon process until ctx ends: storage, runtime activation,
// the local API, the enrolled gateway link, peer replication, and the
// scheduler. It returns nil after a graceful shutdown.
func Run(ctx context.Context, cfg Config) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	if cfg.Stderr == nil {
		cfg.Stderr = io.Discard
	}
	data := store.New(cfg.Home)
	if err := data.Ensure(); err != nil {
		return err
	}
	runtimeLock, err := link.AcquireRuntimeLock(data.Root)
	if err != nil {
		return err
	}
	defer runtimeLock.Close()
	var serviceRuntime *serviceruntime.Service
	if cfg.RuntimePath != "" {
		if !cfg.ServiceMode {
			return errors.New("--runtime requires --service")
		}
		executable, err := os.Executable()
		if err != nil {
			return err
		}
		if executable != serviceruntime.PlatformRuntime(cfg.RuntimePath).DaemonExecutable() {
			return errors.New("--runtime must be started directly from its fixed daemon executable")
		}
		startupCtx, startupCancel := context.WithTimeout(context.Background(), time.Minute)
		platformRuntime := serviceruntime.PlatformRuntime(cfg.RuntimePath)
		handoff := config.LoadServiceHandoff(config.Environ())
		platformRuntime.InheritedLock, platformRuntime.ActivationToken = handoff.LockFD, handoff.Activation
		var reexec bool
		serviceRuntime, reexec, err = platformRuntime.Start(startupCtx)
		startupCancel()
		if err != nil {
			return fmt.Errorf("start fixed service runtime: %w", err)
		}
		defer serviceRuntime.Close()
		if reexec {
			return serviceRuntime.Exec(os.Args)
		}
	}
	if err := config.LoadEnvFile(data.Root, cfg.EnvFile); err != nil {
		return err
	}
	env := cfg.Env
	if env == nil {
		loaded := config.LoadDaemon(config.Environ())
		env = &loaded
	}
	catalog, err := newCatalog(data.Root, cfg.HarnessConfig, *env)
	if err != nil {
		return err
	}
	logger, logPath, closeLog, err := daemonLogger(data.Root, cfg.ServiceMode, cfg.Verbose, cfg.Stderr)
	if err != nil {
		return fmt.Errorf("open daemon log: %w", err)
	}
	defer closeLog()
	// Rotate before anything listens; the raw API and its forwarders share it.
	localToken, err := localauth.Rotate(data.Root)
	if err != nil {
		return err
	}
	identity, identityErr := link.LoadIdentity(data.Root)
	enrolled := identityErr == nil && identity.Enrolled()
	if enrolled {
		discovery, done := context.WithTimeout(ctx, 10*time.Second)
		endpoint, resolveErr := link.ResolveGatewayEndpoint(discovery, identity)
		done()
		if resolveErr != nil {
			logger.Warn("gateway endpoint discovery unavailable; retaining enrolled endpoint", "error", resolveErr)
		} else if endpoint != identity.GatewayURL {
			if err := link.RelocateGateway(identity, endpoint); err != nil {
				return fmt.Errorf("persist verified gateway endpoint: %w", err)
			}
			identity, identityErr = link.LoadIdentity(data.Root)
			if identityErr != nil {
				return identityErr
			}
			logger.Info("gateway endpoint relocated with enrollment preserved", "gateway", endpoint)
		}
	}
	remoteDesktopOptions := remoteDesktopOptions(data.Root, env.RemoteDesktop, logger)
	if enrolled {
		remoteDesktopOptions.Identity = remotedesktop.Identity{
			DaemonID: identity.ID, GatewayURL: identity.Issuer(), Generation: identity.Generation,
			PrivateKey: identity.PrivateKey, GatewaySigningPublicKey: identity.GatewaySigningPublicKey,
		}
	}
	remoteDesktop := remotedesktop.New(remoteDesktopOptions)
	startedAt := time.Now().UTC().Format(time.RFC3339Nano)
	gatewayState := link.GatewayNotEnrolled
	if enrolled {
		gatewayState = link.GatewayConnecting
	}
	serviceManager := env.ServiceManager
	if cfg.ServiceMode && serviceManager == "" {
		if runtime.GOOS == "darwin" && cfg.RuntimePath != "" {
			serviceManager = "homebrew"
		} else {
			serviceManager = "managed"
		}
	}
	// Bind before publishing status or routes so "127.0.0.1:0" resolves to the
	// port clients must dial.
	listener, err := net.Listen("tcp", cfg.Addr)
	if err != nil {
		return err
	}
	defer listener.Close()
	address := listener.Addr().String()
	runtimeStatus := link.RuntimeStatus{
		PID: os.Getpid(), Version: buildinfo.ReleaseVersion, State: "starting", StartedAt: startedAt,
		ListenAddress: address, ServiceManaged: cfg.ServiceMode, ServiceManager: serviceManager, LogPath: logPath,
		Enrolled: enrolled, GatewayState: gatewayState,
	}
	if enrolled {
		runtimeStatus.DaemonID, runtimeStatus.DaemonName = identity.ID, identity.Name
		runtimeStatus.GatewayURL = identity.GatewayURL
	}
	statusWriter, err := link.NewStatusWriter(data.Root, runtimeStatus)
	if err != nil {
		return fmt.Errorf("initialize daemon status: %w", err)
	}
	defer func() { _ = statusWriter.Stop() }()
	go runStatusHeartbeat(ctx, statusWriter)

	runner := harness.NewSubprocessRunner(data.Root, harnessEnvironment(*env))
	state := daemonstate.New(data)
	var quotaSource *providerquota.Manager
	var controlRTC *controlrtc.Manager
	if enrolled {
		quotaSource = providerquota.NewWithRuntime(data.Root, logger, runner, providerquota.Accounts{
			CodexHome: env.CodexHome, ClaudeConfigDir: env.ClaudeConfigDir,
			CodexAccountHomes: env.CodexAccountHomes, ClaudeAccountHomes: env.ClaudeAccountHomes,
			Environment: env.Environment.List(),
		})
		var routes []*gatewayv1.DirectCandidate
		loopback, loopbackErr := link.NewDirectRoute(identity, address, localToken, "loopback", "127.0.0.1:0", "127.0.0.1", "loopback", 1000)
		if loopbackErr != nil {
			logger.Warn("automatic local route is unavailable; clients will use the gateway relay", "error", loopbackErr)
		} else {
			routes = append(routes, loopback.Candidate)
			controlRTC = controlrtc.New(controlrtc.Identity{DaemonID: identity.ID, GatewayURL: identity.Issuer(), Generation: identity.Generation, GatewaySigningPublicKey: identity.GatewaySigningPublicKey}, loopback.Listener.Addr().String())
			loopback.Serve(ctx, cancel, logger)
			logger.Info("automatic authenticated local route enabled", "address", loopback.Listener.Addr().String())
		}
		if strings.TrimSpace(cfg.DirectAddr) != "" {
			if strings.TrimSpace(cfg.DirectHost) == "" {
				return errors.New("--direct-host is required with --direct-addr")
			}
			direct, directErr := link.NewDirectRoute(identity, address, localToken, "direct", cfg.DirectAddr, cfg.DirectHost, cfg.DirectNetwork, 100)
			if directErr != nil {
				return directErr
			}
			routes = append(routes, direct.Candidate)
			direct.Serve(ctx, cancel, logger)
		}
		go runGatewayLink(ctx, cancel, gatewayLink{
			data: data, state: state, identity: identity, logger: logger, statusWriter: statusWriter,
			localTarget: address, localToken: localToken, routes: routes,
			remoteDesktop: remoteDesktop, quotas: quotaSource, controlRTC: controlRTC != nil,
		})
		go (&peersync.PeerSync{Identity: identity, Store: data, Log: logger}).Run(ctx)
	} else if identityErr != nil && !errors.Is(identityErr, os.ErrNotExist) {
		return identityErr
	} else {
		logger.Warn("daemon is not enrolled; serving the loopback API only", "command", "dieter daemon enroll")
	}
	if err := statusWriter.Update(func(value *link.RuntimeStatus) { value.State = "running" }); err != nil {
		return err
	}
	ready := func() error {
		if err := notifyServiceReady(serviceManager, env.NotifySocket); err != nil {
			return err
		}
		return serviceRuntime.Ready()
	}
	options := ServiceOptions{Env: *env, Runner: runner, Catalog: catalog, RemoteDesktop: remoteDesktop, ControlRTC: controlRTC, DaemonState: state}
	if quotaSource != nil {
		options.ProviderAccountKey = quotaSource.ActiveAccountKey
	}
	if controlRTC != nil {
		defer controlRTC.Close()
	}
	services := NewServices(data, logger, options)
	err = services.Serve(ctx, listener, serviceRuntime.Activating(), ready)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

// remoteDesktopOptions maps the screen-sharing configuration onto the
// remote desktop manager. Every per-machine path stays under DIETER_HOME.
func remoteDesktopOptions(root string, screen config.RemoteDesktop, logger *slog.Logger) remotedesktop.Options {
	options := remotedesktop.Options{
		Logger: logger,
		Source: remotedesktop.SourceOptions{
			Kind: screen.Source, HelperPath: screen.Helper, Display: screen.Display, Logger: logger,
			StateRoot: root, ClipboardDirectory: filepath.Join(root, "clipboard"), FrameOverlap: screen.FrameOverlap,
		},
		Tuning: remotedesktop.Tuning{
			DisableFEC: screen.DisableFEC, DisableFastBitrate: screen.DisableFastBitrate,
			DisableLongTermReferences: screen.DisableLongTermReferences, ContentAdaptation: screen.ContentAdaptation,
			VirtualDisplay: screen.VirtualDisplay, VirtualDisable: screen.VirtualDisable,
		},
	}
	if runtime.GOOS == "linux" {
		options.Source.PortalStatePath = filepath.Join(root, "screen", "linux-portal-token")
	}
	return options
}

// harnessEnvironment is the host environment of harness workers and model
// discovery.
func harnessEnvironment(env config.Daemon) harness.Environment {
	return harness.Environment{Variables: env.Environment.List(), RuntimeDir: env.HarnessRuntimeDir, PassThrough: env.HarnessEnv}
}

// newCatalog loads the harness registry: an explicit --harness-config, else
// DIETER_HARNESS_CONFIG, else DIETER_HOME/harnesses.yaml, else the embedded
// release catalog.
func newCatalog(root, explicit string, env config.Daemon) (*harness.Catalog, error) {
	path := strings.TrimSpace(explicit)
	if path == "" {
		path = env.HarnessConfig
	}
	if path == "" {
		candidate := filepath.Join(root, "harnesses.yaml")
		if _, err := os.Stat(candidate); err == nil {
			path = candidate
		} else if !errors.Is(err, os.ErrNotExist) {
			return nil, fmt.Errorf("inspect harness config %q: %w", candidate, err)
		}
	}
	return harness.NewCatalog(harness.CatalogOptions{
		Path: path, Mock: env.MockHarness, Root: root, Environment: harnessEnvironment(env),
	})
}

// gatewayLink is the enrolled daemon's persistent outbound tunnel and the
// compatibility policy it receives.
type gatewayLink struct {
	data          *store.Store
	state         *daemonstate.Store
	identity      *link.Identity
	logger        *slog.Logger
	statusWriter  *link.StatusWriter
	localTarget   string
	localToken    string
	routes        []*gatewayv1.DirectCandidate
	remoteDesktop *remotedesktop.Manager
	quotas        *providerquota.Manager
	controlRTC    bool
}

func runGatewayLink(ctx context.Context, cancel context.CancelFunc, l gatewayLink) {
	onCompatibilityPolicy := func(policy *gatewayv1.CompatibilityPolicy) error {
		if policy == nil || policy.GetRevision() == "" || policy.GetMinimumClientVersion() == "" || policy.GetMinimumDaemonVersion() == "" {
			return errors.New("gateway returned an incomplete compatibility policy")
		}
		if err := l.state.SaveGatewayCompatibilityPolicy(daemonstate.GatewayCompatibilityPolicy{
			GatewayReleaseVersion: policy.GetGatewayReleaseVersion(),
			MinimumClientVersion:  policy.GetMinimumClientVersion(),
			MinimumDaemonVersion:  policy.GetMinimumDaemonVersion(),
			Revision:              policy.GetRevision(),
		}); err != nil {
			return err
		}
		return l.statusWriter.Update(func(value *link.RuntimeStatus) {
			value.GatewayReleaseVersion = policy.GetGatewayReleaseVersion()
			value.MinimumClientVersion = policy.GetMinimumClientVersion()
			value.MinimumDaemonVersion = policy.GetMinimumDaemonVersion()
			value.CompatibilityPolicyRevision = policy.GetRevision()
		})
	}
	onUpdateRequired := func(policy *gatewayv1.CompatibilityPolicy) error {
		if policy == nil || policy.GetRevision() == "" || policy.GetMinimumDaemonVersion() == "" {
			return errors.New("gateway returned an incomplete compatibility policy")
		}
		installed := buildinfo.ReleaseVersion
		key := version.UpdateAttemptKey(l.identity.Issuer(), policy.GetRevision(), installed, policy.GetMinimumDaemonVersion())
		receipt := daemonstate.CompatibilityUpdateReceipt{
			Key: key, GatewayIssuer: l.identity.Issuer(), PolicyRevision: policy.GetRevision(),
			InstalledVersion: installed, MinimumDaemonVersion: policy.GetMinimumDaemonVersion(),
		}
		admitted, err := l.state.BeginCompatibilityUpdate(receipt)
		if err != nil {
			return fmt.Errorf("record automatic update attempt: %w", err)
		}
		if !admitted {
			return errors.New("automatic update was already attempted for this gateway policy and installed release")
		}
		_ = l.statusWriter.Update(func(value *link.RuntimeStatus) {
			value.GatewayReleaseVersion = policy.GetGatewayReleaseVersion()
			value.MinimumClientVersion = policy.GetMinimumClientVersion()
			value.MinimumDaemonVersion = policy.GetMinimumDaemonVersion()
			value.CompatibilityPolicyRevision = policy.GetRevision()
			value.AutomaticUpdateAttemptedAt = time.Now().UTC().Format(time.RFC3339Nano)
			value.AutomaticUpdateOutcome = "admitted"
		})
		updateCtx, updateCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer updateCancel()
		err = machine.ExecuteRequiredUpdateAtRoot(updateCtx, l.data.Root, policy.GetMinimumDaemonVersion())
		outcome, message := "started", ""
		if err != nil {
			outcome, message = "failed", err.Error()
		}
		if finishErr := l.state.FinishCompatibilityUpdate(key, outcome, message); finishErr != nil && err == nil {
			err = finishErr
		}
		_ = l.statusWriter.Update(func(value *link.RuntimeStatus) { value.AutomaticUpdateOutcome = outcome })
		return err
	}
	client := &link.GatewayClient{
		Identity: l.identity, LocalTarget: l.localTarget, LocalToken: l.localToken, Version: buildinfo.ReleaseVersion, Routes: l.routes,
		Log: l.logger, OnStatus: l.statusWriter.Gateway, OnAcknowledged: l.statusWriter.GatewayAcknowledged,
		OnCompatibilityPolicy: onCompatibilityPolicy, OnUpdateRequired: onUpdateRequired,
		RemoteDesktopPresence: l.remoteDesktop.Presence, ProviderQuotas: l.quotas,
		ControlWebRTC: l.controlRTC,
	}
	if tunnelErr := client.Run(ctx); tunnelErr != nil && ctx.Err() == nil {
		var updateRequired *link.UpdateRequiredError
		if errors.As(tunnelErr, &updateRequired) {
			l.logger.Warn("gateway requires a daemon update", "error", tunnelErr)
			return
		}
		l.logger.Error("gateway tunnel stopped", "error", tunnelErr)
		cancel()
	}
}
