// Command isolated-gateway runs a throwaway copy of the Dieter gateway plus
// an enrolled daemon and mock-harness data plane on loopback. It exists so
// end-to-end client testing never has to touch the production gateway: it
// prints a ready-to-use session token and blocks until interrupted.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	"github.com/dbpprt/dieter/internal/gateway"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/host/machine"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/platform/buildinfo"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/security/localauth"
	"github.com/dbpprt/dieter/internal/security/roster"
	boardstore "github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/store/mail"
	"github.com/dbpprt/dieter/internal/testkit/topology"
	"github.com/dbpprt/dieter/internal/transport/controlrtc"
	"github.com/dbpprt/dieter/tools/fixtures/fixtureturn"
)

const enrollmentRPCTimeout = 30 * time.Second

// isolatedAccount is the GitHub user that owns every fixture machine.
const isolatedAccount int64 = 1

func enrollmentRPC[T any](ctx context.Context, logger *slog.Logger, role, operation string, call func(context.Context) (T, error)) (T, error) {
	started := time.Now()
	logger.Info("isolated enrollment starting", "role", role, "operation", operation, "timeout", enrollmentRPCTimeout)
	requestContext, cancel := context.WithTimeout(ctx, enrollmentRPCTimeout)
	defer cancel()
	result, err := call(requestContext)
	elapsed := time.Since(started).Round(time.Millisecond)
	if err != nil {
		return result, fmt.Errorf("isolated %s enrollment %s failed after %s: %w", role, operation, elapsed, err)
	}
	logger.Info("isolated enrollment completed", "role", role, "operation", operation, "elapsed", elapsed)
	return result, nil
}

func main() {
	address := flag.String("addr", "127.0.0.1:14243", "loopback listen address for the gateway copy")
	home := flag.String("home", "", "state root (default: a fresh temporary directory)")
	offlineTrigger := flag.String("offline-trigger", "", "optional file whose creation disconnects the enrolled daemon while leaving the gateway online")
	daemonRestartTrigger := flag.String("daemon-restart-trigger", "", "optional file whose creation restarts the isolated daemon API and gateway tunnel")
	inboxFixture := flag.Bool("inbox-fixture", false, "seed deterministic Inbox activity and real conversations")
	mailReport := flag.String("mail-report", "", "optional Markdown file to seed as a revised report in the isolated E2E mailbox")
	e2eFixture := flag.Bool("e2e-fixture", false, "seed the small persisted workspace that every Maestro flow uses")
	usageFixture := flag.Bool("usage-fixture", false, "publish deterministic provider usage without provider credentials")
	showcaseFixture := flag.Bool("showcase-fixture", false, "seed the multi-machine workspace with live agent turns used for documentation screenshots")
	channelsFixture := flag.Bool("channels-fixture", false, "turn agent channels on and seed the project channel and its agents' conversations with a two-agent coordination")
	directRoute := flag.String("direct-route", "", `advertise a loopback direct TLS route for the primary daemon: "live" serves it, "dead" advertises a closed port`)
	flag.Parse()
	if *directRoute != "" && *directRoute != "live" && *directRoute != "dead" {
		fmt.Fprintln(os.Stderr, `error: -direct-route must be "live" or "dead"`)
		os.Exit(2)
	}
	if err := run(*address, *home, *offlineTrigger, *daemonRestartTrigger, *directRoute, *mailReport, *inboxFixture, *usageFixture, *e2eFixture, *showcaseFixture, *channelsFixture); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(address, home, offlineTrigger, daemonRestartTrigger, directRoute, mailReport string, inboxFixture, usageFixture, e2eFixture, showcaseFixture, channelsFixture bool) error {
	if home == "" {
		var err error
		home, err = os.MkdirTemp("", "dieter-isolated-*")
		if err != nil {
			return err
		}
	}
	// Machine-home terminal coverage must remain inside the disposable fixture,
	// including shell startup files and any history a tested shell may create.
	if err := os.Setenv("HOME", home); err != nil {
		return err
	}
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	authSecret := make([]byte, 32)
	if _, err := rand.Read(authSecret); err != nil {
		return err
	}
	turn, err := fixtureturn.Load()
	if err != nil {
		return err
	}
	isolated, err := topology.NewGateway(topology.GatewayOptions{
		Root: filepath.Join(home, "gateway"), Address: address, Accounts: []int64{isolatedAccount}, Login: "isolated",
		AuthSecret: authSecret, SessionTTL: 12 * time.Hour, Logger: logger,
		Configure: func(config *gateway.Config) {
			config.GitHubClientID, config.GitHubSecret = "isolated", "isolated"
			if turn != nil {
				config.RTCTURNURLs = turn.URLs
				config.RTCTURNSecret = []byte(turn.SharedSecret)
			}
		},
	})
	if err != nil {
		return err
	}
	defer isolated.Close()
	gatewayServer := isolated.Server
	enroll := func(role, root, name string) (*link.Identity, error) {
		return enrollmentRPC(ctx, logger, role, "enrollment", func(requestContext context.Context) (*link.Identity, error) {
			return isolated.Enroll(requestContext, root, name, isolatedAccount)
		})
	}

	primaryName := "Isolated E2E machine"
	if showcaseFixture {
		primaryName = showcaseOffice
	}
	identity, err := enroll("primary", filepath.Join(home, "dieter"), primaryName)
	if err != nil {
		return err
	}

	data := boardstore.New(filepath.Join(home, "dieter"))
	if err = data.Ensure(); err != nil {
		return err
	}
	subject := fmt.Sprintf("github:%d", isolatedAccount)
	account := crdt.Revision([]string{identity.GatewayURL, subject})
	if _, err = data.Replica.BindPeerAccount(account, subject, identity.ID, identity.GatewayURL); err != nil {
		return err
	}
	var project model.Project
	var board model.Board
	var showcased *showcase
	if showcaseFixture {
		if showcased, project, board, err = seedShowcaseOffice(ctx, home, data); err != nil {
			return err
		}
	} else {
		repository := filepath.Join(home, "repo")
		for _, command := range [][]string{
			{"git", "init", "-b", "main", repository},
			{"git", "-C", repository, "config", "user.name", "Dieter Isolated E2E"},
			{"git", "-C", repository, "config", "user.email", "dieter@localhost"},
		} {
			process := exec.CommandContext(ctx, command[0], command[1:]...)
			process.Env = isolatedGitEnvironment(os.Environ())
			if output, commandErr := process.CombinedOutput(); commandErr != nil {
				return fmt.Errorf("%s: %s: %w", strings.Join(command, " "), output, commandErr)
			}
		}
		if err = os.WriteFile(filepath.Join(repository, "README.md"), []byte("# Isolated E2E\n"), 0o644); err != nil {
			return err
		}
		linkedWorktree := filepath.Join(home, "linked-worktree")
		for _, command := range [][]string{
			{"git", "-C", repository, "add", "README.md"},
			// Disposable fixture commits must not invoke the operator's signing agent.
			{"git", "-C", repository, "-c", "commit.gpgsign=false", "commit", "-m", "initial"},
			{"git", "-C", repository, "worktree", "add", "-b", "linked-worktree", linkedWorktree},
		} {
			process := exec.CommandContext(ctx, command[0], command[1:]...)
			process.Env = isolatedGitEnvironment(os.Environ())
			if output, commandErr := process.CombinedOutput(); commandErr != nil {
				return fmt.Errorf("%s: %s: %w", strings.Join(command, " "), output, commandErr)
			}
		}
		project, err = data.Kanban.CreateProject(kanban.CreateProjectInput{
			Name: "Isolated E2E", Path: repository, BaseBranch: "main",
		})
		if err != nil {
			return err
		}
		board, err = data.Kanban.CreateBoard(kanban.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
		if err != nil {
			return err
		}
	}
	if inboxFixture {
		if err := seedInboxFixture(ctx, data, project, board); err != nil {
			return err
		}
	}
	if e2eFixture {
		if err := seedE2EFixture(data, project, board); err != nil {
			return err
		}
	}
	if mailReport != "" {
		if !e2eFixture {
			return fmt.Errorf("-mail-report requires -e2e-fixture")
		}
		body, err := os.ReadFile(mailReport)
		if err != nil {
			return err
		}
		if _, _, err := data.Mail.Send(mail.Draft{Sender: model.MailSender{Kind: model.MailSenderOperator, Label: "Revised report fixture"}, Subject: "upday revised transparency report", Body: string(body)}); err != nil {
			return err
		}
	}
	if channelsFixture {
		if err := seedChannelsFixture(data, project, board); err != nil {
			return err
		}
	}
	if os.Getenv("DIETER_PERFORMANCE_SWEEP") == "1" {
		if err := seedChatPerformanceFixture(data, project); err != nil {
			return err
		}
	}

	boardListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	localToken, err := localauth.Ensure(data.Root)
	if err != nil {
		return err
	}
	// Device trust and the unadvertised TLS endpoint that relay tunnels and
	// WebRTC control channels reach, exactly as `dieter serve` wires them.
	primaryTrust, err := fixtureTrust(ctx, identity, logger)
	if err != nil {
		return err
	}
	endpoint, err := fixtureEndpoint(identity, primaryTrust, boardListener.Addr().String(), localToken)
	if err != nil {
		return err
	}
	defer endpoint.Server.Stop()
	var control *controlrtc.Manager
	if os.Getenv("DIETER_TEST_CONTROL_WEBRTC") == "1" {
		control = controlrtc.New(controlrtc.Identity{DaemonID: identity.ID, GatewayURL: identity.GatewayURL, Generation: identity.Generation, GatewaySigningPublicKey: identity.GatewaySigningPublicKey}, endpoint.Listener.Addr().String())
		defer control.Close()
	}
	trusts := map[*boardstore.Store]*link.Trust{data: primaryTrust}
	var boardServersMu sync.Mutex
	var boardServers []*api.Server
	var boardRunners []*isolatedRunner
	// Every fixture shares one installed harness runtime: DIETER_HARNESS_RUNTIME_DIR
	// (the checkout's internal/harness/runtime in client tests) or a per-user
	// cache, so concurrent fixtures don't each run npm ci.
	runtimeHome, runtimeEnvironment := fixtureHarnessRuntime()
	newFixtureServer := func(fixtureData *boardstore.Store) *api.Server {
		runner := newIsolatedRunner(harness.NewSubprocessRunner(runtimeHome, runtimeEnvironment))
		// Smoke fixtures exercise client delivery and reconnect behavior with the
		// bounded mock harness. Do not let the host's production agent disk
		// reserve turn that transport assertion into a machine-capacity test.
		noDiskReserve := uint64(0)
		runner.logger = logger
		runner.showcase = showcaseFixture
		value := api.NewWithOptions(fixtureData, logger, api.Options{
			Runner:        runner,
			PrivacyDriver: &isolatedPrivacy{},
			PrivacyBootID: func(context.Context) (string, error) { return "isolated-boot", nil },
			// Keep the real release choices without triggering provider CLI/network
			// discovery or runtime installation in each disposable fixture home. The
			// mock harness answers every prompt deterministically, so end-to-end
			// turns complete without real provider credentials.
			Catalog:          harness.StaticCatalog(true),
			MinimumFreeBytes: &noDiskReserve,
			ControlRTC: func() *controlrtc.Manager {
				if fixtureData == data {
					return control
				}
				return nil
			}(),
			Trust: trusts[fixtureData],
			MachineAction: func(_ context.Context, operation machine.Operation) error {
				logger.Info("isolated machine operation accepted", "operation", operation)
				return nil
			},
			MachineCapabilities: isolatedMachineCapabilities,
		})
		boardServersMu.Lock()
		boardServers = append(boardServers, value)
		boardRunners = append(boardRunners, runner)
		boardServersMu.Unlock()
		return value
	}
	// Registered before the HTTP server defers so admissions close first. The
	// driver may remove fixture runtimes only after terminal sessions close and
	// every fixture-owned turn has stopped writing.
	defer func() {
		cleanupContext, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		boardServersMu.Lock()
		values := append([]*api.Server(nil), boardServers...)
		runners := append([]*isolatedRunner(nil), boardRunners...)
		boardServersMu.Unlock()
		for index := len(values) - 1; index >= 0; index-- {
			values[index].CloseTerminalSessionsForTesting(cleanupContext)
		}
		for index := len(runners) - 1; index >= 0; index-- {
			runners[index].Shutdown()
		}
	}()
	boardServer := newFixtureServer(data)
	boardHTTP := &http.Server{Handler: boardServer.Handler(), Protocols: api.LoopbackProtocols()}
	go func() { _ = boardHTTP.Serve(boardListener) }()
	defer boardHTTP.Close()
	secondTarget := ""
	var secondHandler *replaceableHandler
	var newSecondServer func() *api.Server
	var secondServer *api.Server
	var secondData *boardstore.Store
	var secondIdentity *link.Identity
	if daemonRestartTrigger != "" {
		secondData = boardstore.New(filepath.Join(home, "second-dieter"))
		if err = secondData.Ensure(); err != nil {
			return err
		}
		if secondIdentity, err = enroll("second", filepath.Join(home, "second-dieter"), "Projectless E2E machine"); err != nil {
			return err
		}
		secondTrust, trustErr := fixtureTrust(ctx, secondIdentity, logger)
		if trustErr != nil {
			return trustErr
		}
		trusts[secondData] = secondTrust
		secondListener, listenErr := net.Listen("tcp", "127.0.0.1:0")
		if listenErr != nil {
			return listenErr
		}
		newSecondServer = func() *api.Server { return newFixtureServer(secondData) }
		secondServer = newSecondServer()
		secondHandler = &replaceableHandler{handler: secondServer.Handler()}
		secondHTTP := &http.Server{Handler: secondHandler, Protocols: api.LoopbackProtocols()}
		go func() { _ = secondHTTP.Serve(secondListener) }()
		defer secondHTTP.Close()
		secondTarget = secondListener.Addr().String()
	}

	routes, err := fixtureDirectRoute(directRoute, identity, primaryTrust, boardListener.Addr().String(), localToken)
	if err != nil {
		return err
	}
	tunnel := &link.GatewayClient{ControlWebRTC: control != nil, Identity: identity, TunnelTarget: endpoint.Listener.Addr().String(), Version: buildinfo.ReleaseVersion, Routes: routes.candidates, Log: logger}
	if usageFixture {
		tunnel.ProviderQuotas = isolatedUsageQuotas{}
	}
	if showcaseFixture {
		tunnel.ProviderQuotas = showcaseUsageQuotas{}
	}
	defer routes.close()
	if offlineTrigger == "" {
		go func() { _ = tunnel.Run(ctx) }()
	} else {
		go func() {
			ticker := time.NewTicker(100 * time.Millisecond)
			defer ticker.Stop()
			var tunnelContext context.Context
			var disconnect context.CancelFunc
			var stopped chan struct{}
			start := func() {
				tunnelContext, disconnect = context.WithCancel(ctx)
				stopped = make(chan struct{})
				go func() {
					defer close(stopped)
					_ = tunnel.Run(tunnelContext)
				}()
			}
			stop := func() {
				if disconnect == nil {
					return
				}
				disconnect()
				<-stopped
				disconnect = nil
				stopped = nil
			}
			start()
			defer stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					_, err := os.Stat(offlineTrigger)
					offline := err == nil
					if offline && disconnect != nil {
						stop()
					} else if !offline && disconnect == nil {
						start()
					}
				}
			}
		}()
	}

	// Keep an enrolled incompatible machine in discovery. The gateway rejects
	// its obsolete contract, so it must remain offline rather than opening a
	// fake incompatible tunnel against the current data plane.
	incompatibleID := ""
	if !showcaseFixture {
		incompatibleIdentity, enrollErr := enroll("incompatible", filepath.Join(home, "incompatible-daemon"), "Incompatible API machine")
		if enrollErr != nil {
			return enrollErr
		}
		if err = isolated.Store.MarkDaemonSeen(incompatibleIdentity.ID, "incompatible-e2e", []byte("[]"), []byte("{}")); err != nil {
			return err
		}
		incompatibleID = incompatibleIdentity.ID
	}

	secondDaemonID := ""
	if daemonRestartTrigger != "" {
		if _, err = secondData.Replica.BindPeerAccount(account, subject, secondIdentity.ID, secondIdentity.GatewayURL); err != nil {
			return err
		}
		secondDaemonID = secondIdentity.ID
		secondToken, tokenErr := localauth.Read(secondData.Root)
		if tokenErr != nil {
			return tokenErr
		}
		secondEndpoint, endpointErr := fixtureEndpoint(secondIdentity, trusts[secondData], secondTarget, secondToken)
		if endpointErr != nil {
			return endpointErr
		}
		defer secondEndpoint.Server.Stop()
		secondTunnel := &link.GatewayClient{
			Identity: secondIdentity, TunnelTarget: secondEndpoint.Listener.Addr().String(), Version: buildinfo.ReleaseVersion,
			Log: logger,
		}
		acknowledged := make(chan struct{}, 1)
		secondTunnel.OnAcknowledged = func(time.Time) {
			select {
			case acknowledged <- struct{}{}:
			default:
			}
		}
		go func() {
			var tunnelCancel context.CancelFunc
			var tunnelDone chan struct{}
			startTunnel := func() {
				for len(acknowledged) > 0 {
					<-acknowledged
				}
				tunnelContext, cancel := context.WithCancel(ctx)
				tunnelCancel = cancel
				tunnelDone = make(chan struct{})
				go func() {
					defer close(tunnelDone)
					_ = secondTunnel.Run(tunnelContext)
				}()
			}
			stopTunnel := func() {
				if tunnelCancel == nil {
					return
				}
				tunnelCancel()
				<-tunnelDone
				tunnelCancel = nil
				tunnelDone = nil
			}
			startTunnel()
			defer stopTunnel()

			ticker := time.NewTicker(50 * time.Millisecond)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					if _, statErr := os.Stat(daemonRestartTrigger); statErr != nil {
						continue
					}
					stopTunnel()
					restartContext, restartCancel := context.WithTimeout(context.Background(), 2*time.Second)
					secondServer.ShutdownTerminalSessions(restartContext)
					restartCancel()
					secondServer = newSecondServer()
					secondHandler.set(secondServer.Handler())
					startTunnel()
					select {
					case <-acknowledged:
						if writeErr := os.WriteFile(daemonRestartTrigger+".ready", []byte("ready\n"), 0o600); writeErr != nil {
							logger.Error("could not acknowledge isolated daemon restart", "error", writeErr)
						}
						logger.Info("isolated daemon API and gateway tunnel restarted")
					case <-time.After(10 * time.Second):
						logger.Error("isolated daemon gateway tunnel did not reconnect after restart")
					case <-ctx.Done():
						return
					}
					<-ctx.Done()
					return
				}
			}
		}()
	}

	tokenBytes := make([]byte, 24)
	if _, err = rand.Read(tokenBytes); err != nil {
		return err
	}
	token := "isolated_" + hex.EncodeToString(tokenBytes)
	if err = isolated.AddSession(token, isolatedAccount, "isolated"); err != nil {
		return err
	}

	deadline := time.Now().Add(10 * time.Second)
	for (!gatewayServer.Hub.Online(identity.ID) ||
		(secondDaemonID != "" && !gatewayServer.Hub.Online(secondDaemonID))) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !gatewayServer.Hub.Online(identity.ID) ||
		(secondDaemonID != "" && !gatewayServer.Hub.Online(secondDaemonID)) {
		return fmt.Errorf("compatible daemon tunnels did not come online")
	}
	// The primary machine starts the account's device roster and pairs the
	// second one through the production pairing path.
	if _, _, err = primaryTrust.Initialize(ctx, false); err != nil {
		return fmt.Errorf("start the isolated device roster: %w", err)
	}
	if secondDaemonID != "" {
		if err = topology.Pair(ctx, primaryTrust, trusts[secondData]); err != nil {
			return fmt.Errorf("pair the isolated second machine: %w", err)
		}
	}
	// Clients pair with one shared code; the primary machine approves every
	// request that proves it, exactly as `dieter device approve CODE` does.
	_, pairingCode, err := roster.NewPairingSecret()
	if err != nil {
		return err
	}
	go approvePairingCode(ctx, primaryTrust, pairingCode, logger)
	if showcased != nil {
		if err = showcased.connect(ctx, showcaseEnvironment{
			logger: logger, gateway: isolated, enroll: enroll, newServer: newFixtureServer, account: account, subject: subject,
			office: identity, officeAddress: boardListener.Addr().String(), officeToken: localToken,
			primaryTrust: primaryTrust, trusts: trusts,
		}); err != nil {
			return err
		}
	}

	fmt.Printf("DIETER_ISOLATED_ADDR=%s\n", isolated.Address)
	fmt.Printf("DIETER_ISOLATED_TOKEN=%s\n", token)
	fmt.Printf("DIETER_ISOLATED_PAIRING_CODE=%s\n", pairingCode)
	fmt.Printf("DIETER_ISOLATED_DAEMON=%s\n", identity.ID)
	if incompatibleID != "" {
		fmt.Printf("DIETER_ISOLATED_INCOMPATIBLE_DAEMON=%s\n", incompatibleID)
	}
	if secondDaemonID != "" {
		fmt.Printf("DIETER_ISOLATED_SECOND_DAEMON=%s\n", secondDaemonID)
	}
	fmt.Printf("DIETER_ISOLATED_PROJECT=%s\n", project.ID)
	fmt.Printf("DIETER_ISOLATED_BOARD=%s\n", board.ID)
	fmt.Println("READY")

	<-ctx.Done()
	return nil
}

type directRoutes struct {
	candidates []*gatewayv1.DirectCandidate
	close      func()
}

// fixtureTrust opens a fixture machine's device trust and follows its roster
// until ctx ends.
func fixtureTrust(ctx context.Context, identity *link.Identity, logger *slog.Logger) (*link.Trust, error) {
	deviceTrust, err := link.OpenTrust(identity, logger)
	if err != nil {
		return nil, err
	}
	deviceTrust.PairingPoll = 200 * time.Millisecond
	go deviceTrust.Run(ctx)
	return deviceTrust, nil
}

// fixtureEndpoint serves a machine's unadvertised loopback TLS endpoint.
func fixtureEndpoint(identity *link.Identity, deviceTrust *link.Trust, localTarget, localToken string) (*link.DirectRoute, error) {
	route, err := link.NewDirectRoute(identity, deviceTrust, localTarget, localToken, "endpoint", "127.0.0.1:0", "127.0.0.1", "loopback", 0)
	if err != nil {
		return nil, err
	}
	go func() { _ = route.Server.Serve(route.Listener) }()
	return route, nil
}

// approvePairingCode keeps approving devices that post a pairing request
// proving code, until ctx ends. Each device still verifies the confirmation.
func approvePairingCode(ctx context.Context, approver *link.Trust, code string, logger *slog.Logger) {
	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		before := approver.Status().GetHeadSequence()
		if _, err := approver.Approve(ctx, code); err == nil {
			if after := approver.Status().GetHeadSequence(); after != before {
				logger.Info("isolated fixture approved a device", "head", after)
			}
		} else if kind, _ := fault.KindOf(err); kind != fault.NotFound {
			logger.Warn("isolated fixture approval failed", "error", err)
		}
	}
}

// fixtureDirectRoute mirrors the daemon's automatic loopback route, so clients
// exercise pinned direct TLS against the disposable daemon. A "dead" route
// advertises a port that refuses connections to cover relay fallback.
func fixtureDirectRoute(mode string, identity *link.Identity, deviceTrust *link.Trust, localTarget, localToken string) (directRoutes, error) {
	if mode == "" {
		return directRoutes{close: func() {}}, nil
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return directRoutes{}, err
	}
	port := uint32(listener.Addr().(*net.TCPAddr).Port)
	candidate := &gatewayv1.DirectCandidate{Id: "loopback", Host: "127.0.0.1", Port: port, Network: "loopback", Priority: 1000, CertificateIdentity: identity.ID}
	if mode == "dead" {
		if err := listener.Close(); err != nil {
			return directRoutes{}, err
		}
		return directRoutes{candidates: []*gatewayv1.DirectCandidate{candidate}, close: func() {}}, nil
	}
	server, err := link.NewDirectServer(identity, deviceTrust, localTarget, localToken)
	if err != nil {
		_ = listener.Close()
		return directRoutes{}, err
	}
	go func() { _ = server.Serve(listener) }()
	return directRoutes{candidates: []*gatewayv1.DirectCandidate{candidate}, close: server.Stop}, nil
}

type replaceableHandler struct {
	mu      sync.RWMutex
	handler http.Handler
}

func (h *replaceableHandler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	h.mu.RLock()
	handler := h.handler
	h.mu.RUnlock()
	handler.ServeHTTP(writer, request)
}

func (h *replaceableHandler) set(handler http.Handler) {
	h.mu.Lock()
	h.handler = handler
	h.mu.Unlock()
}

// Auto-title always selects Spark independently of the conversation provider.
// Intercept that metadata request here so native Quick Task tests never need
// provider credentials, and can observe the running card before its rename.
type isolatedHarness interface {
	harness.Runner
	harness.Canceller
	harness.Suspender
}

type isolatedRun struct {
	cancel context.CancelFunc
	done   chan struct{}
}

type isolatedRunner struct {
	isolatedHarness
	mu       sync.Mutex
	closed   bool
	active   map[*isolatedRun]struct{}
	logger   *slog.Logger // Optional; set before admitting any fixture turns.
	sequence uint64
	showcase bool // Plays the scripted showcase turns; set before admitting any turns.
}

func newIsolatedRunner(runner isolatedHarness) *isolatedRunner {
	return &isolatedRunner{isolatedHarness: runner, active: make(map[*isolatedRun]struct{})}
}

// Shutdown cancels and drains every fixture-owned turn, including runtime
// preparation. Durable turn contexts outlive HTTP requests, so closing the HTTP
// server alone cannot stop npm or other children before the fixture process exits.
// Do not return on a timeout while a writer remains: the smoke driver bounds its
// own stop wait and refuses runtime cleanup if this process is still running.
func (runner *isolatedRunner) Shutdown() {
	runner.mu.Lock()
	runner.closed = true
	active := make([]*isolatedRun, 0, len(runner.active))
	for run := range runner.active {
		run.cancel()
		active = append(active, run)
	}
	runner.mu.Unlock()
	for _, run := range active {
		<-run.done
	}
}

func (runner *isolatedRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) (err error) {
	runner.mu.Lock()
	if runner.closed {
		runner.mu.Unlock()
		return context.Canceled
	}
	ctx, cancel := context.WithCancel(ctx)
	run := &isolatedRun{cancel: cancel, done: make(chan struct{})}
	runner.active[run] = struct{}{}
	runner.sequence++
	sequence := runner.sequence
	runner.mu.Unlock()
	defer func() {
		cancel()
		runner.mu.Lock()
		delete(runner.active, run)
		close(run.done)
		runner.mu.Unlock()
	}()
	if runner.logger != nil {
		// Never log request/output data or error strings. Fixed labels and a
		// fixture-local sequence distinguish startup from delivery failures.
		provider := "other"
		if request.Harness == "mock" || request.Harness == "codex" {
			provider = request.Harness
		}
		logger := runner.logger.With("sequence", sequence, "harness", provider)
		started := time.Now()
		logger.Info("isolated harness", "phase", "start", "elapsed_ms", 0)
		defer func() {
			classification := "ok"
			switch {
			case errors.Is(err, context.Canceled):
				classification = "canceled"
			case errors.Is(err, context.DeadlineExceeded):
				classification = "deadline_exceeded"
			case err != nil:
				classification = "error"
			}
			logger.Info("isolated harness", "phase", "finish", "elapsed_ms", time.Since(started).Milliseconds(), "error_class", classification)
		}()
		var first sync.Once
		next := emit
		emit = func(output harness.Output) error {
			first.Do(func() {
				logger.Info("isolated harness", "phase", "first_output", "elapsed_ms", time.Since(started).Milliseconds())
			})
			return next(output)
		}
	}
	return runner.run(ctx, request, emit)
}

func (runner *isolatedRunner) run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	if runner.showcase {
		if script := showcaseScript(request); script != nil {
			return runShowcaseTurn(ctx, request, emit, script)
		}
	}
	// Activity receipt tests exercise the real daemon event pipeline without
	// waiting for an unrelated SDK runtime installation in each disposable home.
	if request.Harness == "mock" && request.Prompt == "mock-activity-reply" {
		for _, chunk := range []map[string]string{
			{"type": "start", "messageId": request.ResponseMessageID},
			{"type": "text-start", "id": "reply"},
			{"type": "text-delta", "id": "reply", "delta": "Activity reply ready to read."},
			{"type": "text-end", "id": "reply"},
			{"type": "finish"},
		} {
			if err := ctx.Err(); err != nil {
				return err
			}
			raw, err := json.Marshal(chunk)
			if err != nil {
				return err
			}
			if err := emit(harness.Output{Type: "chunk", Chunk: raw}); err != nil {
				return err
			}
		}
		return nil
	}
	// Queue editing needs a deterministic active turn. The normal mock harness
	// intentionally finishes immediately, so this opt-in marker holds only the
	// disposable fixture turn until the test cancels it.
	if strings.Contains(request.Prompt, "mock-queue-hold") {
		timer := time.NewTimer(time.Minute)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
		}
	}
	if request.ConfiguredModel == "gpt-5.3-codex-spark" && strings.HasPrefix(request.SessionID, "title_") {
		timer := time.NewTimer(5 * time.Second)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
		}
		return emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(`{"type":"text-delta","delta":"Quick Task Starts Immediately"}`)})
	}
	return runner.isolatedHarness.Run(ctx, request, emit)
}

func isolatedMachineCapabilities(context.Context) []machine.OperationCapability {
	return []machine.OperationCapability{
		{Operation: machine.OperationRestart, Supported: true, Authorized: true},
		{Operation: machine.OperationShutdown, Supported: true, Authorized: true},
		{Operation: machine.OperationUpdate, Supported: true, Authorized: true},
	}
}

// Opt-in client workload: a nonempty directory and two independently paged,
// tool-heavy histories. All writes use the disposable fixture store.
func seedChatPerformanceFixture(data *boardstore.Store, project model.Project) error {
	for i := range 40 {
		card, err := data.Kanban.CreateChat(kanban.CreateCardInput{
			Project: project.ID, Title: fmt.Sprintf("Performance chat %02d", i),
			Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject,
		})
		if err != nil {
			return err
		}
		if i >= 2 {
			continue
		}
		if _, err := data.Kanban.PinChat(card.ID, true); err != nil {
			return err
		}
		messages := make([]model.UIMessage, 300)
		for j := range messages {
			payload, _ := json.Marshal(map[string]any{"command": "fixture measurement", "index": fmt.Sprintf("%d-%d", i, j), "output": strings.Repeat("bounded tool output ", 1024)})
			messages[j] = model.UIMessage{ID: fmt.Sprintf("perf-%d-%d", i, j), Role: "assistant", Parts: []model.UIMessagePart{
				{Type: "text", Text: fmt.Sprintf("### Finding %d\n\nA measured **chat performance** fixture with `inline code` and a short explanation.", j)},
				{Type: "tool", ToolCallID: fmt.Sprint(j), ToolName: "exec", State: "output-available", Output: payload},
			}}
		}
		if os.Getenv("DIETER_PERFORMANCE_LONG_TURN") == "1" {
			// A message is a provider turn, not one visible paragraph. Real
			// agent conversations can put hundreds of text/tool parts in it.
			var parts []model.UIMessagePart
			for j := range 340 {
				parts = append(parts,
					model.UIMessagePart{Type: "text", Text: fmt.Sprintf("### Step %d\n\nChecked **refresh behavior** with `native input`. The result remains available in the transcript.", j)},
					model.UIMessagePart{Type: "dynamic-tool", ToolCallID: fmt.Sprintf("long-%d", j), ToolName: "exec", State: "output-available", Output: json.RawMessage(`{"output":"check completed"}`)})
			}
			messages[len(messages)-1].Parts = parts
		}
		if _, err := data.Conversations.InitializeFork(card.ID, messages); err != nil {
			return err
		}
	}
	return nil
}

// Fixtures never inherit operator Git hooks, signing, templates or repository selectors.
func isolatedGitEnvironment(environment []string) []string {
	result := make([]string, 0, len(environment)+4)
	for _, value := range environment {
		if !strings.HasPrefix(value, "GIT_") {
			result = append(result, value)
		}
	}
	return append(result, "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "GIT_TEMPLATE_DIR=", "GIT_TERMINAL_PROMPT=0")
}

// Presentation fixtures never blank the operator desktop.
type isolatedPrivacy struct{ enabled, setup bool }

func (f *isolatedPrivacy) Setup(ctx context.Context) (*dieterv1.MachinePrivacy, error) {
	f.setup = true
	return f.Snapshot(ctx)
}

func (f *isolatedPrivacy) Snapshot(context.Context) (*dieterv1.MachinePrivacy, error) {
	state := dieterv1.MachinePrivacy_STATE_OFF
	if f.enabled {
		state = dieterv1.MachinePrivacy_STATE_ON
	}
	return &dieterv1.MachinePrivacy{Supported: f.setup, HelperSetupRequired: !f.setup, Requested: f.enabled, State: state, DisplayCount: 1, InputDeviceCount: 2}, nil
}
func (f *isolatedPrivacy) Set(ctx context.Context, enabled bool) (*dieterv1.MachinePrivacy, error) {
	f.enabled = enabled
	return f.Snapshot(ctx)
}

// fixtureHarnessRuntime returns the runner root and environment shared by all
// fixture servers in this process.
func fixtureHarnessRuntime() (string, harness.Environment) {
	environment := harness.Environment{RuntimeDir: os.Getenv("DIETER_HARNESS_RUNTIME_DIR")}
	cache, err := os.UserCacheDir()
	if err != nil {
		cache = os.TempDir()
	}
	return filepath.Join(cache, "dieter-fixtures"), environment
}
