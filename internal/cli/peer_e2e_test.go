package cli

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/controlrtc"
	"github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/gateway"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/linkauth"
	"github.com/dbpprt/dieter/internal/peerstore"
	"github.com/dbpprt/dieter/internal/server"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/pion/turn/v5"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/types/known/emptypb"
)

func TestPeerMachineSynchronizationRoutes(t *testing.T) {
	t.Setenv("DIETER_ENABLE_MOCK_HARNESS", "1")
	for _, route := range []string{"direct-tls", "webrtc-direct", "webrtc-turn", "relay"} {
		t.Run(route, func(t *testing.T) { testPeerMachines(t, route) })
	}
}
func testPeerMachines(t *testing.T, wantRoute string) {
	ctx, cancel := context.WithTimeout(t.Context(), 90*time.Second)
	defer cancel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	origin, _ := url.Parse("http://" + listener.Addr().String())
	config := gateway.Config{Root: t.TempDir(), Address: listener.Addr().String(), PublicURL: origin, GitHubClientID: "test", GitHubSecret: "test", AllowedUserIDs: map[int64]struct{}{42: {}, 43: {}}, AuthSecret: []byte("0123456789abcdef0123456789abcdef"), SessionTTL: time.Hour, NativeRedirects: map[string]struct{}{}, GitHubBaseURL: "https://github.invalid", GitHubAPIURL: "https://api.github.invalid", DevInsecure: true, RTCTTL: 5 * time.Minute}
	if wantRoute == "webrtc-turn" {
		socket, e := net.ListenPacket("udp4", "127.0.0.1:0")
		if e != nil {
			t.Fatal(e)
		}
		config.RTCTURNSecret = []byte("peer-turn-secret")
		config.RTCTURNURLs = []string{"turn:" + socket.LocalAddr().String() + "?transport=udp"}
		turnServer, e := turn.NewServer(turn.ServerConfig{Realm: "peer-test", AuthHandler: func(r *turn.RequestAttributes) (string, []byte, bool) {
			mac := hmac.New(sha1.New, []byte(config.RTCTURNSecret))
			mac.Write([]byte(r.Username))
			password := base64.StdEncoding.EncodeToString(mac.Sum(nil))
			return r.Username, turn.GenerateAuthKey(r.Username, r.Realm, password), true
		}, PacketConnConfigs: []turn.PacketConnConfig{{PacketConn: socket, RelayAddressGenerator: &turn.RelayAddressGeneratorStatic{RelayAddress: net.ParseIP("127.0.0.1"), Address: "127.0.0.1"}}}})
		if e != nil {
			t.Fatal(e)
		}
		defer turnServer.Close()
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
	go func() { _ = gatewayServer.Serve(listener) }()
	defer gatewayServer.APIGRPC.Stop()
	defer gatewayServer.RelayGRPC.Stop()
	enroll := func(name string, account int64) *daemon.Identity {
		t.Helper()
		identity, e := daemon.LoadOrCreateEnrollmentIdentity(t.TempDir(), name, origin.String())
		if e != nil {
			t.Fatal(e)
		}
		enrollment, e := daemon.BeginEnrollment(ctx, identity)
		if e != nil {
			t.Fatal(e)
		}
		if e = gatewayStore.ApproveEnrollment(enrollment.GetEnrollmentId(), enrollment.GetUserCode(), account, "owner"); e != nil {
			t.Fatal(e)
		}
		credential, e := daemon.CompleteEnrollment(ctx, identity, enrollment.GetEnrollmentId(), enrollment.GetEnrollmentSecret())
		if e != nil {
			t.Fatal(e)
		}
		if e = identity.SaveCredential(credential.GetDaemonId(), credential.GetDaemonName(), credential.GetCertificatePem(), credential.GetDaemonCaPem(), credential.GetGatewaySigningPublicKey(), credential.GetExpiresAt(), credential.GetGeneration()); e != nil {
			t.Fatal(e)
		}
		return identity
	}
	a, b, other := enroll("A", 42), enroll("B", 42), enroll("Other", 43)
	scope := peerstore.Revision([]string{origin.String(), "github:42"})
	sa, sb := store.New(a.Root), store.New(b.Root)
	ba, err := sa.BindPeerAccount(scope, "github:42", a.ID, a.GatewayURL)
	if err != nil {
		t.Fatal(err)
	}
	bb, err := sb.BindPeerAccount(scope, "github:42", b.ID, b.GatewayURL)
	if err != nil {
		t.Fatal(err)
	}
	localListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	direct, err := newDaemonDirectRoute(b, localListener.Addr().String(), "peer-test", "127.0.0.1:0", "127.0.0.1", "loopback", 1000)
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = direct.server.Serve(direct.listener) }()
	defer direct.server.Stop()
	defer direct.listener.Close()
	var control *controlrtc.Manager
	rtc := wantRoute == "webrtc-direct" || wantRoute == "webrtc-turn"
	if rtc {
		control = controlrtc.New(controlrtc.Identity{DaemonID: b.ID, GatewayURL: b.GatewayURL, Generation: b.Generation, GatewaySigningPublicKey: b.GatewaySigningPublicKey}, direct.listener.Addr().String())
		defer control.Close()
	}
	application := server.NewWithOptions(sb, logger, server.Options{ControlRTC: control, Runner: &fakeRunner{}})
	httpServer := &http.Server{Handler: application.Handler()}
	go func() { _ = httpServer.Serve(localListener) }()
	defer httpServer.Close()
	var routes []*gatewayv1.DirectCandidate
	if wantRoute == "direct-tls" {
		routes = []*gatewayv1.DirectCandidate{direct.candidate}
	}
	tunnelCtx, stopTunnel := context.WithCancel(ctx)
	defer stopTunnel()
	tunnelDone := make(chan struct{})
	go func() {
		defer close(tunnelDone)
		_ = (&daemon.GatewayClient{Identity: b, LocalTarget: localListener.Addr().String(), Version: "test", APIVersion: server.APIVersion, Routes: routes, ControlWebRTC: rtc, Log: logger}).Run(tunnelCtx)
	}()
	defer func() { stopTunnel(); <-tunnelDone }()
	deadline := time.Now().Add(5 * time.Second)
	for !gatewayServer.Hub.Online(b.ID) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !gatewayServer.Hub.Online(b.ID) {
		t.Fatal("peer not connected")
	}
	left, err := sa.PutPeerRecord(ba, "project-settings", "shared", "", []byte(`{"name":"From A"}`), false)
	if err != nil {
		t.Fatal(err)
	}
	_, err = sb.PutPeerRecord(bb, "project-settings", "shared", "", []byte(`{"name":"From B"}`), false)
	if err != nil {
		t.Fatal(err)
	}
	runner := &daemon.PeerSync{Identity: a, Store: sa, RelayOnly: wantRoute == "webrtc-turn"}
	if err = runner.Round(ctx); err != nil {
		t.Fatal(err)
	}
	da, err := sa.PeerData(scope)
	if err != nil {
		t.Fatal(err)
	}
	db, err := sb.PeerData(scope)
	if err != nil {
		t.Fatal(err)
	}
	if da.LastRoute != wantRoute || peerstore.Revision(da.State) != peerstore.Revision(db.State) || len(da.Records["project-settings/shared"].Versions) != 2 {
		t.Fatalf("route=%s wanted=%s A=%+v B=%+v", da.LastRoute, wantRoute, da.State, db.State)
	}
	if _, err = sa.PutPeerRecord(ba, "project-settings", "shared", left.Revision(), []byte(`{}`), false); err == nil {
		t.Fatal("stale write accepted")
	}
	resolved, err := sa.PutPeerRecord(ba, "project-settings", "shared", da.Records["project-settings/shared"].Revision(), []byte(`{"name":"Resolved"}`), false)
	if err != nil {
		t.Fatal(err)
	}
	// A fresh runner/store instance proves durable restart/catch-up without a client.
	runner.Store = store.New(a.Root)
	if err = runner.Round(ctx); err != nil {
		t.Fatal(err)
	}
	db, err = sb.PeerData(scope)
	if err != nil || db.Records["project-settings/shared"].Revision() != resolved.Revision() {
		t.Fatal(db, err)
	}
	// Exercise the actual CLI over local and routed transports.
	cliRoot := store.New(t.TempDir())
	proof := linkauth.SignPeer(a.PrivateKey, a.ID, a.GatewayURL, a.Generation, time.Now())
	if err = saveClientConfig(cliRoot.Root, clientConfig{DefaultGateway: origin.String(), Sessions: map[string]clientSession{origin.String(): {AccessToken: proof, ExpiresAt: time.Now().Add(time.Minute).Format(time.RFC3339Nano), Login: "owner"}}}); err != nil {
		t.Fatal(err)
	}
	client := New(cliRoot)
	client.DaemonMode = true
	client.Machine = b.ID
	client.GatewayURL = origin.String()
	client.Timeout = 15 * time.Second
	var output bytes.Buffer
	client.Out = &output
	client.Err = &output
	if err = client.Run([]string{"peer", "status"}); err != nil {
		t.Fatal(err)
	}
	var peerStatus dieterv1.PeerStoreStatus
	if err = protojson.Unmarshal(output.Bytes(), &peerStatus); err != nil || peerStatus.GetAccount() != scope {
		t.Fatal(output.String(), err)
	}
	file := filepath.Join(t.TempDir(), "settings.json")
	if err = os.WriteFile(file, []byte(`{"projectId":"shared","name":"Board"}`), 0600); err != nil {
		t.Fatal(err)
	}
	output.Reset()
	if err = client.Run([]string{"peer", "put", "--kind", "board-settings", "--id", "board", "--file", file}); err != nil {
		t.Fatal(err)
	}
	var card dieterv1.PeerRecord
	if err = protojson.Unmarshal(output.Bytes(), &card); err != nil {
		t.Fatal(err)
	}
	output.Reset()
	if err = client.Run([]string{"peer", "delete", "--kind", "board-settings", "--id", "board", "--revision", card.GetRevision()}); err != nil {
		t.Fatal(err)
	}
	// Real raw local API, with no remote credentials, has the same record view.
	local, err := grpc.NewClient(localListener.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer local.Close()
	if _, err = dieterv1.NewDieterServiceClient(local).ListPeerRecords(ctx, &dieterv1.PeerSnapshotRequest{}); err != nil {
		t.Fatal(err)
	}

	// One logical project over real transports: attach a second machine, edit
	// from its replica, and keep all execution/file operations on their owner.
	project, err := sa.CreateProject(store.CreateProjectInput{Name: "Shared repo", Path: initTestRepository(t, "owner-a"), InitialBoardName: "Main"})
	if err != nil {
		t.Fatal(err)
	}
	board, err := sa.InitialBoard(project.ID)
	if err != nil {
		t.Fatal(err)
	}
	ownedA, err := sa.CreateChat(store.CreateCardInput{Project: project.ID, Title: "A conversation", WorkspaceMode: "project"})
	if err != nil {
		t.Fatal(err)
	}
	if err = runner.Round(ctx); err != nil {
		t.Fatal(err)
	}
	output.Reset()
	pathB := initTestRepository(t, "owner-b")
	if err = client.Run([]string{"project", "attach", "--name", "B checkout", project.ID, pathB}); err != nil {
		t.Fatal(err)
	}
	var checkout dieterv1.Checkout
	if err = protojson.Unmarshal(output.Bytes(), &checkout); err != nil {
		t.Fatal(output.String(), err)
	}
	localAPIForProjects := dieterv1.NewDieterServiceClient(local)
	created, err := localAPIForProjects.CreateCard(ctx, &dieterv1.CreateConversationRequest{ProjectId: project.ID, BoardId: board.ID, CheckoutId: checkout.Id, Title: "B conversation", Prompt: "Draft only", WorkspaceMode: "project", DeferStart: true, Provider: "mock", Model: "mock", CommandId: "shared-project-card", ClientId: "peer-test"})
	if err != nil {
		t.Fatal(err)
	}
	repeated, err := localAPIForProjects.CreateCard(ctx, &dieterv1.CreateConversationRequest{ProjectId: project.ID, BoardId: board.ID, CheckoutId: checkout.Id, Title: "B conversation", Prompt: "Draft only", WorkspaceMode: "project", DeferStart: true, Provider: "mock", Model: "mock", CommandId: "shared-project-card", ClientId: "peer-test"})
	if err != nil || repeated.GetId() != created.GetId() {
		t.Fatalf("create receipt: %v %v", repeated, err)
	}
	if created.GetOwnerDaemonId() != b.ID || created.GetCheckoutId() != checkout.Id {
		t.Fatalf("execution destination: %v", created)
	}
	if _, err = localAPIForProjects.GetConversation(ctx, &dieterv1.GetConversationRequest{CardId: ownedA.ID}); err == nil {
		t.Fatal("non-owner read conversation")
	}
	output.Reset()
	if err = client.Run([]string{"file", "read", "--project", project.ID, "--checkout", checkout.Id, "README.md"}); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(output.Bytes(), []byte("initial")) {
		t.Fatal(output.String())
	}
	second, err := sb.AttachCheckout(project.ID, initTestRepository(t, "owner-b-second"), "Second B checkout")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = localAPIForProjects.ReadFile(ctx, &dieterv1.ReadFileRequest{ProjectId: project.ID, Path: "README.md"}); err == nil {
		t.Fatal("ambiguous checkout implicitly selected")
	}
	if _, err = localAPIForProjects.ReadFile(ctx, &dieterv1.ReadFileRequest{ProjectId: project.ID, CheckoutId: second.ID, Path: "README.md"}); err != nil {
		t.Fatal(err)
	}
	name := "Edited without project creator"
	if _, err = sb.UpdateProject(project.ID, &name, nil, nil); err != nil {
		t.Fatal(err)
	}
	if err = runner.Round(ctx); err != nil {
		t.Fatal(err)
	}
	mergedProject, err := sa.ResolveProject(project.ID)
	if err != nil || mergedProject.Name != name || len(mergedProject.Checkouts) != 3 {
		t.Fatalf("shared project: %+v %v", mergedProject, err)
	}
	if _, err = sa.CardDetail(created.GetId()); err == nil {
		t.Fatal("replication moved conversation ownership")
	}
	// Multi-page snapshots and unattended Run catch up without a native client.
	for n := 0; n <= peerstore.PageSize; n++ {
		if _, err = sb.PutPeerRecord(bb, "project-settings", "page_"+strconv.Itoa(n), "", []byte(`{"name":"Paged"}`), false); err != nil {
			t.Fatal(err)
		}
	}
	localAPI := dieterv1.NewDieterServiceClient(local)
	first, err := localAPI.ListPeerRecords(ctx, &dieterv1.PeerSnapshotRequest{})
	if err != nil || first.GetNextKey() == "" {
		t.Fatal(first, err)
	}
	if _, err = sb.PutPeerRecord(bb, "project-settings", "changed_page", "", []byte(`{}`), false); err != nil {
		t.Fatal(err)
	}
	if _, err = localAPI.ListPeerRecords(ctx, &dieterv1.PeerSnapshotRequest{AfterKey: first.GetNextKey(), SnapshotRevision: first.GetSnapshotRevision()}); status.Code(err) != codes.Aborted {
		t.Fatalf("stale page: %v", err)
	}
	if _, err = localAPI.MergePeerRecords(ctx, &dieterv1.MergePeerRecordsRequest{Account: "another-account"}); status.Code(err) != codes.PermissionDenied {
		t.Fatalf("account mismatch: %v", err)
	}
	background, stop := context.WithCancel(ctx)
	finished := make(chan struct{})
	runner.Interval = 100 * time.Millisecond
	runner.Log = logger
	go func() { defer close(finished); runner.Run(background) }()
	until := time.Now().Add(15 * time.Second)
	caughtUp := false
	for time.Now().Before(until) {
		data, e := sa.PeerData(scope)
		if e == nil && data.Records["project-settings/changed_page"].ID != "" {
			caughtUp = true
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	stop()
	<-finished
	if !caughtUp {
		t.Fatal("background sync did not catch up")
	}
	// Possession proof does not authorize another account or a revoked enrollment.
	gatewayConn, err := grpc.NewClient(listener.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer gatewayConn.Close()
	gw := gatewayv1.NewGatewayServiceClient(gatewayConn)
	auth := func(i *daemon.Identity) context.Context {
		return metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+linkauth.SignPeer(i.PrivateKey, i.ID, i.GatewayURL, i.Generation, time.Now()))
	}
	if _, err = gw.ResolveDaemonRoute(auth(other), &gatewayv1.DaemonRef{DaemonId: b.ID}); status.Code(err) != codes.NotFound {
		t.Fatalf("cross-account route: %v", err)
	}
	if _, err = gatewayStore.RevokeDaemon(a.ID, 42); err != nil {
		t.Fatal(err)
	}
	if _, err = gw.GetAccount(auth(a), &emptypb.Empty{}); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("revoked proof: %v", err)
	}
	if err = runner.Round(ctx); err == nil {
		t.Fatal("revoked daemon synchronized")
	}
}
