package gateway_test

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/dbpprt/nauclio/internal/daemon"
	"github.com/dbpprt/nauclio/internal/gateway"
	gatewayv1 "github.com/dbpprt/nauclio/internal/gen/nauclio/gateway/v1"
	naucliov1 "github.com/dbpprt/nauclio/internal/gen/nauclio/v1"
	"github.com/dbpprt/nauclio/internal/server"
	"github.com/dbpprt/nauclio/internal/store"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/types/known/emptypb"
)

func TestGatewayEnrollsDaemonAndRelaysNauclioService(t *testing.T) {
	t.Setenv("NAUCLIO_ENABLE_MOCK_HARNESS", "1")
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	gatewayListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	publicURL, _ := url.Parse("http://" + gatewayListener.Addr().String())
	config := gateway.Config{
		Root: t.TempDir(), Address: gatewayListener.Addr().String(), PublicURL: publicURL,
		GitHubClientID: "test", GitHubSecret: "test", AllowedUserID: 7000188, AllowedLogin: "owner",
		AuthSecret: []byte("0123456789abcdef0123456789abcdef"), SessionTTL: time.Hour,
		NativeRedirects: map[string]struct{}{}, GitHubBaseURL: "https://github.invalid", GitHubAPIURL: "https://api.github.invalid", DevInsecure: true,
	}
	gatewayStore, err := gateway.OpenStore(config.Root)
	if err != nil {
		t.Fatal(err)
	}
	defer gatewayStore.Close()
	gatewayServer, err := gateway.NewServer(config, gatewayStore, logger)
	if err != nil {
		t.Fatal(err)
	}
	go gatewayServer.Serve(gatewayListener)
	defer gatewayListener.Close()

	connection, err := grpc.NewClient(gatewayListener.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()

	identity, err := daemon.LoadOrCreateEnrollmentIdentity(t.TempDir(), "Test machine", publicURL.String())
	if err != nil {
		t.Fatal(err)
	}
	enrollment, err := daemon.BeginEnrollment(ctx, identity)
	if err != nil {
		t.Fatal(err)
	}
	if err := gatewayStore.ApproveEnrollment(enrollment.GetEnrollmentId(), enrollment.GetUserCode(), config.AllowedUserID, "owner"); err != nil {
		t.Fatal(err)
	}
	credential, err := daemon.CompleteEnrollment(ctx, identity, enrollment.GetEnrollmentId(), enrollment.GetEnrollmentSecret())
	if err != nil {
		t.Fatal(err)
	}
	if err := identity.SaveCredential(credential.GetDaemonId(), credential.GetDaemonName(), credential.GetCertificatePem(), credential.GetDaemonCaPem(), credential.GetGatewaySigningPublicKey(), credential.GetExpiresAt(), credential.GetGeneration()); err != nil {
		t.Fatal(err)
	}

	boardStore := store.New(t.TempDir())
	if err := boardStore.Ensure(); err != nil {
		t.Fatal(err)
	}
	repositoryPath := filepath.Join(t.TempDir(), "repo")
	if err := os.MkdirAll(filepath.Join(repositoryPath, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	project, err := boardStore.CreateProject(store.CreateProjectInput{Name: "Relay", Path: repositoryPath})
	if err != nil {
		t.Fatal(err)
	}
	boardListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	boardHTTP := &http.Server{Handler: server.New(boardStore, logger).Handler()}
	go boardHTTP.Serve(boardListener)
	defer boardHTTP.Close()

	tunnel := &daemon.GatewayClient{Identity: identity, LocalTarget: boardListener.Addr().String(), Version: "test", Log: logger}
	go func() { _ = tunnel.Run(ctx) }()

	session := "native-test-session"
	digest := sessionDigest(config.AuthSecret, session)
	if err := gatewayStore.UpdateAuthState(func(state *gateway.AuthState) error {
		state.Sessions = append(state.Sessions, gateway.Session{TokenHash: digest, GitHubID: config.AllowedUserID, Login: "owner", CreatedAt: time.Now().UTC(), ExpiresAt: time.Now().UTC().Add(time.Hour)})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	authorized := metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+session)

	deadline := time.Now().Add(5 * time.Second)
	for !gatewayServer.Hub.Online(identity.ID) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !gatewayServer.Hub.Online(identity.ID) {
		t.Fatal("daemon did not establish its reverse tunnel")
	}

	routed := metadata.AppendToOutgoingContext(authorized, "x-nauclio-daemon-id", identity.ID)
	nauclioClient := naucliov1.NewNauclioServiceClient(connection)
	health, err := nauclioClient.Health(routed, &emptypb.Empty{})
	if err != nil {
		t.Fatalf("relay NauclioService.Health: %v", err)
	}
	if health.GetStatus() != "ok" || health.GetStorePath() != boardStore.Root {
		t.Fatalf("unexpected relayed health: %#v", health)
	}
	terminalCtx, stopTerminal := context.WithTimeout(routed, 10*time.Second)
	defer stopTerminal()
	terminalSession, err := nauclioClient.CreateTerminal(terminalCtx, &naucliov1.CreateTerminalRequest{
		ProjectId: project.ID, Shell: "sh", WorkingDirectory: repositoryPath, Columns: 100, Rows: 30,
	})
	if err != nil || terminalSession.GetStatus() != "running" {
		t.Fatalf("create relayed terminal=%#v err=%v", terminalSession, err)
	}
	firstWatchCtx, stopFirstWatch := context.WithCancel(terminalCtx)
	firstWatch, err := nauclioClient.WatchTerminal(firstWatchCtx, &naucliov1.WatchTerminalRequest{TerminalId: terminalSession.GetId(), HeartbeatMs: 1_000})
	if err != nil {
		t.Fatalf("watch relayed terminal: %v", err)
	}
	baseline, err := firstWatch.Recv()
	if err != nil || !baseline.GetScreenReset() {
		t.Fatalf("relayed terminal baseline=%#v err=%v", baseline, err)
	}
	if _, err := nauclioClient.WriteTerminal(terminalCtx, &naucliov1.TerminalInputRequest{
		TerminalId: terminalSession.GetId(), Data: []byte("printf 'gateway-terminal-first\\n'\n"),
	}); err != nil {
		t.Fatalf("write relayed terminal: %v", err)
	}
	firstSequence := receiveRelayedTerminalMarker(t, firstWatch, "gateway-terminal-first")
	stopFirstWatch()
	if _, err := nauclioClient.WriteTerminal(terminalCtx, &naucliov1.TerminalInputRequest{
		TerminalId: terminalSession.GetId(), Data: []byte("printf 'gateway-terminal-resumed\\n'\n"),
	}); err != nil {
		t.Fatalf("write disconnected relayed terminal: %v", err)
	}
	resumedWatch, err := nauclioClient.WatchTerminal(terminalCtx, &naucliov1.WatchTerminalRequest{
		TerminalId: terminalSession.GetId(), AfterSequence: firstSequence, HeartbeatMs: 1_000,
	})
	if err != nil {
		t.Fatalf("resume relayed terminal: %v", err)
	}
	if sequence := receiveRelayedTerminalMarker(t, resumedWatch, "gateway-terminal-resumed"); sequence <= firstSequence {
		t.Fatalf("relayed terminal sequence did not advance: %d <= %d", sequence, firstSequence)
	}
	if _, err := nauclioClient.CloseTerminal(terminalCtx, &naucliov1.TerminalRef{TerminalId: terminalSession.GetId()}); err != nil {
		t.Fatalf("close relayed terminal: %v", err)
	}

	syncStream, err := nauclioClient.WatchSync(routed, &naucliov1.SyncRequest{ConversationLimit: 20, HeartbeatMs: 1_000})
	if err != nil {
		t.Fatalf("open relayed global sync: %v", err)
	}
	syncFrame, err := syncStream.Recv()
	if err != nil || syncFrame.GetSnapshot() == nil || syncFrame.GetCursor().GetEpoch() == "" {
		t.Fatalf("relayed global sync frame=%#v err=%v", syncFrame, err)
	}
	command := &naucliov1.CreateConversationRequest{
		ProjectId: project.ID, Title: "Relayed outbox", Prompt: "deliver once",
		Provider: "mock", Model: "mock", DeferStart: true,
		ClientId: "gateway-e2e-client", CommandId: "gateway-e2e-command",
	}
	created, err := nauclioClient.CreateChat(routed, command)
	if err != nil {
		t.Fatalf("relayed outbox command: %v", err)
	}
	repeated, err := nauclioClient.CreateChat(routed, command)
	if err != nil || repeated.GetId() != created.GetId() {
		t.Fatalf("relayed idempotent command first=%q repeated=%#v err=%v", created.GetId(), repeated, err)
	}
	for {
		frame, receiveErr := syncStream.Recv()
		if receiveErr != nil {
			t.Fatalf("receive relayed command event: %v", receiveErr)
		}
		found := false
		for _, chat := range frame.GetSnapshot().GetState().GetChats() {
			found = found || chat.GetId() == created.GetId()
		}
		if found {
			break
		}
	}
	if err := filepath.Walk(config.Root, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil || info.IsDir() {
			return walkErr
		}
		raw, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		if bytes.Contains(raw, []byte(command.GetCommandId())) || bytes.Contains(raw, []byte(command.GetPrompt())) {
			t.Fatalf("gateway persisted Board command data in %s", path)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	watchCtx, stopWatch := context.WithCancel(routed)
	watch, err := naucliov1.NewNauclioServiceClient(connection).WatchState(watchCtx, &naucliov1.WatchStateRequest{IntervalMs: 100})
	if err != nil {
		t.Fatalf("open relayed state stream: %v", err)
	}
	state, err := watch.Recv()
	stopWatch()
	if err != nil || state.GetStorePath() != boardStore.Root {
		t.Fatalf("relayed state stream=%#v err=%v", state, err)
	}

	gatewayClient := gatewayv1Client(connection)
	list, err := gatewayClient.ListDaemons(authorized, &emptypb.Empty{})
	if err != nil || len(list.GetDaemons()) != 1 || !list.GetDaemons()[0].GetOnline() {
		t.Fatalf("list daemons=%#v err=%v", list, err)
	}
	renamed, err := gatewayClient.RenameDaemon(authorized, &gatewayv1.RenameDaemonRequest{DaemonId: identity.ID, Name: "Studio runner"})
	if err != nil || renamed.GetName() != "Studio runner" {
		t.Fatalf("rename daemon=%#v err=%v", renamed, err)
	}
	list, err = gatewayClient.ListDaemons(authorized, &emptypb.Empty{})
	if err != nil || len(list.GetDaemons()) != 1 || list.GetDaemons()[0].GetName() != "Studio runner" {
		t.Fatalf("persisted daemon display name=%#v err=%v", list, err)
	}
	token, err := gatewayClient.ExchangeDaemonToken(authorized, &gatewayv1.ExchangeDaemonTokenRequest{DaemonId: identity.ID, ClientKeyThumbprint: "client-key"})
	if err != nil {
		t.Fatal(err)
	}
	public, err := gateway.PublicKeyFromPEM(identity.GatewaySigningPublicKey)
	if err != nil {
		t.Fatal(err)
	}
	claims, err := gateway.ParseAndVerifyDaemonToken(public, token.GetAccessToken(), publicURL.String(), identity.ID, identity.Generation, time.Now().UTC())
	if err != nil || claims.ClientThumbprint != "client-key" {
		t.Fatalf("verify daemon token claims=%#v err=%v", claims, err)
	}
	if token.GetTokenType() != "Bearer" {
		t.Fatalf("unexpected daemon token type %q", token.GetTokenType())
	}
	route, err := gatewayClient.ResolveDaemonRoute(authorized, &gatewayv1.DaemonRef{DaemonId: identity.ID})
	if err != nil || string(route.GetDaemonCaPem()) != string(identity.DaemonCAPEM) {
		t.Fatalf("resolve route=%#v err=%v", route, err)
	}

	directListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	direct, err := daemon.NewDirectServer(identity, boardListener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	go direct.Serve(directListener)
	defer direct.Stop()
	defer directListener.Close()
	directConnection, err := daemon.DialDirect(ctx, directListener.Addr().String(), identity.ID, identity.DaemonCAPEM, token.GetAccessToken())
	if err != nil {
		t.Fatal(err)
	}
	defer directConnection.Close()
	directHealth, err := naucliov1.NewNauclioServiceClient(directConnection).Health(ctx, &emptypb.Empty{})
	if err != nil || directHealth.GetStorePath() != boardStore.Root {
		t.Fatalf("direct authenticated health=%#v err=%v", directHealth, err)
	}

	// A tunnel can be dropped by an idle proxy or a gateway-side transport
	// failure while both processes remain healthy. The daemon must establish a
	// fresh authenticated link and make relayed RPCs usable again.
	gatewayServer.Hub.CloseDaemon(identity.ID)
	deadline = time.Now().Add(5 * time.Second)
	for gatewayServer.Hub.Online(identity.ID) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if gatewayServer.Hub.Online(identity.ID) {
		t.Fatal("daemon tunnel did not disconnect")
	}
	deadline = time.Now().Add(5 * time.Second)
	for !gatewayServer.Hub.Online(identity.ID) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if !gatewayServer.Hub.Online(identity.ID) {
		t.Fatal("daemon did not reconnect its reverse tunnel")
	}
	reconnectedHealth, err := naucliov1.NewNauclioServiceClient(connection).Health(routed, &emptypb.Empty{})
	if err != nil || reconnectedHealth.GetStorePath() != boardStore.Root {
		t.Fatalf("reconnected relay health=%#v err=%v", reconnectedHealth, err)
	}
}

func receiveRelayedTerminalMarker(t *testing.T, stream interface {
	Recv() (*naucliov1.TerminalFrame, error)
}, marker string) uint64 {
	t.Helper()
	var output []byte
	var sequence uint64
	for !bytes.Contains(output, []byte(marker)) {
		frame, err := stream.Recv()
		if err != nil {
			t.Fatal(err)
		}
		output = append(output, frame.GetData()...)
		if frame.GetSequence() > sequence {
			sequence = frame.GetSequence()
		}
	}
	return sequence
}

func TestGatewayRoutesMultipleDaemonsAndTracksPresenceIndependently(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	gatewayListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	publicURL, _ := url.Parse("http://" + gatewayListener.Addr().String())
	config := gateway.Config{
		Root: t.TempDir(), Address: gatewayListener.Addr().String(), PublicURL: publicURL,
		GitHubClientID: "test", GitHubSecret: "test", AllowedUserID: 7000188, AllowedLogin: "owner",
		AuthSecret: []byte("0123456789abcdef0123456789abcdef"), SessionTTL: time.Hour,
		NativeRedirects: map[string]struct{}{}, GitHubBaseURL: "https://github.invalid", GitHubAPIURL: "https://api.github.invalid", DevInsecure: true,
	}
	gatewayStore, err := gateway.OpenStore(config.Root)
	if err != nil {
		t.Fatal(err)
	}
	defer gatewayStore.Close()
	gatewayServer, err := gateway.NewServer(config, gatewayStore, logger)
	if err != nil {
		t.Fatal(err)
	}
	go gatewayServer.Serve(gatewayListener)
	defer gatewayListener.Close()

	connection, err := grpc.NewClient(gatewayListener.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()

	session := "multi-daemon-session"
	if err := gatewayStore.UpdateAuthState(func(state *gateway.AuthState) error {
		state.Sessions = append(state.Sessions, gateway.Session{
			TokenHash: sessionDigest(config.AuthSecret, session), GitHubID: config.AllowedUserID, Login: "owner",
			CreatedAt: time.Now().UTC(), ExpiresAt: time.Now().UTC().Add(time.Hour),
		})
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	authorized := metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+session)

	type machine struct {
		identity *daemon.Identity
		store    *store.Store
		stop     context.CancelFunc
	}
	machines := make([]machine, 0, 2)
	for _, name := range []string{"Studio Mac", "Build server"} {
		identity, err := daemon.LoadOrCreateEnrollmentIdentity(t.TempDir(), name, publicURL.String())
		if err != nil {
			t.Fatal(err)
		}
		enrollment, err := daemon.BeginEnrollment(ctx, identity)
		if err != nil {
			t.Fatal(err)
		}
		if err := gatewayStore.ApproveEnrollment(enrollment.GetEnrollmentId(), enrollment.GetUserCode(), config.AllowedUserID, "owner"); err != nil {
			t.Fatal(err)
		}
		credential, err := daemon.CompleteEnrollment(ctx, identity, enrollment.GetEnrollmentId(), enrollment.GetEnrollmentSecret())
		if err != nil {
			t.Fatal(err)
		}
		if err := identity.SaveCredential(credential.GetDaemonId(), credential.GetDaemonName(), credential.GetCertificatePem(), credential.GetDaemonCaPem(), credential.GetGatewaySigningPublicKey(), credential.GetExpiresAt(), credential.GetGeneration()); err != nil {
			t.Fatal(err)
		}

		boardStore := store.New(t.TempDir())
		if err := boardStore.Ensure(); err != nil {
			t.Fatal(err)
		}
		boardListener, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		boardHTTP := &http.Server{Handler: server.New(boardStore, logger).Handler()}
		go boardHTTP.Serve(boardListener)
		t.Cleanup(func() {
			_ = boardHTTP.Close()
			_ = boardListener.Close()
		})

		machineCtx, stop := context.WithCancel(ctx)
		tunnel := &daemon.GatewayClient{Identity: identity, LocalTarget: boardListener.Addr().String(), Version: "test", Log: logger}
		go func() { _ = tunnel.Run(machineCtx) }()
		machines = append(machines, machine{identity: identity, store: boardStore, stop: stop})
	}

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if gatewayServer.Hub.Online(machines[0].identity.ID) && gatewayServer.Hub.Online(machines[1].identity.ID) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	for _, machine := range machines {
		if !gatewayServer.Hub.Online(machine.identity.ID) {
			t.Fatalf("daemon %q did not establish its reverse tunnel", machine.identity.Name)
		}
		routed := metadata.AppendToOutgoingContext(authorized, "x-nauclio-daemon-id", machine.identity.ID)
		health, err := naucliov1.NewNauclioServiceClient(connection).Health(routed, &emptypb.Empty{})
		if err != nil || health.GetStorePath() != machine.store.Root {
			t.Fatalf("relay %q health=%#v err=%v", machine.identity.Name, health, err)
		}
	}

	list, err := gatewayv1Client(connection).ListDaemons(authorized, &emptypb.Empty{})
	if err != nil || len(list.GetDaemons()) != 2 {
		t.Fatalf("list daemons=%#v err=%v", list, err)
	}
	for _, item := range list.GetDaemons() {
		if !item.GetOnline() {
			t.Fatalf("expected both daemons online: %#v", list)
		}
	}

	machines[0].stop()
	deadline = time.Now().Add(5 * time.Second)
	for gatewayServer.Hub.Online(machines[0].identity.ID) && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if gatewayServer.Hub.Online(machines[0].identity.ID) || !gatewayServer.Hub.Online(machines[1].identity.ID) {
		t.Fatalf("daemon presence was not independent")
	}
}

func sessionDigest(secret []byte, token string) string {
	mac := hmac.New(sha256.New, secret)
	_, _ = mac.Write([]byte(token))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// Keep all generated gateway references in one place so the test exercises
// the exact native gRPC surface used by macOS and Android.
func gatewayv1Client(connection *grpc.ClientConn) gatewayv1.GatewayServiceClient {
	return gatewayv1.NewGatewayServiceClient(connection)
}
