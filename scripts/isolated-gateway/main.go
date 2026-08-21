// Command isolated-gateway runs a throwaway copy of the Nauclio gateway plus
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
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/dbpprt/nauclio/internal/daemon"
	"github.com/dbpprt/nauclio/internal/gateway"
	"github.com/dbpprt/nauclio/internal/model"
	"github.com/dbpprt/nauclio/internal/server"
	boardstore "github.com/dbpprt/nauclio/internal/store"
)

func main() {
	address := flag.String("addr", "127.0.0.1:14243", "loopback listen address for the gateway copy")
	home := flag.String("home", "", "state root (default: a fresh temporary directory)")
	flag.Parse()
	if err := run(*address, *home); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(address, home string) error {
	// The mock harness answers every prompt deterministically, so end-to-end
	// turns complete without real provider credentials.
	if err := os.Setenv("NAUCLIO_ENABLE_MOCK_HARNESS", "1"); err != nil {
		return err
	}
	if home == "" {
		var err error
		home, err = os.MkdirTemp("", "nauclio-isolated-*")
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

	data := boardstore.New(filepath.Join(home, "nauclio"))
	if err = data.Ensure(); err != nil {
		return err
	}
	repository := filepath.Join(home, "repo")
	if err = os.MkdirAll(filepath.Join(repository, ".git"), 0o755); err != nil {
		return err
	}
	project, err := data.CreateProject(boardstore.CreateProjectInput{Name: "Isolated E2E", Path: repository})
	if err != nil {
		return err
	}
	board, err := data.CreateBoard(boardstore.CreateBoardInput{Project: project.ID, Name: "Main", Workflow: model.WorkflowReview})
	if err != nil {
		return err
	}

	boardListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	boardHTTP := &http.Server{Handler: server.New(data, logger).Handler()}
	go func() { _ = boardHTTP.Serve(boardListener) }()
	defer boardHTTP.Close()

	tunnel := &daemon.GatewayClient{Identity: identity, LocalTarget: boardListener.Addr().String(), Version: "isolated-e2e", Log: logger}
	go func() { _ = tunnel.Run(ctx) }()

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

	fmt.Printf("NAUCLIO_ISOLATED_ADDR=%s\n", gatewayListener.Addr().String())
	fmt.Printf("NAUCLIO_ISOLATED_TOKEN=%s\n", token)
	fmt.Printf("NAUCLIO_ISOLATED_DAEMON=%s\n", identity.ID)
	fmt.Printf("NAUCLIO_ISOLATED_PROJECT=%s\n", project.ID)
	fmt.Printf("NAUCLIO_ISOLATED_BOARD=%s\n", board.ID)
	fmt.Println("READY")

	<-ctx.Done()
	return nil
}
