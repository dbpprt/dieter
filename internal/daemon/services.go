package daemon

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	"github.com/dbpprt/dieter/internal/engine"
	"github.com/dbpprt/dieter/internal/engine/accounts"
	"github.com/dbpprt/dieter/internal/engine/scheduler"
	"github.com/dbpprt/dieter/internal/harness"
	hostfolders "github.com/dbpprt/dieter/internal/host/folders"
	"github.com/dbpprt/dieter/internal/host/machine"
	hostmemory "github.com/dbpprt/dieter/internal/host/memory"
	"github.com/dbpprt/dieter/internal/host/remoteexec"
	"github.com/dbpprt/dieter/internal/host/terminal"
	"github.com/dbpprt/dieter/internal/platform/config"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/daemonstate"
	"github.com/dbpprt/dieter/internal/transport/controlrtc"
)

// ServiceOptions are the configuration and host-level collaborators of the
// daemon object graph. Nil collaborators are built from Env for the store
// root.
type ServiceOptions struct {
	Env           config.Daemon
	Runner        harness.Runner
	Catalog       *harness.Catalog
	RemoteDesktop *remotedesktop.Manager
	ControlRTC    *controlrtc.Manager
	DaemonState   *daemonstate.Store
	// Trust is the enrolled daemon's device roster; nil when not enrolled.
	Trust api.DeviceTrust
	// FolderPeers dials the other daemons of the account for synced folders;
	// nil when not enrolled. FolderTrusted reports roster membership.
	FolderPeers   hostfolders.Dialer
	FolderTrusted func(daemonID string) bool
	// MemoryPeers reaches the other daemons of the account for recall across
	// machines; nil when not enrolled.
	MemoryPeers hostmemory.Dialer
	// Name is this machine's enrolled name, also used in provider account
	// messages.
	Name string
	// Roster lists the account's active daemons; provider logins of other
	// daemons are ignored. Optional.
	Roster func() map[string]bool
	// AccountsBackend replaces the provider tools the accounts engine runs
	// (fixtures); nil runs Claude Code and Codex from the harness runtime.
	AccountsBackend accounts.Backend
}

// Services is the wired daemon object graph over one central store.
type Services struct {
	Store         *store.Store
	App           *engine.Service
	Schedules     *scheduler.Manager
	Terminals     *terminal.Manager
	Executions    *remoteexec.Manager
	RemoteDesktop *remotedesktop.Manager
	Folders       *hostfolders.Engine
	Memory        *hostmemory.Service
	Accounts      *accounts.Service
	API           *api.Server
	log           *slog.Logger
}

// NewServices constructs every daemon service exactly once and hands them to
// the API server. It starts no background work.
func NewServices(data *store.Store, logger *slog.Logger, options ServiceOptions) *Services {
	if logger == nil {
		logger = slog.Default()
	}
	runner := options.Runner
	if runner == nil {
		runner = harness.NewSubprocessRunner(data.Root, harnessEnvironment(options.Env))
	}
	catalog := options.Catalog
	if catalog == nil {
		catalog = harness.DefaultCatalog(data.Root, options.Env.MockHarness)
	}
	providerAccounts := newProviderAccounts(data, logger, runner, options)
	// Turns resolve provider accounts when they really run Claude Code and
	// Codex, or when a fixture supplies the provider tools; injected test
	// runners keep the adapters' own credentials.
	var turnAccounts engine.ProviderAccounts
	if _, real := runner.(*harness.SubprocessRunner); real || options.AccountsBackend != nil {
		turnAccounts = providerAccounts
	}
	application := engine.NewWithOptions(data, engine.Options{Runner: runner, Catalog: catalog, MinimumFreeBytes: options.Env.MinimumFreeBytes, Accounts: turnAccounts})
	// Agent channel hooks run this binary's `dieter channel hook`.
	application.CLIExecutable = engine.DaemonExecutable()
	remoteDesktop := options.RemoteDesktop
	if remoteDesktop == nil {
		remoteDesktop = remotedesktop.New(remoteDesktopOptions(data.Root, options.Env.RemoteDesktop, logger))
	}
	folders := hostfolders.New(hostfolders.Options{Store: data, Log: logger, Name: options.Name, Dial: options.FolderPeers, Trusted: options.FolderTrusted})
	// Turns of a project learn the synced folders linked to it.
	application.LinkedFolders = func(projectID string) []engine.LinkedFolder {
		var out []engine.LinkedFolder
		for _, folder := range folders.LinkedFolders(projectID) {
			out = append(out, engine.LinkedFolder{Name: folder.Name, Path: folder.Path, Mode: string(folder.Mode)})
		}
		return out
	}
	// Agent memory: finished turns of memory-enabled conversations are
	// indexed, and their agents recall and save through the memory hooks.
	memory := hostmemory.New(hostmemory.Options{Store: data, App: application, Log: logger, Name: options.Name, Dial: options.MemoryPeers})
	application.Memory = memory
	services := &Services{
		Memory:    memory,
		Folders:   folders,
		Store:     data,
		App:       application,
		Schedules: scheduler.New(data, application),
		Terminals: terminal.NewPersistent(data.Root, terminal.Options{
			Shell: options.Env.Shell, SystemdScope: options.Env.ServiceManager == "systemd-user",
		}),
		Executions:    remoteexec.New(),
		RemoteDesktop: remoteDesktop,
		Accounts:      providerAccounts,
		log:           logger,
	}
	services.API = api.NewWithOptions(data, logger, api.Options{
		Runner: runner, ControlRTC: options.ControlRTC, RemoteDesktop: remoteDesktop,
		App: application, Schedules: services.Schedules, Terminals: services.Terminals,
		Executions: services.Executions, Machine: machine.NewCollector(data.Root),
		Catalog: catalog, MinimumFreeBytes: options.Env.MinimumFreeBytes, DaemonState: options.DaemonState,
		Trust: options.Trust, Folders: folders, Accounts: providerAccounts, Memory: memory,
	})
	return services
}

// providerAccountEnvironment names the daemon variables the accounts engine
// hands to provider tools: the basics their CLIs need, the host logins it
// adopts (CLAUDE_CONFIG_DIR, CODEX_HOME) and API keys of environment accounts.
var providerAccountEnvironment = []string{
	"PATH", "HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "SHELL",
	"HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy", "ALL_PROXY", "all_proxy",
	"NODE_EXTRA_CA_CERTS", "NODE_USE_ENV_PROXY",
	"CLAUDE_CONFIG_DIR", "CODEX_HOME",
	"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
	"OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL",
}

// newProviderAccounts builds the provider accounts engine over the harness
// runtime that ships Claude Code and Codex.
func newProviderAccounts(data *store.Store, logger *slog.Logger, runner harness.Runner, options ServiceOptions) *accounts.Service {
	environment := map[string]string{}
	for _, key := range providerAccountEnvironment {
		if value := options.Env.Environment.Value(key); value != "" {
			environment[key] = value
		}
	}
	opts := accounts.Options{
		Store: data, HostHome: environment["HOME"], Environment: environment, Logger: logger,
		MachineName: func() string { return options.Name }, Roster: options.Roster, Backend: options.AccountsBackend,
	}
	if subprocess, ok := runner.(*harness.SubprocessRunner); ok {
		opts.RuntimeDir = subprocess.RuntimeDirectory
	}
	service, err := accounts.New(opts)
	if err != nil {
		// Only a relative HOME fails here; turns then fail with the reason.
		logger.Warn("provider accounts are unavailable", "error", err)
		opts.HostHome = ""
		service, _ = accounts.New(opts)
	}
	return service
}

// storageRecoveryInterval bounds how long work left by a failed storage
// writer waits before a sweep completes it.
const storageRecoveryInterval = 5 * time.Second

// Serve runs the loopback data plane on listener until ctx ends. It reconciles
// orphaned turns before listening, acknowledges a runtime activation through
// ready only after recovered workers prove readiness, starts the scheduler,
// and suspends active turns during graceful shutdown.
func (s *Services) Serve(ctx context.Context, listener net.Listener, activating bool, ready func() error) error {
	logger := s.log
	defer listener.Close()
	addr := listener.Addr().String()
	reconcile := func() ([]string, error) {
		recovered, recoveryErr := s.App.ReconcileOrphanedTurns()
		if recoveryErr != nil {
			logger.Warn("some orphaned agent turns could not be fully reconciled", "error", recoveryErr)
		}
		if len(recovered) > 0 {
			logger.Info("reconciled orphaned agent turns", "cards", recovered)
		}
		return recovered, recoveryErr
	}
	recovered, recoveryErr := reconcile()
	if activating && recoveryErr != nil {
		return fmt.Errorf("qualify candidate agent turn recovery: %w", recoveryErr)
	}
	if activating && len(recovered) > 0 {
		readinessCtx, readinessCancel := context.WithTimeout(ctx, 20*time.Second)
		recoveryErr = s.App.WaitForRecoveredTurns(readinessCtx, recovered)
		readinessCancel()
		if recoveryErr != nil {
			return fmt.Errorf("qualify candidate agent workers: %w", recoveryErr)
		}
	}
	if cleaned, err := s.App.CleanupInactiveProviderBridges(); err != nil {
		logger.Warn("could not clean inactive provider bridges", "error", err)
	} else if len(cleaned) > 0 {
		logger.Info("cleaned inactive provider bridges", "cards", cleaned)
	}
	if ready != nil {
		if err := ready(); err != nil {
			return fmt.Errorf("commit service runtime activation: %w", err)
		}
	}
	// Agent channels are account-wide: publish this daemon's channel records
	// and ingest the other daemons'.
	go s.App.RunChannelReplication(ctx)
	// Provider accounts: adoption of host logins, login checks, usage probes
	// and cleanup of removed accounts.
	go s.Accounts.Run(ctx)
	// During a launchd/systemd replacement the previous owner PID can remain
	// alive for a fraction of a second after the new process starts. Recheck
	// once after handoff so that transiently-valid leases cannot strand a turn.
	go func() {
		timer := time.NewTimer(time.Second)
		defer timer.Stop()
		select {
		case <-ctx.Done():
		case <-timer.C:
			_, _ = reconcile()
		}
	}()
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-ticker.C:
				if stalled := s.App.ReconcileStalledTurns(now); len(stalled) > 0 {
					logger.Warn("reconciling stalled agent workers", "cards", stalled)
				}
				// A storage failure can prevent runTurn from persisting its final
				// card status even though the worker and lease were released. Retry
				// orphan reconciliation in-process so freeing disk repairs the card
				// without requiring a daemon restart.
				_, _ = reconcile()
			}
		}
	}()
	s.API.RestorePrivacy(ctx)
	go s.Store.RecoverEvery(ctx, storageRecoveryInterval, logger)
	stopSchedules := s.Schedules.Start(ctx)
	defer stopSchedules()
	foldersDone := make(chan struct{})
	go func() {
		defer close(foldersDone)
		s.Folders.Run(ctx)
	}()
	defer func() { <-foldersDone }()
	memoryDone := make(chan struct{})
	go func() {
		defer close(memoryDone)
		s.Memory.Run(ctx)
	}()
	defer func() { <-memoryDone }()
	httpServer := &http.Server{Addr: addr, Handler: s.API.Handler(), Protocols: api.LoopbackProtocols(), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, IdleTimeout: 90 * time.Second, MaxHeaderBytes: 1 << 20}
	logger.Info("Dieter daemon is ready", "url", fmt.Sprintf("http://%s", addr), "store", s.Store.Root)
	serveErr := make(chan error, 1)
	go func() { serveErr <- httpServer.Serve(listener) }()
	select {
	case err := <-serveErr:
		return err
	case <-ctx.Done():
	}
	// Service managers allow thirty seconds for a graceful stop. Reserve most
	// of that window for durable suspension and child-manager cleanup before
	// the service manager escalates to killing remaining processes.
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer shutdownCancel()
	if err := s.App.SuspendActiveTurns(shutdownCtx); err != nil {
		logger.Warn("some active agent turns could not be suspended for restart", "error", err)
	}
	s.Accounts.Shutdown()
	s.Terminals.Shutdown(shutdownCtx)
	s.Executions.Shutdown(shutdownCtx)
	s.RemoteDesktop.Shutdown(shutdownCtx)
	if err := httpServer.Shutdown(shutdownCtx); err != nil {
		_ = httpServer.Close()
	}
	return <-serveErr
}
