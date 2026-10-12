//go:build e2e

package gateway_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	"github.com/dbpprt/dieter/internal/gateway"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/harness"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/model"
	"github.com/dbpprt/dieter/internal/remotedesktop"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/store/commands"
	"github.com/dbpprt/dieter/internal/store/kanban"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/testkit/topology"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"github.com/pion/webrtc/v4"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

// owner is the GitHub account that owns the relay fixture's machines.
const owner int64 = 7000188

func TestGatewayRejectsOutdatedDaemonAndPublishesUpdatePolicy(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	defer cancel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	g := topology.StartGateway(t, topology.GatewayOptions{Configure: func(config *gateway.Config) {
		config.MinimumClientVersion, config.MinimumDaemonVersion = "0.4.308", "0.4.309"
	}})
	gatewayServer := g.Server
	identity := topology.Machine(t, g, "outdated", topology.Account)

	updates := 0
	client := link.GatewayClient{
		Identity: identity, LocalTarget: "127.0.0.1:1", Version: "0.4.308", Log: logger,
		OnUpdateRequired: func(policy *gatewayv1.CompatibilityPolicy) error {
			updates++
			if policy.GetMinimumDaemonVersion() != "0.4.309" || policy.GetRevision() == "" {
				t.Fatalf("policy=%#v", policy)
			}
			return nil
		},
	}
	err := client.Run(ctx)
	var updateRequired *link.UpdateRequiredError
	if !errors.As(err, &updateRequired) || updates != 1 {
		t.Fatalf("error=%v updates=%d", err, updates)
	}
	if gatewayServer.Hub.Online(identity.ID) {
		t.Fatal("outdated daemon entered the online routing pool")
	}
}

func TestGatewayAllowsMultipleAccountsAndIsolatesDaemons(t *testing.T) {
	t.Parallel()
	ctx := t.Context()
	g := topology.StartGateway(t, topology.GatewayOptions{Accounts: []int64{7000188, 60854672}})
	connection := topology.Dial(t, g)

	type account struct {
		githubID int64
		login    string
		session  string
		daemonID string
	}
	accounts := []account{
		{githubID: 7000188, login: "dbpprt", session: "primary-session"},
		{githubID: 60854672, login: "derzierau", session: "secondary-session"},
	}
	for index := range accounts {
		accounts[index].daemonID = topology.Machine(t, g, accounts[index].login+" machine", accounts[index].githubID).ID
		if err := g.AddSession(accounts[index].session, accounts[index].githubID, accounts[index].login); err != nil {
			t.Fatal(err)
		}
	}

	client := gatewayv1Client(connection)
	for index, account := range accounts {
		authorized := metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+account.session, "x-dieter-client-version", "0.4.1-dev")
		list, err := client.ListDaemons(authorized, &emptypb.Empty{})
		if err != nil || len(list.GetDaemons()) != 1 || list.GetDaemons()[0].GetId() != account.daemonID {
			t.Fatalf("@%s daemon isolation=%#v err=%v", account.login, list, err)
		}
		if info := list.GetGatewayInformation(); info.GetReleaseVersion() == "" || info.GetCompatibilityPolicy() == nil {
			t.Fatalf("gateway build information=%#v", info)
		}
		other := accounts[(index+1)%len(accounts)]
		if _, err := client.ExchangeDaemonToken(authorized, &gatewayv1.ExchangeDaemonTokenRequest{DaemonId: other.daemonID, ClientKeyThumbprint: "client-key"}); status.Code(err) != codes.NotFound {
			t.Fatalf("@%s accessed @%s daemon: %v", account.login, other.login, err)
		}
	}
}

// relayFixture is one enrolled daemon behind a gateway. The daemon's tunnel
// reaches the gateway through a pausable proxy; the daemon owns a Git project,
// a synthetic remote desktop, and a runner that holds turns until released.
type relayFixture struct {
	ctx        context.Context
	gateway    *topology.Gateway
	daemon     *topology.Daemon
	proxy      *pauseProxy
	events     <-chan link.GatewayEvent
	runner     *tunnelSurvivalRunner
	desktop    *remotedesktop.Manager
	project    model.Project
	repository string
	connection *grpc.ClientConn
	client     dieterclient.Client
	authorized context.Context
	routed     context.Context
}

func startRelayFixture(t *testing.T) *relayFixture {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Minute)
	t.Cleanup(cancel)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	f := &relayFixture{ctx: ctx, runner: newTunnelSurvivalRunner(), repository: testkit.GitRepo(t)}
	f.gateway = topology.StartGateway(t, topology.GatewayOptions{Accounts: []int64{owner}, Logger: logger, Configure: func(config *gateway.Config) {
		config.RTCSTUNURLs = []string{"stun:stun.example:3478"}
		f.proxy = startPauseProxy(t, config)
	}})
	identity := topology.Machine(t, f.gateway, "Test machine", owner)
	data := store.New(identity.Root)
	if err := data.Ensure(); err != nil {
		t.Fatal(err)
	}
	project, err := data.Kanban.CreateProject(kanban.CreateProjectInput{Name: "Relay", Path: f.repository, BaseBranch: "main"})
	if err != nil {
		t.Fatal(err)
	}
	f.project = project
	f.desktop = remotedesktop.New(remotedesktop.Options{
		Identity: remotedesktop.Identity{
			DaemonID: identity.ID, GatewayURL: identity.GatewayURL, Generation: identity.Generation,
			PrivateKey: identity.PrivateKey, GatewaySigningPublicKey: identity.GatewaySigningPublicKey,
		},
		Source: remotedesktop.SourceOptions{Kind: "synthetic", FPS: 10},
		Logger: logger, DetachGrace: 100 * time.Millisecond, MonitorInterval: 10 * time.Millisecond,
	})
	t.Cleanup(func() { f.desktop.Shutdown(context.Background()) })
	f.daemon = topology.StartDaemon(t, f.gateway, topology.DaemonOptions{
		Identity: identity, Store: data, Logger: logger,
		API: api.Options{Runner: f.runner, RemoteDesktop: f.desktop, Catalog: testkit.MockCatalog()},
		Tunnel: func(tunnel *link.GatewayClient) {
			// The broad relay workload uses production liveness deadlines.
			// Watchdog expiry is exercised separately without Git/WebRTC work
			// competing against an artificially short heartbeat deadline.
			tunnel.Timing = link.GatewayTiming{
				ReconnectInitialBackoff: 20 * time.Millisecond, ReconnectMaximumBackoff: 50 * time.Millisecond,
				ReconnectStableAfter: 200 * time.Millisecond,
			}
			tunnel.RemoteDesktopPresence = func() *gatewayv1.RemoteDesktopPresence { return f.desktop.Presence() }
			f.events = recordGatewayEvents(t, tunnel)
		},
	})
	// Release held turns before the daemon stops.
	t.Cleanup(f.runner.Release)
	waitForGatewayEvent(t, f.events, link.GatewayConnected, 2*time.Second)
	f.connection = topology.Dial(t, f.gateway)
	f.client = dieterclient.New(f.connection)
	session := topology.SignIn(t, f.gateway, owner, "owner")
	f.authorized = topology.Authorized(ctx, session)
	f.routed = topology.Routed(ctx, session, identity.ID)
	return f
}

// startPauseProxy puts a pausable TCP proxy in front of the gateway and makes
// it the public origin, so daemon tunnels pass through it.
func startPauseProxy(t *testing.T, config *gateway.Config) *pauseProxy {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	proxy := newPauseProxy(listener, config.Address)
	go proxy.Serve()
	t.Cleanup(proxy.Close)
	config.PublicURL = &url.URL{Scheme: "http", Host: listener.Addr().String()}
	return proxy
}

// recordGatewayEvents buffers the tunnel's status events for
// waitForGatewayEvent.
func recordGatewayEvents(t *testing.T, tunnel *link.GatewayClient) <-chan link.GatewayEvent {
	events := make(chan link.GatewayEvent, 32)
	tunnel.OnStatus = func(event link.GatewayEvent) {
		t.Logf("gateway state=%s error=%q", event.State, event.Error)
		select {
		case events <- event:
		default:
		}
	}
	return events
}

func TestGatewayRelaysDaemonAPIAndTerminals(t *testing.T) {
	t.Parallel()
	f := startRelayFixture(t)
	dieterClient, routed, boardStore, project, repositoryPath := f.client, f.routed, f.daemon.Store, f.project, f.repository

	health, err := dieterClient.Health(routed, &emptypb.Empty{})
	if err != nil {
		t.Fatalf("relay MachineService.Health: %v", err)
	}
	if health.GetStatus() != "ok" || health.GetStorePath() != boardStore.Root {
		t.Fatalf("unexpected relayed health: %#v", health)
	}
	machineInformation, err := dieterClient.GetMachineInformation(routed, &emptypb.Empty{})
	if err != nil {
		t.Fatalf("relay MachineService.GetMachineInformation: %v", err)
	}
	if machineInformation.GetDaemonBuild().GetReleaseVersion() == "" || machineInformation.GetGpu() == nil {
		t.Fatalf("relayed machine build/GPU information=%#v", machineInformation)
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
}

func TestGatewayRelaysChangesCommandsAndWorkspaceOperations(t *testing.T) {
	t.Parallel()
	f := startRelayFixture(t)
	dieterClient, routed, connection, boardStore, project, repositoryPath := f.client, f.routed, f.connection, f.daemon.Store, f.project, f.repository
	tunnelProxy, config := f.proxy, f.gateway.Config

	changeStream, err := dieterClient.WatchChanges(routed, &dieterv1.ChangesRequest{HeartbeatMs: 1_000})
	if err != nil {
		t.Fatalf("open relayed change stream: %v", err)
	}
	// Without a peer service this machine never binds an account, so its
	// records name the store's own peer identity as owner, as do its frames.
	peer, err := boardStore.Replica.PeerIdentity()
	if err != nil {
		t.Fatal(err)
	}
	projectRecords := 0
	for caughtUp := false; !caughtUp; {
		frame, receiveErr := changeStream.Recv()
		if receiveErr != nil {
			t.Fatalf("receive relayed changes: %v", receiveErr)
		}
		if frame.GetCursor().GetRecordsEpoch() == "" || frame.GetCursor().GetLocalEpoch() == "" || frame.GetDaemonId() != peer.DaemonID {
			t.Fatalf("relayed change frame lacks its machine or cursor: %#v", frame)
		}
		for _, record := range frame.GetRecords() {
			if record.GetKind() == "project" && strings.HasPrefix(record.GetId(), project.ID+".") {
				projectRecords++
			}
		}
		caughtUp = frame.GetCaughtUp()
	}
	if projectRecords == 0 {
		t.Fatal("relayed change stream did not carry the project's records")
	}
	command := &dieterv1.CreateConversationRequest{
		ProjectId: project.ID, Title: "Relayed outbox", Prompt: "deliver once",
		Provider: "mock", Model: "mock", DeferStart: true, WorkspaceMode: "worktree",
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
	conversationWorkspace, err := dieterClient.GetWorkspace(routed, &dieterv1.ConversationRef{CardId: created.GetId()})
	if err != nil || conversationWorkspace.GetMode() != "worktree" || conversationWorkspace.GetPath() == repositoryPath || conversationWorkspace.GetRevision() == "" {
		t.Fatalf("relayed workspace=%#v err=%v", conversationWorkspace, err)
	}
	document, err := dieterClient.ReadFile(routed, &dieterv1.ReadFileRequest{CardId: created.GetId(), Path: "README.md"})
	if err != nil {
		t.Fatalf("read relayed workspace file: %v", err)
	}
	if _, err := dieterClient.SaveFile(routed, &dieterv1.SaveFileRequest{
		CardId: created.GetId(), Path: "README.md", Revision: document.GetRevision(), Content: "relayed workspace\n",
	}); err != nil {
		t.Fatalf("save relayed workspace file: %v", err)
	}
	changes, err := dieterClient.GetChangeset(routed, &dieterv1.GetChangesetRequest{CardId: created.GetId()})
	if err != nil || len(changes.GetFiles()) != 1 {
		t.Fatalf("relayed changeset=%#v err=%v", changes, err)
	}
	gitOperation, err := dieterClient.StartGitOperation(routed, &dieterv1.StartGitOperationRequest{
		CardId: created.GetId(), Kind: "commit", ExpectedRevision: changes.GetRevision(),
		Parameters: map[string]string{"subject": "relayed workspace", "validate": "false", "stage_all": "true"},
	})
	if err != nil {
		t.Fatalf("start relayed Git operation: %v", err)
	}
	// A short transport stall must not tear down the Git watch. This exceeds
	// the old 350 ms test watchdog, but remains well within production's
	// heartbeat budget and models transient scheduling/I/O stalls under -race.
	tunnelProxy.Pause()
	resumeGitTraffic := time.AfterFunc(time.Second, tunnelProxy.Resume)
	defer resumeGitTraffic.Stop()
	gitWatch, err := dieterClient.WatchGitOperation(routed, &dieterv1.WatchGitOperationRequest{OperationId: gitOperation.GetId(), HeartbeatMs: 1_000})
	if err != nil {
		t.Fatalf("watch relayed Git operation: %v", err)
	}
	gitStatus := ""
	for {
		frame, receiveErr := gitWatch.Recv()
		if errors.Is(receiveErr, io.EOF) {
			break
		}
		if receiveErr != nil {
			t.Fatalf("receive relayed Git operation: %v", receiveErr)
		}
		gitStatus = frame.GetOperation().GetStatus()
	}
	if gitStatus != "succeeded" {
		t.Fatalf("relayed Git operation ended as %q", gitStatus)
	}
	// The relayed command reaches the stream as the chat's shared identity and
	// its owner-only details, including the committed workspace. The workspace
	// summary is read from Git, so it can follow the writes above by up to a
	// recovery poll.
	for identityRecord, ownedCard, committed := false, false, false; !identityRecord || !ownedCard || !committed; {
		frame, receiveErr := changeStream.Recv()
		if receiveErr != nil {
			t.Fatalf("receive relayed command changes: %v", receiveErr)
		}
		for _, record := range frame.GetRecords() {
			identityRecord = identityRecord || record.GetKind() == "item" && record.GetId() == created.GetId()+".identity"
		}
		for _, card := range frame.GetOwnedCards() {
			if card.GetId() != created.GetId() {
				continue
			}
			ownedCard = ownedCard || card.GetInitialPrompt() == command.GetPrompt()
			workspace := card.GetWorkspace()
			committed = workspace.GetAhead() == 1 && workspace.GetCurrentOperationId() == ""
		}
	}
	// Drain what is still in flight, then a projection-neutral write must send
	// nothing but heartbeats.
	for heartbeats := 0; heartbeats < 1; {
		frame, receiveErr := changeStream.Recv()
		if receiveErr != nil {
			t.Fatalf("drain relayed workspace changes: %v", receiveErr)
		}
		if frame.GetHeartbeat() {
			heartbeats++
		}
	}
	if err := boardStore.Commands.Save("gateway-e2e-client", "projection-neutral", commands.Result{Kind: "test"}); err != nil {
		t.Fatal(err)
	}
	for heartbeats := 0; heartbeats < 2; heartbeats++ {
		frame, receiveErr := changeStream.Recv()
		if receiveErr != nil {
			t.Fatalf("receive relayed heartbeat: %v", receiveErr)
		}
		if !frame.GetHeartbeat() || !frame.GetCaughtUp() {
			t.Fatalf("projection-neutral write produced a data frame: %#v", frame)
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
	watch, err := dieterclient.New(connection).WatchChanges(watchCtx, &dieterv1.ChangesRequest{})
	if err != nil {
		t.Fatalf("open second relayed change stream: %v", err)
	}
	first, err := watch.Recv()
	stopWatch()
	if err != nil || first.GetDaemonId() != peer.DaemonID || !first.GetResetRecords() || !first.GetResetLocal() {
		t.Fatalf("second relayed change stream=%#v err=%v", first, err)
	}
}

func TestGatewayPublishesDaemonDirectoryTokensAndRoutes(t *testing.T) {
	t.Parallel()
	f := startRelayFixture(t)
	ctx, dieterClient, routed, authorized, connection := f.ctx, f.client, f.routed, f.authorized, f.connection
	identity, boardStore, remoteDesktop, publicURL := f.daemon.Identity, f.daemon.Store, f.desktop, f.gateway.URL

	gatewayClient := gatewayv1Client(connection)
	list, err := gatewayClient.ListDaemons(authorized, &emptypb.Empty{})
	if err != nil || len(list.GetDaemons()) != 1 || !list.GetDaemons()[0].GetOnline() {
		t.Fatalf("list daemons=%#v err=%v", list, err)
	}
	if got := list.GetDaemons()[0].GetCompatibility(); got != gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_COMPATIBLE {
		t.Fatalf("advertised compatibility=%v", got)
	}
	if desktop := list.GetDaemons()[0].GetRemoteDesktop(); !desktop.GetReady() || desktop.GetPlatform() != runtime.GOOS {
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
	claims, err := gateway.ParseAndVerifyDaemonToken(public, token.GetAccessToken(), publicURL, identity.ID, identity.Generation, time.Now().UTC())
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
	rtcClaims, err := gateway.ParseAndVerifyRTCConfiguration(public, string(rtc.GetSignedEnvelope()), publicURL, identity.ID, "github:7000188", rtc.GetConfigurationId(), rtcDigest[:], identity.Generation, time.Now().UTC())
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
	direct, err := link.NewDirectServer(identity, f.daemon.Address, testkit.LocalToken(t, boardStore.Root))
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = direct.Serve(directListener) }()
	defer direct.Stop()
	defer directListener.Close()
	directConnection, err := link.DialDirect(ctx, directListener.Addr().String(), identity.ID, identity.DaemonCAPEM, token.GetAccessToken())
	if err != nil {
		t.Fatal(err)
	}
	defer directConnection.Close()
	directHealth, err := dieterclient.New(directConnection).Health(ctx, &emptypb.Empty{})
	if err != nil || directHealth.GetStorePath() != boardStore.Root {
		t.Fatalf("direct authenticated health=%#v err=%v", directHealth, err)
	}
}

func TestGatewayTunnelLossKeepsDaemonOwnedTurns(t *testing.T) {
	t.Parallel()
	f := startRelayFixture(t)
	dieterClient, routed, connection, boardStore, runner := f.client, f.routed, f.connection, f.daemon.Store, f.runner
	gatewayServer, identity, gatewayEvents := f.gateway.Server, f.daemon.Identity, f.events
	created, err := dieterClient.CreateChat(routed, &dieterv1.CreateConversationRequest{
		ProjectId: f.project.ID, Title: "Tunnel survival", Prompt: "deliver once",
		Provider: "mock", Model: "mock", DeferStart: true, WorkspaceMode: "worktree",
		ClientId: "gateway-e2e-client", CommandId: "gateway-e2e-command",
	})
	if err != nil {
		t.Fatal(err)
	}

	// Start a daemon-owned turn before disconnecting the tunnel. Losing and
	// replacing the transport must cancel only relay RPCs, never this worker.
	startedTurn, err := dieterClient.SendMessage(routed, &dieterv1.SendMessageRequest{
		CardId: created.GetId(), Provider: "mock", Model: "mock",
		Parts:    []*dieterv1.MessagePart{{Type: "text", Text: "keep working while the tunnel reconnects"}},
		ClientId: "gateway-e2e-client", CommandId: "start-survival-turn",
	})
	if err != nil || !startedTurn.GetSent() {
		t.Fatalf("start tunnel-survival turn=%#v err=%v", startedTurn, err)
	}
	select {
	case <-runner.Started:
	case <-time.After(testkit.Budget(30 * time.Second)):
		t.Fatal("daemon-owned turn did not start")
	}

	// Force the transport loss explicitly. The focused blackhole test below
	// verifies watchdog/handshake timeouts; this test verifies that losing a
	// transport never cancels a durable turn or duplicates a queued message.
	gatewayServer.Hub.CloseDaemon(identity.ID)
	waitForGatewayEvent(t, gatewayEvents, link.GatewayDisconnected, 5*time.Second)
	if running, resolveErr := boardStore.Kanban.ResolveCard(created.GetId()); resolveErr != nil || running.Runtime != "running" {
		t.Fatalf("tunnel loss changed daemon-owned turn runtime=%q err=%v", running.Runtime, resolveErr)
	}
	select {
	case <-runner.Canceled:
		t.Fatal("tunnel loss canceled the daemon-owned agent turn")
	default:
	}

	waitForGatewayEvent(t, gatewayEvents, link.GatewayConnected, 5*time.Second)
	if !gatewayServer.Hub.Online(identity.ID) {
		t.Fatal("daemon did not register its reconnected reverse tunnel")
	}
	reconnectedHealth, err := dieterclient.New(connection).Health(routed, &emptypb.Empty{})
	if err != nil || reconnectedHealth.GetStorePath() != boardStore.Root {
		t.Fatalf("reconnected relay health=%#v err=%v", reconnectedHealth, err)
	}
	queuedRequest := &dieterv1.SendMessageRequest{
		CardId: created.GetId(), Provider: "mock", Model: "mock",
		Parts:    []*dieterv1.MessagePart{{Type: "text", Text: "deliver once after reconnect"}},
		ClientId: "gateway-e2e-client", CommandId: "post-reconnect-message",
	}
	queued, err := dieterClient.SendMessage(routed, queuedRequest)
	if err != nil || !queued.GetQueued() || queued.GetMessageId() == "" {
		t.Fatalf("queue post-reconnect message=%#v err=%v", queued, err)
	}
	repeatedQueue, err := dieterClient.SendMessage(routed, queuedRequest)
	if err != nil || repeatedQueue.GetMessageId() != queued.GetMessageId() || !repeatedQueue.GetQueued() {
		t.Fatalf("repeat post-reconnect message first=%#v repeated=%#v err=%v", queued, repeatedQueue, err)
	}
	conversation, err := boardStore.Conversations.Get(created.GetId())
	if err != nil {
		t.Fatal(err)
	}
	queuedCopies := 0
	for _, message := range conversation.Queue {
		if message.ID == queued.GetMessageId() {
			queuedCopies++
		}
	}
	if queuedCopies != 1 {
		t.Fatalf("post-reconnect message copies=%d, want 1", queuedCopies)
	}
	select {
	case <-runner.Canceled:
		t.Fatal("reconnection canceled the daemon-owned agent turn")
	default:
	}
	runner.Release()
	// Each completed runner is followed by the daemon's bounded workspace
	// refresh before the queued turn starts or the durable runtime projection
	// becomes idle. Under the parallel race suite those two serial refreshes can
	// legitimately exceed the short event waits used above, so wait within the
	// lifecycle's own bounds instead of failing during final persistence.
	deadline := time.Now().Add(35 * time.Second)
	for time.Now().Before(deadline) {
		resolved, resolveErr := boardStore.Kanban.ResolveCard(created.GetId())
		latestConversation, conversationErr := boardStore.Conversations.Get(created.GetId())
		if resolveErr == nil && conversationErr == nil && resolved.Runtime == "idle" && len(latestConversation.Queue) == 0 && runner.Completed.Load() >= 2 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	resolved, resolveErr := boardStore.Kanban.ResolveCard(created.GetId())
	conversation, conversationErr := boardStore.Conversations.Get(created.GetId())
	if resolveErr != nil || conversationErr != nil || resolved.Runtime != "idle" || len(conversation.Queue) != 0 || runner.Completed.Load() < 2 {
		t.Fatalf("daemon-owned turns did not finish after release: runtime=%q queue=%d completed=%d resolveErr=%v conversationErr=%v", resolved.Runtime, len(conversation.Queue), runner.Completed.Load(), resolveErr, conversationErr)
	}
}

func TestGatewayUnenrollsDaemonOnlyWithItsSignature(t *testing.T) {
	t.Parallel()
	f := startRelayFixture(t)
	ctx, authorized, identity := f.ctx, f.authorized, f.daemon.Identity
	gatewayStore, gatewayServer := f.gateway.Store, f.gateway.Server
	gatewayClient := gatewayv1Client(f.connection)

	if _, err := gatewayClient.UnenrollDaemon(ctx, &gatewayv1.UnenrollDaemonRequest{
		DaemonId: identity.ID, Nonce: make([]byte, 32), Signature: make([]byte, 64),
	}); err == nil {
		t.Fatal("unsigned daemon unenrollment unexpectedly succeeded")
	}
	if record, err := gatewayStore.Daemon(identity.ID); err != nil || record.Revoked {
		t.Fatalf("invalid unenrollment changed daemon record=%#v err=%v", record, err)
	}
	if err := link.Unenroll(ctx, identity); err != nil {
		t.Fatal(err)
	}
	// A repeated signed request is safe if the gateway committed revocation but
	// the command did not receive its response or clear the local credential.
	if err := link.Unenroll(ctx, identity); err != nil {
		t.Fatalf("repeat daemon unenrollment: %v", err)
	}
	deadline := time.Now().Add(testkit.Budget(30 * time.Second))
	for gatewayServer.Hub.Online(identity.ID) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	record, err := gatewayStore.Daemon(identity.ID)
	if err != nil || !record.Revoked || gatewayServer.Hub.Online(identity.ID) {
		t.Fatalf("unenrolled daemon record=%#v online=%v err=%v", record, gatewayServer.Hub.Online(identity.ID), err)
	}
	list, err := gatewayClient.ListDaemons(authorized, &emptypb.Empty{})
	if err != nil || len(list.GetDaemons()) != 0 {
		t.Fatalf("unenrolled daemon remained discoverable: %#v err=%v", list, err)
	}
	// The client reads this identity on reconnect; join it before mutating the
	// credential so unenrollment cleanup cannot race its next handshake.
	f.daemon.StopTunnel()
	if err := identity.ClearCredential(); err != nil {
		t.Fatal(err)
	}
	reloaded, err := link.LoadIdentity(identity.Root)
	if err != nil || reloaded.Enrolled() || len(reloaded.PrivateKey) == 0 {
		t.Fatalf("cleared local enrollment=%#v err=%v", reloaded, err)
	}
}

func TestGatewayDetectsBlackholedTunnelAndReconnects(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()
	var tunnelProxy *pauseProxy
	g := topology.StartGateway(t, topology.GatewayOptions{Accounts: []int64{owner}, Configure: func(config *gateway.Config) {
		tunnelProxy = startPauseProxy(t, config)
	}})
	var events <-chan link.GatewayEvent
	daemon := topology.StartDaemon(t, g, topology.DaemonOptions{Name: "Blackhole test machine", Account: owner, Tunnel: func(tunnel *link.GatewayClient) {
		// Only transport liveness runs under these accelerated deadlines. Allow
		// seconds of scheduling/SQLite slack even here, then check exact failures
		// with bounded event waits instead of retrying a failed relay operation.
		tunnel.Timing = link.GatewayTiming{
			HeartbeatActiveInterval: 100 * time.Millisecond, HeartbeatIdleMaxInterval: 100 * time.Millisecond,
			HeartbeatAckTimeout: 3 * time.Second, HandshakeTimeout: 3 * time.Second,
			ReconnectInitialBackoff: 20 * time.Millisecond, ReconnectMaximumBackoff: 50 * time.Millisecond,
			ReconnectStableAfter: 200 * time.Millisecond,
		}
		events = recordGatewayEvents(t, tunnel)
	}})
	boardStore := daemon.Store
	client := dieterclient.New(topology.Dial(t, g))
	routed := topology.Routed(ctx, topology.SignIn(t, g, owner, "owner"), daemon.Identity.ID)

	waitForGatewayEvent(t, events, link.GatewayConnected, 10*time.Second)
	if health, err := client.Health(routed, &emptypb.Empty{}); err != nil || health.GetStorePath() != boardStore.Root {
		t.Fatalf("initial relay health=%#v err=%v", health, err)
	}
	// Leave both sockets open while withholding bytes in both directions.
	// This exercises stuck Send/Recv and cannot be replaced by CloseDaemon.
	tunnelProxy.Pause()
	disconnected := waitForGatewayEvent(t, events, link.GatewayDisconnected, 10*time.Second)
	if !strings.Contains(disconnected.Error, "heartbeat acknowledgement timed out") {
		t.Fatalf("half-open tunnel error=%q", disconnected.Error)
	}
	handshakeFailure := waitForGatewayEvent(t, events, link.GatewayDisconnected, 10*time.Second)
	if !strings.Contains(handshakeFailure.Error, "gateway handshake timed out") {
		t.Fatalf("blackholed reconnect error=%q", handshakeFailure.Error)
	}
	tunnelProxy.Resume()
	waitForGatewayEvent(t, events, link.GatewayConnected, 10*time.Second)
	if health, err := client.Health(routed, &emptypb.Empty{}); err != nil || health.GetStorePath() != boardStore.Root {
		t.Fatalf("reconnected relay health=%#v err=%v", health, err)
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
	t.Parallel()
	g := topology.StartGateway(t, topology.GatewayOptions{Accounts: []int64{owner}})
	connection := topology.Dial(t, g)
	authorized := topology.Authorized(t.Context(), topology.SignIn(t, g, owner, "owner"))
	var daemons []*topology.Daemon
	for _, name := range []string{"Studio Mac", "Build server"} {
		daemons = append(daemons, topology.StartDaemon(t, g, topology.DaemonOptions{Name: name, Account: owner}))
	}
	for _, daemon := range daemons {
		routed := metadata.AppendToOutgoingContext(authorized, "x-dieter-daemon-id", daemon.Identity.ID)
		health, err := dieterclient.New(connection).Health(routed, &emptypb.Empty{})
		if err != nil || health.GetStorePath() != daemon.Store.Root {
			t.Fatalf("relay %q health=%#v err=%v", daemon.Identity.Name, health, err)
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
		if item.GetCompatibility() != gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_COMPATIBLE {
			t.Fatalf("machine %q compatibility=%v", item.GetName(), item.GetCompatibility())
		}
	}

	daemons[0].StopTunnel()
	testkit.Eventually(t, 5*time.Second, func() bool { return !g.Server.Hub.Online(daemons[0].Identity.ID) }, "%s to go offline", daemons[0].Identity.Name)
	if !g.Server.Hub.Online(daemons[1].Identity.ID) {
		t.Fatal("daemon presence was not independent")
	}
}

type pauseProxy struct {
	listener net.Listener
	target   string
	paused   atomic.Bool
	done     chan struct{}
	close    sync.Once
	mu       sync.Mutex
	conns    map[net.Conn]struct{}
}

func newPauseProxy(listener net.Listener, target string) *pauseProxy {
	return &pauseProxy{listener: listener, target: target, done: make(chan struct{}), conns: map[net.Conn]struct{}{}}
}

func (p *pauseProxy) Serve() {
	for {
		client, err := p.listener.Accept()
		if err != nil {
			return
		}
		go p.handle(client)
	}
}

func (p *pauseProxy) handle(client net.Conn) {
	upstream, err := net.Dial("tcp", p.target)
	if err != nil {
		_ = client.Close()
		return
	}
	p.track(client, upstream)
	defer p.untrack(client, upstream)
	finished := make(chan struct{}, 2)
	go func() {
		p.forward(upstream, client)
		finished <- struct{}{}
	}()
	go func() {
		p.forward(client, upstream)
		finished <- struct{}{}
	}()
	<-finished
	_ = client.Close()
	_ = upstream.Close()
	<-finished
}

func (p *pauseProxy) forward(destination, source net.Conn) {
	buffer := make([]byte, 32<<10)
	for {
		count, err := source.Read(buffer)
		if count > 0 {
			for p.paused.Load() {
				select {
				case <-p.done:
					return
				case <-time.After(2 * time.Millisecond):
				}
			}
			written := 0
			for written < count {
				n, writeErr := destination.Write(buffer[written:count])
				if writeErr != nil {
					return
				}
				written += n
			}
		}
		if err != nil {
			return
		}
	}
}

func (p *pauseProxy) track(connections ...net.Conn) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, connection := range connections {
		p.conns[connection] = struct{}{}
	}
}

func (p *pauseProxy) untrack(connections ...net.Conn) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, connection := range connections {
		delete(p.conns, connection)
	}
}

func (p *pauseProxy) Pause()  { p.paused.Store(true) }
func (p *pauseProxy) Resume() { p.paused.Store(false) }

func (p *pauseProxy) Close() {
	p.close.Do(func() {
		close(p.done)
		_ = p.listener.Close()
		p.mu.Lock()
		defer p.mu.Unlock()
		for connection := range p.conns {
			_ = connection.Close()
		}
	})
}

type tunnelSurvivalRunner struct {
	Started   chan struct{}
	Canceled  chan struct{}
	Completed atomic.Int32
	release   chan struct{}
	start     sync.Once
	cancel    sync.Once
	finish    sync.Once
}

func newTunnelSurvivalRunner() *tunnelSurvivalRunner {
	return &tunnelSurvivalRunner{Started: make(chan struct{}), Canceled: make(chan struct{}), release: make(chan struct{})}
}

func (r *tunnelSurvivalRunner) Run(ctx context.Context, request harness.Request, emit func(harness.Output) error) error {
	defer r.Completed.Add(1)
	for _, chunk := range []string{
		`{"type":"start","messageId":"` + request.ResponseMessageID + `"}`,
		`{"type":"text-start","id":"text_live"}`,
		`{"type":"text-delta","id":"text_live","delta":"working"}`,
	} {
		if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
			return err
		}
	}
	r.start.Do(func() { close(r.Started) })
	select {
	case <-ctx.Done():
		r.cancel.Do(func() { close(r.Canceled) })
		return ctx.Err()
	case <-r.release:
		for _, chunk := range []string{
			`{"type":"text-end","id":"text_live"}`,
			`{"type":"finish","finishReason":"stop"}`,
		} {
			if err := emit(harness.Output{Type: "chunk", Chunk: json.RawMessage(chunk)}); err != nil {
				return err
			}
		}
		return nil
	}
}

func (r *tunnelSurvivalRunner) Release() {
	r.finish.Do(func() { close(r.release) })
}

func waitForGatewayEvent(t *testing.T, events <-chan link.GatewayEvent, state string, timeout time.Duration) link.GatewayEvent {
	t.Helper()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	for {
		select {
		case event := <-events:
			if event.State == state {
				return event
			}
		case <-timer.C:
			t.Fatalf("gateway did not report state %q within %s", state, timeout)
			return link.GatewayEvent{}
		}
	}
}

func testRemoteDesktopThroughGateway(t *testing.T, routed context.Context, client dieterclient.Client, rtc *gatewayv1.RTCConfiguration, identity *link.Identity, manager *remotedesktop.Manager) {
	t.Helper()
	settings := webrtc.SettingEngine{}
	settings.SetIncludeLoopbackCandidate(true)
	// Both peers are local test fixtures. Do not let physical/VPN interfaces
	// or external IPv6 routes determine whether relayed signaling succeeds.
	settings.SetNetworkTypes([]webrtc.NetworkType{webrtc.NetworkTypeUDP4})
	settings.SetInterfaceFilter(func(name string) bool { return name == "lo0" || name == "lo" })
	viewer, err := webrtc.NewAPI(webrtc.WithSettingEngine(settings)).NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer viewer.Close()
	if _, err := viewer.AddTransceiverFromKind(webrtc.RTPCodecTypeVideo, webrtc.RTPTransceiverInit{Direction: webrtc.RTPTransceiverDirectionRecvonly}); err != nil {
		t.Fatal(err)
	}
	ordered := true
	stateChannel, err := viewer.CreateDataChannel("dieter-input-state-v"+remotedesktop.InputProtocolVersionString, &webrtc.DataChannelInit{Ordered: &ordered})
	if err != nil {
		t.Fatal(err)
	}
	unordered := false
	zero := uint16(0)
	if _, err := viewer.CreateDataChannel("dieter-pointer-v"+remotedesktop.InputProtocolVersionString, &webrtc.DataChannelInit{Ordered: &unordered, MaxRetransmits: &zero}); err != nil {
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
	case <-time.After(testkit.Budget(30 * time.Second)):
		t.Fatal("viewer ICE gathering timed out")
	}
	offer = *viewer.LocalDescription()
	request := &dieterv1.StartRemoteDesktopRequest{InputProtocolVersion: remotedesktop.InputProtocolVersion,
		ClientNonce: "gateway-e2e-nonce", RtcConfiguration: rtc,
		Offer:     &dieterv1.RemoteDesktopSessionDescription{Type: "offer", Sdp: offer.SDP},
		DisplayId: "primary", Control: true, MaxFps: 10, MaxBitrateKbps: 500,
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
			channelDeadline := time.Now().Add(time.Second)
			for stateChannel.ReadyState() != webrtc.DataChannelStateOpen && time.Now().Before(channelDeadline) {
				time.Sleep(10 * time.Millisecond)
			}
			if !binding.GetControlGranted() || stateChannel.ReadyState() != webrtc.DataChannelStateOpen {
				t.Fatalf("relayed control channel was not authorized and open: binding=%#v state=%v", binding, stateChannel.ReadyState())
			}
			// Model an ungraceful viewer disappearance. Canceling the gateway
			// stream must cancel the relayed local RPC, detach its subscription,
			// and stop the host capture without relying on CloseRemoteDesktop.
			cancelStream()
			deadline := time.Now().Add(testkit.Budget(30 * time.Second))
			for manager.Capabilities().GetActiveSession() && time.Now().Before(deadline) {
				time.Sleep(10 * time.Millisecond)
			}
			if manager.Capabilities().GetActiveSession() {
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
				message := remotedesktop.SessionBindingMessage(sessionID, request.GetClientNonce(), binding.GetHelperDtlsFingerprint(), binding.GetExpiresAt(), offerHash[:], binding.GetControlGranted(), binding.GetDisplayId(), binding.GetInputProtocolVersion(), binding.GetInputEpoch())
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

// Keep all generated gateway references in one place so the test exercises
// the exact native gRPC surface used by macOS and Android.
func gatewayv1Client(connection *grpc.ClientConn) gatewayv1.GatewayServiceClient {
	return gatewayv1.NewGatewayServiceClient(connection)
}
