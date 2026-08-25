package gateway_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
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

	"github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/gateway"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/server"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/pion/webrtc/v4"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

func TestGatewayEnrollsDaemonAndRelaysDieterService(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
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
		RTCSTUNURLs: []string{"stun:stun.example:3478"}, RTCTTL: 5 * time.Minute,
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
	if _, err := boardStore.UpdateRemoteDesktopSettings(true, false); err != nil {
		t.Fatal(err)
	}
	remoteDesktop := remotedesktop.New(remotedesktop.Options{
		Identity: remotedesktop.Identity{
			DaemonID: identity.ID, GatewayURL: identity.GatewayURL, Generation: identity.Generation,
			PrivateKey: identity.PrivateKey, GatewaySigningPublicKey: identity.GatewaySigningPublicKey,
		},
		Source: remotedesktop.SourceOptions{Kind: "synthetic", FPS: 10},
		Logger: logger, DetachGrace: 100 * time.Millisecond, MonitorInterval: 10 * time.Millisecond,
	})
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
	boardHTTP := &http.Server{Handler: server.NewWithRemoteDesktop(boardStore, logger, nil, remoteDesktop).Handler()}
	go boardHTTP.Serve(boardListener)
	defer boardHTTP.Close()

	tunnel := &daemon.GatewayClient{
		Identity: identity, LocalTarget: boardListener.Addr().String(), Version: "test", Log: logger,
		RemoteDesktopPresence: func() *gatewayv1.RemoteDesktopPresence {
			return remoteDesktop.Presence(true, false)
		},
	}
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

	routed := metadata.AppendToOutgoingContext(authorized, "x-dieter-daemon-id", identity.ID)
	dieterClient := dieterv1.NewDieterServiceClient(connection)
	health, err := dieterClient.Health(routed, &emptypb.Empty{})
	if err != nil {
		t.Fatalf("relay DieterService.Health: %v", err)
	}
	if health.GetStatus() != "ok" || health.GetStorePath() != boardStore.Root {
		t.Fatalf("unexpected relayed health: %#v", health)
	}
	terminalCtx, stopTerminal := context.WithTimeout(routed, 10*time.Second)
	defer stopTerminal()
	terminalSession, err := dieterClient.CreateTerminal(terminalCtx, &dieterv1.CreateTerminalRequest{
		ProjectId: project.ID, Shell: "sh", WorkingDirectory: repositoryPath, Columns: 100, Rows: 30,
	})
	if err != nil || terminalSession.GetStatus() != "running" {
		t.Fatalf("create relayed terminal=%#v err=%v", terminalSession, err)
	}
	firstWatchCtx, stopFirstWatch := context.WithCancel(terminalCtx)
	firstWatch, err := dieterClient.WatchTerminal(firstWatchCtx, &dieterv1.WatchTerminalRequest{TerminalId: terminalSession.GetId(), HeartbeatMs: 1_000})
	if err != nil {
		t.Fatalf("watch relayed terminal: %v", err)
	}
	baseline, err := firstWatch.Recv()
	if err != nil || !baseline.GetScreenReset() {
		t.Fatalf("relayed terminal baseline=%#v err=%v", baseline, err)
	}
	if _, err := dieterClient.WriteTerminal(terminalCtx, &dieterv1.TerminalInputRequest{
		TerminalId: terminalSession.GetId(), Data: []byte("printf 'gateway-terminal-first\\n'\n"),
	}); err != nil {
		t.Fatalf("write relayed terminal: %v", err)
	}
	firstSequence := receiveRelayedTerminalMarker(t, firstWatch, "gateway-terminal-first")
	stopFirstWatch()
	if _, err := dieterClient.WriteTerminal(terminalCtx, &dieterv1.TerminalInputRequest{
		TerminalId: terminalSession.GetId(), Data: []byte("printf 'gateway-terminal-resumed\\n'\n"),
	}); err != nil {
		t.Fatalf("write disconnected relayed terminal: %v", err)
	}
	resumedWatch, err := dieterClient.WatchTerminal(terminalCtx, &dieterv1.WatchTerminalRequest{
		TerminalId: terminalSession.GetId(), AfterSequence: firstSequence, HeartbeatMs: 1_000,
	})
	if err != nil {
		t.Fatalf("resume relayed terminal: %v", err)
	}
	if sequence := receiveRelayedTerminalMarker(t, resumedWatch, "gateway-terminal-resumed"); sequence <= firstSequence {
		t.Fatalf("relayed terminal sequence did not advance: %d <= %d", sequence, firstSequence)
	}
	if _, err := dieterClient.CloseTerminal(terminalCtx, &dieterv1.TerminalRef{TerminalId: terminalSession.GetId()}); err != nil {
		t.Fatalf("close relayed terminal: %v", err)
	}

	syncStream, err := dieterClient.WatchSync(routed, &dieterv1.SyncRequest{ConversationLimit: 0, HeartbeatMs: 1_000})
	if err != nil {
		t.Fatalf("open relayed global sync: %v", err)
	}
	syncFrame, err := syncStream.Recv()
	if err != nil || syncFrame.GetSnapshot() == nil || syncFrame.GetCursor().GetEpoch() == "" {
		t.Fatalf("relayed global sync frame=%#v err=%v", syncFrame, err)
	}
	syncSequence := syncFrame.GetCursor().GetSequence()
	command := &dieterv1.CreateConversationRequest{
		ProjectId: project.ID, Title: "Relayed outbox", Prompt: "deliver once",
		Provider: "mock", Model: "mock", DeferStart: true,
		ClientId: "gateway-e2e-client", CommandId: "gateway-e2e-command",
	}
	created, err := dieterClient.CreateChat(routed, command)
	if err != nil {
		t.Fatalf("relayed outbox command: %v", err)
	}
	repeated, err := dieterClient.CreateChat(routed, command)
	if err != nil || repeated.GetId() != created.GetId() {
		t.Fatalf("relayed idempotent command first=%q repeated=%#v err=%v", created.GetId(), repeated, err)
	}
	for {
		frame, receiveErr := syncStream.Recv()
		if receiveErr != nil {
			t.Fatalf("receive relayed command event: %v", receiveErr)
		}
		found := false
		for _, chat := range frame.GetDelta().GetChats() {
			found = found || chat.GetId() == created.GetId()
		}
		if frame.GetCursor().GetSequence() > syncSequence {
			syncSequence = frame.GetCursor().GetSequence()
		}
		if found {
			break
		}
	}
	if err := boardStore.SaveCommandResult("gateway-e2e-client", "projection-neutral", store.CommandResult{Kind: "test"}); err != nil {
		t.Fatal(err)
	}
	for {
		frame, receiveErr := syncStream.Recv()
		if receiveErr != nil {
			t.Fatalf("receive relayed projection-neutral event: %v", receiveErr)
		}
		if frame.GetHeartbeat() || frame.GetCursor().GetSequence() <= syncSequence {
			continue
		}
		if frame.GetDelta() != nil || frame.GetSnapshot() != nil || len(frame.GetEvents()) == 0 {
			t.Fatalf("relayed projection-neutral event was not cursor-only: delta=%v frame=%#v", frame.GetDelta(), frame)
		}
		break
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
	watch, err := dieterv1.NewDieterServiceClient(connection).WatchState(watchCtx, &dieterv1.WatchStateRequest{IntervalMs: 100})
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
	if desktop := list.GetDaemons()[0].GetRemoteDesktop(); !desktop.GetReady() || desktop.GetPlatform() != "darwin" {
		t.Fatalf("remote desktop presence=%#v", desktop)
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
	rtc, err := gatewayClient.GetRTCConfiguration(authorized, &gatewayv1.DaemonRef{DaemonId: identity.ID})
	if err != nil {
		t.Fatal(err)
	}
	unsigned := proto.Clone(rtc).(*gatewayv1.RTCConfiguration)
	unsigned.SignedEnvelope = nil
	raw, err := proto.MarshalOptions{Deterministic: true}.Marshal(unsigned)
	if err != nil {
		t.Fatal(err)
	}
	rtcDigest := sha256.Sum256(raw)
	rtcClaims, err := gateway.ParseAndVerifyRTCConfiguration(public, string(rtc.GetSignedEnvelope()), publicURL.String(), identity.ID, "github:7000188", rtc.GetConfigurationId(), rtcDigest[:], identity.Generation, time.Now().UTC())
	if err != nil || rtcClaims.ID != rtc.GetConfigurationId() || len(rtc.GetIceServers()) != 1 {
		t.Fatalf("verify RTC configuration claims=%#v config=%#v err=%v", rtcClaims, rtc, err)
	}
	testRemoteDesktopThroughGateway(t, routed, dieterClient, rtc, identity, remoteDesktop)
	route, err := gatewayClient.ResolveDaemonRoute(authorized, &gatewayv1.DaemonRef{DaemonId: identity.ID})
	if err != nil || string(route.GetDaemonCaPem()) != string(identity.DaemonCAPEM) || string(route.GetDaemonCertificatePem()) != string(identity.CertificatePEM) {
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
	directHealth, err := dieterv1.NewDieterServiceClient(directConnection).Health(ctx, &emptypb.Empty{})
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
	reconnectedHealth, err := dieterv1.NewDieterServiceClient(connection).Health(routed, &emptypb.Empty{})
	if err != nil || reconnectedHealth.GetStorePath() != boardStore.Root {
		t.Fatalf("reconnected relay health=%#v err=%v", reconnectedHealth, err)
	}

	if _, err := gatewayClient.UnenrollDaemon(ctx, &gatewayv1.UnenrollDaemonRequest{
		DaemonId: identity.ID, Nonce: make([]byte, 32), Signature: make([]byte, 64),
	}); err == nil {
		t.Fatal("unsigned daemon unenrollment unexpectedly succeeded")
	}
	if record, err := gatewayStore.Daemon(identity.ID); err != nil || record.Revoked {
		t.Fatalf("invalid unenrollment changed daemon record=%#v err=%v", record, err)
	}
	if err := daemon.Unenroll(ctx, identity); err != nil {
		t.Fatal(err)
	}
	// A repeated signed request is safe if the gateway committed revocation but
	// the command did not receive its response or clear the local credential.
	if err := daemon.Unenroll(ctx, identity); err != nil {
		t.Fatalf("repeat daemon unenrollment: %v", err)
	}
	deadline = time.Now().Add(5 * time.Second)
	for gatewayServer.Hub.Online(identity.ID) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	record, err := gatewayStore.Daemon(identity.ID)
	if err != nil || !record.Revoked || gatewayServer.Hub.Online(identity.ID) {
		t.Fatalf("unenrolled daemon record=%#v online=%v err=%v", record, gatewayServer.Hub.Online(identity.ID), err)
	}
	list, err = gatewayClient.ListDaemons(authorized, &emptypb.Empty{})
	if err != nil || len(list.GetDaemons()) != 0 {
		t.Fatalf("unenrolled daemon remained discoverable: %#v err=%v", list, err)
	}
	if err := identity.ClearCredential(); err != nil {
		t.Fatal(err)
	}
	reloaded, err := daemon.LoadIdentity(identity.Root)
	if err != nil || reloaded.Enrolled() || len(reloaded.PrivateKey) == 0 {
		t.Fatalf("cleared local enrollment=%#v err=%v", reloaded, err)
	}
}

func receiveRelayedTerminalMarker(t *testing.T, stream interface {
	Recv() (*dieterv1.TerminalFrame, error)
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
		routed := metadata.AppendToOutgoingContext(authorized, "x-dieter-daemon-id", machine.identity.ID)
		health, err := dieterv1.NewDieterServiceClient(connection).Health(routed, &emptypb.Empty{})
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

func testRemoteDesktopThroughGateway(t *testing.T, routed context.Context, client dieterv1.DieterServiceClient, rtc *gatewayv1.RTCConfiguration, identity *daemon.Identity, manager *remotedesktop.Manager) {
	t.Helper()
	settings := webrtc.SettingEngine{}
	settings.SetIncludeLoopbackCandidate(true)
	viewer, err := webrtc.NewAPI(webrtc.WithSettingEngine(settings)).NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer viewer.Close()
	if _, err := viewer.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
		t.Fatal(err)
	}
	trackReceived := make(chan struct{}, 1)
	viewer.OnTrack(func(track *webrtc.TrackRemote, _ *webrtc.RTPReceiver) {
		go func() {
			if _, _, err := track.ReadRTP(); err == nil {
				trackReceived <- struct{}{}
			}
		}()
	})
	offer, err := viewer.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gatheringComplete := webrtc.GatheringCompletePromise(viewer)
	if err := viewer.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	select {
	case <-gatheringComplete:
	case <-time.After(5 * time.Second):
		t.Fatal("viewer ICE gathering timed out")
	}
	offer = *viewer.LocalDescription()
	request := &dieterv1.StartRemoteDesktopRequest{
		ClientNonce: "gateway-e2e-nonce", RtcConfiguration: rtc,
		Offer:     &dieterv1.RemoteDesktopSessionDescription{Type: "offer", Sdp: offer.SDP},
		DisplayId: "primary", MaxFps: 10, MaxBitrateKbps: 500,
	}
	streamContext, cancelStream := context.WithTimeout(routed, 12*time.Second)
	defer cancelStream()
	stream, err := client.StartRemoteDesktop(streamContext, request)
	if err != nil {
		t.Fatal(err)
	}
	signals := make(chan *dieterv1.RemoteDesktopSignal, 16)
	signalErrors := make(chan error, 1)
	go func() {
		for {
			signal, receiveErr := stream.Recv()
			if receiveErr != nil {
				signalErrors <- receiveErr
				return
			}
			signals <- signal
		}
	}()

	var binding *dieterv1.RemoteDesktopSessionBinding
	var answer string
	var sessionID string
	answerApplied := false
	var pendingCandidates []*dieterv1.RemoteDesktopICECandidate
	for {
		select {
		case <-trackReceived:
			if !answerApplied || binding == nil || sessionID == "" {
				t.Fatal("received media before authenticating the daemon answer")
			}
			// Model an ungraceful viewer disappearance. Canceling the gateway
			// stream must cancel the relayed local RPC, detach its subscription,
			// and stop the host capture without relying on CloseRemoteDesktop.
			cancelStream()
			deadline := time.Now().Add(2 * time.Second)
			for manager.Capabilities(true, false).GetActiveSession() && time.Now().Before(deadline) {
				time.Sleep(10 * time.Millisecond)
			}
			if manager.Capabilities(true, false).GetActiveSession() {
				t.Fatal("remote desktop session survived viewer relay cancellation")
			}
			return
		case signal := <-signals:
			if sessionID == "" {
				sessionID = signal.GetSessionId()
			}
			switch payload := signal.GetPayload().(type) {
			case *dieterv1.RemoteDesktopSignal_Binding:
				binding = payload.Binding
			case *dieterv1.RemoteDesktopSignal_Description:
				answer = payload.Description.GetSdp()
			case *dieterv1.RemoteDesktopSignal_Candidate:
				if answerApplied {
					if err := viewer.AddICECandidate(e2eCandidateInit(payload.Candidate)); err != nil {
						t.Fatal(err)
					}
				} else {
					pendingCandidates = append(pendingCandidates, payload.Candidate)
				}
			}
			if !answerApplied && binding != nil && answer != "" {
				offerHash := sha256.Sum256([]byte(offer.SDP))
				message := remotedesktop.SessionBindingMessage(sessionID, request.GetClientNonce(), binding.GetHelperDtlsFingerprint(), binding.GetExpiresAt(), offerHash[:])
				if !ed25519.Verify(identity.PublicKey, message, binding.GetDaemonSignature()) {
					t.Fatal("relayed daemon session binding signature did not verify")
				}
				if string(binding.GetOfferSha256()) != string(offerHash[:]) {
					t.Fatal("relayed daemon session binding did not cover the viewer offer")
				}
				if err := viewer.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: answer}); err != nil {
					t.Fatal(err)
				}
				answerApplied = true
				for _, candidate := range pendingCandidates {
					if err := viewer.AddICECandidate(e2eCandidateInit(candidate)); err != nil {
						t.Fatal(err)
					}
				}
				pendingCandidates = nil
			}
		case receiveErr := <-signalErrors:
			t.Fatalf("remote desktop signaling ended before media arrived: %v", receiveErr)
		case <-streamContext.Done():
			t.Fatal("remote desktop media timed out")
		}
	}
}

func e2eCandidateInit(candidate *dieterv1.RemoteDesktopICECandidate) webrtc.ICECandidateInit {
	mid := candidate.GetSdpMid()
	index := uint16(max(0, int(candidate.GetSdpMlineIndex())))
	username := candidate.GetUsernameFragment()
	return webrtc.ICECandidateInit{Candidate: candidate.GetCandidate(), SDPMid: &mid, SDPMLineIndex: &index, UsernameFragment: &username}
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
