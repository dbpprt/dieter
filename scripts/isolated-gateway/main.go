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
	"syscall"
	"time"

	"github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/gateway"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/server"
	boardstore "github.com/dbpprt/dieter/internal/store"
)

func main() {
	address := flag.String("addr", "127.0.0.1:14243", "loopback listen address for the gateway copy")
	home := flag.String("home", "", "state root (default: a fresh temporary directory)")
	offlineTrigger := flag.String("offline-trigger", "", "optional file whose creation disconnects the enrolled daemon while leaving the gateway online")
	boardStressFixture := flag.Bool("board-stress-fixture", false, "seed a 78-card board with 65 variable-height cards in one lane")
	flag.Parse()
	if err := run(*address, *home, *offlineTrigger, *boardStressFixture); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(address, home, offlineTrigger string, boardStressFixture bool) error {
	// The mock harness answers every prompt deterministically, so end-to-end
	// turns complete without real provider credentials.
	if err := os.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1"); err != nil {
		return err
	}
	if home == "" {
		var err error
		home, err = os.MkdirTemp("", "dieter-isolated-*")
		if err != nil {
			return err
		}
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
		GitHubClientID: "isolated", GitHubSecret: "isolated", AllowedUserID: 1, AllowedLogin: "isolated",
		AuthSecret: authSecret, SessionTTL: 12 * time.Hour,
		NativeRedirects: map[string]struct{}{}, GitHubBaseURL: "https://github.invalid", GitHubAPIURL: "https://api.github.invalid",
		DevInsecure: true,
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

	identity, err := daemon.LoadOrCreateEnrollmentIdentity(filepath.Join(home, "daemon"), "Isolated E2E machine", publicURL.String())
	if err != nil {
		return err
	}
	enrollment, err := daemon.BeginEnrollment(ctx, identity)
	if err != nil {
		return err
	}
	if err = gatewayStore.ApproveEnrollment(enrollment.GetEnrollmentId(), enrollment.GetUserCode(), config.AllowedUserID, config.AllowedLogin); err != nil {
		return err
	}
	credential, err := daemon.CompleteEnrollment(ctx, identity, enrollment.GetEnrollmentId(), enrollment.GetEnrollmentSecret())
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
		{"git", "-C", repository, "commit", "-m", "initial"},
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

	boardListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	boardHTTP := &http.Server{Handler: server.New(data, logger).Handler()}
	go func() { _ = boardHTTP.Serve(boardListener) }()
	defer boardHTTP.Close()

	tunnel := &daemon.GatewayClient{Identity: identity, LocalTarget: boardListener.Addr().String(), Version: "isolated-e2e", Log: logger}
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
			TokenHash: digest, GitHubID: config.AllowedUserID, Login: config.AllowedLogin,
			CreatedAt: now, ExpiresAt: now.Add(config.SessionTTL),
		})
		return nil
	}); err != nil {
		return err
	}

	deadline := time.Now().Add(10 * time.Second)
	for !gatewayServer.Hub.Online(identity.ID) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !gatewayServer.Hub.Online(identity.ID) {
		return fmt.Errorf("daemon tunnel did not come online")
	}

	fmt.Printf("DIETER_ISOLATED_ADDR=%s\n", gatewayListener.Addr().String())
	fmt.Printf("DIETER_ISOLATED_TOKEN=%s\n", token)
	fmt.Printf("DIETER_ISOLATED_DAEMON=%s\n", identity.ID)
	fmt.Printf("DIETER_ISOLATED_PROJECT=%s\n", project.ID)
	fmt.Printf("DIETER_ISOLATED_BOARD=%s\n", board.ID)
	fmt.Println("READY")

	<-ctx.Done()
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
		{lane: model.LaneTodo, count: 65},
		{lane: model.LaneRunning, count: 5},
		{lane: model.LaneReview, count: 4},
		{lane: model.LaneDone, count: 4},
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
			if cardIndex%6 == 0 {
				if _, err = data.AddComment(card.ID, "Board stress fixture comment.", model.Author{Kind: "human", Name: "Fixture"}); err != nil {
					return model.Board{}, fmt.Errorf("comment on board stress card %d: %w", cardIndex+1, err)
				}
			}
			cardIndex++
		}
	}
	return board, nil
}
