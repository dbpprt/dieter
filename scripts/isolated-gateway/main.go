// Command isolated-gateway runs a throwaway copy of the Dieter gateway plus
// an enrolled daemon and mock-harness data plane on loopback. It exists so
// end-to-end client testing never has to touch the production gateway: it
// prints a ready-to-use session token and blocks until interrupted.
package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/dbpprt/dieter/internal/controlrtc"
	"github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/fixtureturn"
	"github.com/dbpprt/dieter/internal/gateway"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/machine"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/peerstore"
	"github.com/dbpprt/dieter/internal/protocol"
	"github.com/dbpprt/dieter/internal/server"
	boardstore "github.com/dbpprt/dieter/internal/store"
)

const enrollmentRPCTimeout = 30 * time.Second

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
	boardStressFixture := flag.Bool("board-stress-fixture", false, "seed a 100-card board with 85 variable-height cards in one lane")
	inboxFixture := flag.Bool("inbox-fixture", false, "seed deterministic Inbox activity and real conversations")
	flag.Parse()
	if err := run(*address, *home, *offlineTrigger, *daemonRestartTrigger, *boardStressFixture, *inboxFixture); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(address, home, offlineTrigger, daemonRestartTrigger string, boardStressFixture, inboxFixture bool) error {
	// The mock harness answers every prompt deterministically, so end-to-end
	// turns complete without real provider credentials.
	if err := os.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1"); err != nil {
		return err
	}
	// Smoke fixtures exercise client delivery and reconnect behavior with the
	// bounded mock harness. Do not let the host's production agent
	// disk reserve turn that transport assertion into a machine-capacity test.
	if err := os.Setenv("DIETER_MIN_FREE_BYTES", "0"); err != nil {
		return err
	}
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

	gatewayListener, err := net.Listen("tcp", address)
	if err != nil {
		return err
	}
	publicURL, err := url.Parse("http://" + gatewayListener.Addr().String())
	if err != nil {
		return err
	}
	authSecret := make([]byte, 32)
	if _, err = rand.Read(authSecret); err != nil {
		return err
	}
	config := gateway.Config{
		Root: filepath.Join(home, "gateway"), Address: gatewayListener.Addr().String(), PublicURL: publicURL,
		GitHubClientID: "isolated", GitHubSecret: "isolated", AllowedUserIDs: map[int64]struct{}{1: {}}, AuthSecret: authSecret, SessionTTL: 12 * time.Hour, RTCTTL: 5 * time.Minute,
		NativeRedirects: map[string]struct{}{}, GitHubBaseURL: "https://github.invalid", GitHubAPIURL: "https://api.github.invalid",
		DevInsecure: true,
	}
	turn, err := fixtureturn.Load()
	if err != nil {
		return err
	}
	if turn != nil {
		config.RTCTURNURLs = turn.URLs
		config.RTCTURNSecret = []byte(turn.SharedSecret)
	}
	gatewayStore, err := gateway.OpenStore(config.Root)
	if err != nil {
		return err
	}
	defer gatewayStore.Close()
	gatewayServer, err := gateway.NewServer(config, gatewayStore, logger)
	if err != nil {
		return err
	}
	go func() { _ = gatewayServer.Serve(gatewayListener) }()
	defer gatewayListener.Close()

	identity, err := daemon.LoadOrCreateEnrollmentIdentity(filepath.Join(home, "dieter"), "Isolated E2E machine", publicURL.String())
	if err != nil {
		return err
	}
	enrollment, err := enrollmentRPC(ctx, logger, "primary", "begin", func(requestContext context.Context) (*gatewayv1.DaemonEnrollment, error) {
		return daemon.BeginEnrollment(requestContext, identity)
	})
	if err != nil {
		return err
	}
	if err = gatewayStore.ApproveEnrollment(enrollment.GetEnrollmentId(), enrollment.GetUserCode(), int64(1), "isolated"); err != nil {
		return err
	}
	credential, err := enrollmentRPC(ctx, logger, "primary", "complete", func(requestContext context.Context) (*gatewayv1.DaemonCredential, error) {
		return daemon.CompleteEnrollment(requestContext, identity, enrollment.GetEnrollmentId(), enrollment.GetEnrollmentSecret())
	})
	if err != nil {
		return err
	}
	if err = identity.SaveCredential(credential.GetDaemonId(), credential.GetDaemonName(), credential.GetCertificatePem(), credential.GetDaemonCaPem(), credential.GetGatewaySigningPublicKey(), credential.GetExpiresAt(), credential.GetGeneration()); err != nil {
		return err
	}

	data := boardstore.New(filepath.Join(home, "dieter"))
	if err = data.Ensure(); err != nil {
		return err
	}
	subject := fmt.Sprintf("github:%d", int64(1))
	account := peerstore.Revision([]string{identity.GatewayURL, subject})
	if _, err = data.BindPeerAccount(account, subject, identity.ID, identity.GatewayURL); err != nil {
		return err
	}
	repository := filepath.Join(home, "repo")
	for _, command := range [][]string{
		{"git", "init", "-b", "main", repository},
		{"git", "-C", repository, "config", "user.name", "Dieter Isolated E2E"},
		{"git", "-C", repository, "config", "user.email", "dieter@localhost"},
	} {
		process := exec.CommandContext(ctx, command[0], command[1:]...)
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
		if output, commandErr := process.CombinedOutput(); commandErr != nil {
			return fmt.Errorf("%s: %s: %w", strings.Join(command, " "), output, commandErr)
		}
	}
	project, err := data.CreateProject(boardstore.CreateProjectInput{
		Name: "Isolated E2E", Path: repository, BaseBranch: "main",
	})
	if err != nil {
		return err
	}
	board, err := data.CreateBoard(boardstore.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		return err
	}
	if boardStressFixture {
		board, err = seedBoardStressFixture(data, project, board)
		if err != nil {
			return err
		}
	}
	if inboxFixture {
		if err := seedInboxFixture(ctx, data, project, board); err != nil {
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
	var control *controlrtc.Manager
	if os.Getenv("DIETER_TEST_CONTROL_WEBRTC") == "1" {
		tlsListener, listenErr := net.Listen("tcp", "127.0.0.1:0")
		if listenErr != nil {
			return listenErr
		}
		direct, directErr := daemon.NewDirectServer(identity, boardListener.Addr().String())
		if directErr != nil {
			tlsListener.Close()
			return directErr
		}
		go func() { _ = direct.Serve(tlsListener) }()
		defer direct.Stop()
		control = controlrtc.New(controlrtc.Identity{DaemonID: identity.ID, GatewayURL: identity.GatewayURL, Generation: identity.Generation, GatewaySigningPublicKey: identity.GatewaySigningPublicKey}, tlsListener.Addr().String())
		defer control.Close()
	}
	var boardServersMu sync.Mutex
	var boardServers []*server.Server
	var boardRunners []*isolatedRunner
	newFixtureServer := func(fixtureData *boardstore.Store) *server.Server {
		runner := newIsolatedRunner(harness.NewSubprocessRunner(fixtureData.Root))
		runner.logger = logger
		value := server.NewWithOptions(fixtureData, logger, server.Options{
			Runner: runner,
			ControlRTC: func() *controlrtc.Manager {
				if fixtureData == data {
					return control
				}
				return nil
			}(),
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
		values := append([]*server.Server(nil), boardServers...)
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
	boardHTTP := &http.Server{Handler: boardServer.Handler()}
	go func() { _ = boardHTTP.Serve(boardListener) }()
	defer boardHTTP.Close()
	secondTarget := ""
	var secondHandler *replaceableHandler
	var newSecondServer func() *server.Server
	var secondServer *server.Server
	var secondData *boardstore.Store
	if daemonRestartTrigger != "" {
		secondData = boardstore.New(filepath.Join(home, "second-dieter"))
		if err = secondData.Ensure(); err != nil {
			return err
		}
		secondListener, listenErr := net.Listen("tcp", "127.0.0.1:0")
		if listenErr != nil {
			return listenErr
		}
		newSecondServer = func() *server.Server { return newFixtureServer(secondData) }
		secondServer = newSecondServer()
		secondHandler = &replaceableHandler{handler: secondServer.Handler()}
		secondHTTP := &http.Server{Handler: secondHandler}
		go func() { _ = secondHTTP.Serve(secondListener) }()
		defer secondHTTP.Close()
		secondTarget = secondListener.Addr().String()
	}

	tunnel := &daemon.GatewayClient{ControlWebRTC: control != nil, Identity: identity, LocalTarget: boardListener.Addr().String(), Version: "isolated-e2e", APIVersion: server.APIVersion, Log: logger}
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
	incompatibleIdentity, err := daemon.LoadOrCreateEnrollmentIdentity(filepath.Join(home, "incompatible-daemon"), "Incompatible API machine", publicURL.String())
	if err != nil {
		return err
	}
	incompatibleEnrollment, err := enrollmentRPC(ctx, logger, "incompatible", "begin", func(requestContext context.Context) (*gatewayv1.DaemonEnrollment, error) {
		return daemon.BeginEnrollment(requestContext, incompatibleIdentity)
	})
	if err != nil {
		return err
	}
	if err = gatewayStore.ApproveEnrollment(incompatibleEnrollment.GetEnrollmentId(), incompatibleEnrollment.GetUserCode(), int64(1), "isolated"); err != nil {
		return err
	}
	incompatibleCredential, err := enrollmentRPC(ctx, logger, "incompatible", "complete", func(requestContext context.Context) (*gatewayv1.DaemonCredential, error) {
		return daemon.CompleteEnrollment(requestContext, incompatibleIdentity, incompatibleEnrollment.GetEnrollmentId(), incompatibleEnrollment.GetEnrollmentSecret())
	})
	if err != nil {
		return err
	}
	if err = incompatibleIdentity.SaveCredential(incompatibleCredential.GetDaemonId(), incompatibleCredential.GetDaemonName(), incompatibleCredential.GetCertificatePem(), incompatibleCredential.GetDaemonCaPem(), incompatibleCredential.GetGatewaySigningPublicKey(), incompatibleCredential.GetExpiresAt(), incompatibleCredential.GetGeneration()); err != nil {
		return err
	}
	if err = gatewayStore.MarkDaemonSeen(incompatibleIdentity.ID, "incompatible-e2e", fmt.Sprint(protocol.Number+1), []byte("[]"), []byte("{}")); err != nil {
		return err
	}

	secondDaemonID := ""
	if daemonRestartTrigger != "" {
		secondIdentity, identityErr := daemon.LoadOrCreateEnrollmentIdentity(
			filepath.Join(home, "second-dieter"), "Projectless E2E machine", publicURL.String())
		if identityErr != nil {
			return identityErr
		}
		secondEnrollment, enrollmentErr := enrollmentRPC(ctx, logger, "second", "begin", func(requestContext context.Context) (*gatewayv1.DaemonEnrollment, error) {
			return daemon.BeginEnrollment(requestContext, secondIdentity)
		})
		if enrollmentErr != nil {
			return enrollmentErr
		}
		if err = gatewayStore.ApproveEnrollment(
			secondEnrollment.GetEnrollmentId(), secondEnrollment.GetUserCode(), int64(1), "isolated",
		); err != nil {
			return err
		}
		secondCredential, credentialErr := enrollmentRPC(ctx, logger, "second", "complete", func(requestContext context.Context) (*gatewayv1.DaemonCredential, error) {
			return daemon.CompleteEnrollment(requestContext, secondIdentity, secondEnrollment.GetEnrollmentId(), secondEnrollment.GetEnrollmentSecret())
		})
		if credentialErr != nil {
			return credentialErr
		}
		if err = secondIdentity.SaveCredential(
			secondCredential.GetDaemonId(), secondCredential.GetDaemonName(), secondCredential.GetCertificatePem(),
			secondCredential.GetDaemonCaPem(), secondCredential.GetGatewaySigningPublicKey(),
			secondCredential.GetExpiresAt(), secondCredential.GetGeneration(),
		); err != nil {
			return err
		}
		if _, err = secondData.BindPeerAccount(account, subject, secondIdentity.ID, secondIdentity.GatewayURL); err != nil {
			return err
		}
		secondDaemonID = secondIdentity.ID
		secondTunnel := &daemon.GatewayClient{
			Identity: secondIdentity, LocalTarget: secondTarget, Version: "isolated-e2e-second",
			APIVersion: server.APIVersion, Log: logger,
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
	mac := hmac.New(sha256.New, config.AuthSecret)
	if _, err = mac.Write([]byte(token)); err != nil {
		return err
	}
	digest := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	now := time.Now().UTC()
	if err = gatewayStore.UpdateAuthState(func(state *gateway.AuthState) error {
		state.Sessions = append(state.Sessions, gateway.Session{
			TokenHash: digest, GitHubID: int64(1), Login: "isolated",
			CreatedAt: now, ExpiresAt: now.Add(config.SessionTTL),
		})
		return nil
	}); err != nil {
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

	fmt.Printf("DIETER_ISOLATED_ADDR=%s\n", gatewayListener.Addr().String())
	fmt.Printf("DIETER_ISOLATED_TOKEN=%s\n", token)
	fmt.Printf("DIETER_ISOLATED_DAEMON=%s\n", identity.ID)
	fmt.Printf("DIETER_ISOLATED_INCOMPATIBLE_DAEMON=%s\n", incompatibleIdentity.ID)
	if secondDaemonID != "" {
		fmt.Printf("DIETER_ISOLATED_SECOND_DAEMON=%s\n", secondDaemonID)
	}
	fmt.Printf("DIETER_ISOLATED_PROJECT=%s\n", project.ID)
	fmt.Printf("DIETER_ISOLATED_BOARD=%s\n", board.ID)
	fmt.Println("READY")

	<-ctx.Done()
	return nil
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
		card, err := data.CreateChat(boardstore.CreateCardInput{
			Project: project.ID, Title: fmt.Sprintf("Performance chat %02d", i),
			Provider: "mock", Model: "mock", WorkspaceMode: model.WorkspaceModeProject,
		})
		if err != nil {
			return err
		}
		if i >= 2 {
			continue
		}
		if _, err := data.PinChat(card.ID, true); err != nil {
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
		if _, err := data.InitializeForkConversation(card.ID, messages); err != nil {
			return err
		}
	}
	return nil
}

func seedBoardStressFixture(data *boardstore.Store, project model.Project, board model.Board) (model.Board, error) {
	for _, fixtureLabel := range []struct {
		name  string
		color string
	}{
		{name: "Mac", color: "#6558df"},
		{name: "Performance", color: "#3b82f6"},
		{name: "Gateway", color: "#16a34a"},
	} {
		var err error
		board, err = data.CreateBoardLabel(board.ID, fixtureLabel.name, fixtureLabel.color)
		if err != nil {
			return model.Board{}, fmt.Errorf("create board stress label %q: %w", fixtureLabel.name, err)
		}
	}

	laneCounts := []struct {
		lane  string
		count int
	}{
		{lane: model.LaneTodo, count: 85},
		{lane: model.LaneRunning, count: 5},
		{lane: model.LaneReview, count: 5},
		{lane: model.LaneDone, count: 5},
	}
	cardIndex := 0
	for _, laneFixture := range laneCounts {
		for laneIndex := 0; laneIndex < laneFixture.count; laneIndex++ {
			labelIDs := []string(nil)
			if cardIndex%3 == 0 {
				labelIDs = []string{board.Labels[cardIndex%len(board.Labels)].ID}
			}
			title := fmt.Sprintf("Board stress card %02d", cardIndex+1)
			if cardIndex%3 == 0 {
				title += " with a variable-height title that wraps across multiple lines"
			}
			workspaceMode := model.WorkspaceModeProject
			if cardIndex%5 == 0 {
				workspaceMode = model.WorkspaceModeWorktree
			}
			card, err := data.CreateCard(boardstore.CreateCardInput{
				Project: project.ID, Board: board.ID, Lane: laneFixture.lane,
				Title: title, Prompt: "Exercise the packaged Mac board renderer.",
				Provider: "mock", Model: "mock", WorkspaceMode: workspaceMode,
				LabelIDs: labelIDs,
			})
			if err != nil {
				return model.Board{}, fmt.Errorf("create board stress card %d: %w", cardIndex+1, err)
			}
			if cardIndex%2 == 0 {
				if _, err = data.UpdateCardCache(card.ID, boardstore.CardCacheInput{
					Summary: "Mixed card content exercises variable-height text, labels, menus, sheets, help, and drop targets.",
				}); err != nil {
					return model.Board{}, fmt.Errorf("update board stress card %d: %w", cardIndex+1, err)
				}
			}
			cardIndex++
		}
	}
	return board, nil
}
