//go:build e2e

package cli

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/api"
	"github.com/dbpprt/dieter/internal/gateway"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/peersync"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/security/linkauth"
	"github.com/dbpprt/dieter/internal/security/localauth"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/testkit/topology"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
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
	t.Parallel()
	for _, route := range []string{"direct-tls", "webrtc-direct", "webrtc-turn", "relay"} {
		t.Run(route, func(t *testing.T) {
			t.Parallel()
			testPeerMachines(t, route)
		})
	}
}
func testPeerMachines(t *testing.T, wantRoute string) {
	ctx, cancel := context.WithTimeout(t.Context(), 90*time.Second)
	defer cancel()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	const issuer = "https://durable-gateway.example.test"
	g := topology.StartGateway(t, topology.GatewayOptions{Accounts: []int64{42, 43}, Issuer: issuer, Configure: func(config *gateway.Config) {
		if wantRoute != "webrtc-turn" {
			return
		}
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
		t.Cleanup(func() { _ = turnServer.Close() })
	}})
	a, b, other := topology.Machine(t, g, "A", 42), topology.Machine(t, g, "B", 42), topology.Machine(t, g, "Other", 43)
	scope := crdt.Revision([]string{issuer, "github:42"})
	sa, sb := store.New(a.Root), store.New(b.Root)
	ba, err := sa.BindPeerAccount(scope, "github:42", a.ID, a.Issuer())
	if err != nil {
		t.Fatal(err)
	}
	bb, err := sb.BindPeerAccount(scope, "github:42", b.ID, b.Issuer())
	if err != nil {
		t.Fatal(err)
	}
	rtc := wantRoute == "webrtc-direct" || wantRoute == "webrtc-turn"
	daemonB := topology.StartDaemon(t, g, topology.DaemonOptions{
		Identity: b, Store: sb, Direct: wantRoute == "direct-tls", ControlWebRTC: rtc,
		API: api.Options{Runner: newFakeRunner(), Catalog: testkit.MockCatalog()}, Logger: logger,
	})
	left, err := sa.PutPeerRecord(ba, "project-settings", "shared", "", []byte(`{"name":"From A"}`), false)
	if err != nil {
		t.Fatal(err)
	}
	_, err = sb.PutPeerRecord(bb, "project-settings", "shared", "", []byte(`{"name":"From B"}`), false)
	if err != nil {
		t.Fatal(err)
	}
	runner := &peersync.PeerSync{Identity: a, Store: sa, RelayOnly: wantRoute == "webrtc-turn"}
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
	if da.LastRoute != wantRoute || crdt.Revision(da.State) != crdt.Revision(db.State) || len(da.Records["project-settings/shared"].Versions) != 2 {
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
	cliRoot := store.New(a.Root)
	client := New(cliRoot.Root)

	client.Machine = b.ID
	client.GatewayURL = g.URL
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

	// Exercise the public KV consumer and watch over each authenticated route.
	if err = os.WriteFile(file, []byte(`"Research"`), 0600); err != nil {
		t.Fatal(err)
	}
	output.Reset()
	if err = client.Run([]string{"kv", "put", "--namespace", "navigation", "--key", "projects-folder.fixture.name", "--file", file, "--operation", "kv-create"}); err != nil {
		t.Fatal(err)
	}
	var entry dieterv1.KVEntry
	if err = protojson.Unmarshal(output.Bytes(), &entry); err != nil {
		t.Fatal(err)
	}
	output.Reset()
	if err = client.Run([]string{"kv", "watch", "--namespace", "navigation", "--count", "1"}); err != nil {
		t.Fatal(err)
	}
	var frame dieterv1.KVFrame
	if err = protojson.Unmarshal(output.Bytes(), &frame); err != nil || !frame.GetReset_() || len(frame.GetEntries()) != 1 {
		t.Fatal(output.String(), err)
	}
	output.Reset()
	if err = client.Run([]string{"kv", "move", "--namespace", "navigation", "--key", "projects-folder.fixture.position", "--operation", "kv-move"}); err != nil {
		t.Fatal(err)
	}
	output.Reset()
	if err = client.Run([]string{"kv", "delete", "--namespace", "navigation", "--key", entry.Key, "--revision", entry.Revision, "--operation", "kv-delete"}); err != nil {
		t.Fatal(err)
	}
	if err = runner.Round(ctx); err != nil {
		t.Fatal(err)
	}
	shared, e := sa.PeerData(scope)
	if e != nil || !schema.SelectedKV(shared.Records["kv.navigation/projects-folder.fixture.name"]).Deleted {
		t.Fatal(shared, e)
	}
	// Real raw local API, with only the local token, has the same record view.
	local, err := grpc.NewClient(daemonB.Address, grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithPerRPCCredentials(localauth.FileCredentials{Root: sb.Root}))
	if err != nil {
		t.Fatal(err)
	}
	defer local.Close()
	if _, err = dieterclient.New(local).ListPeerRecords(ctx, &dieterv1.PeerSnapshotRequest{}); err != nil {
		t.Fatal(err)
	}

	// One logical project over real transports: attach a second machine, edit
	// from its replica, and keep all execution/file operations on their owner.
	if _, err := sa.CreateProject(store.CreateProjectInput{Name: "aaa-default", Path: initTestRepository(t, "default"), InitialBoardName: "Main"}); err != nil {
		t.Fatal(err)
	}
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
	// Persist a real owner-signed pre-removal summary. Sync must validate its
	// original bytes and proof, including when the owner is later offline.
	beforeLegacy, err := sa.PeerData(scope)
	if err != nil {
		t.Fatal(err)
	}
	oldSummary := beforeLegacy.Records[crdt.Key("item", ownedA.ID+".summary")]
	var legacyFields map[string]json.RawMessage
	if err := json.Unmarshal(oldSummary.Versions[0].Value, &legacyFields); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"responseSeq", "responseMessageId", "seenResponseSeq"} {
		delete(legacyFields, field)
	}
	legacyFields["commentCount"] = json.RawMessage("0")
	legacyJSON, _ := json.Marshal(legacyFields)
	legacyRecord, err := sa.PutPeerRecord(ba, "item", oldSummary.ID, oldSummary.Revision(), legacyJSON, false)
	if err != nil || len(legacyRecord.Versions[0].Provenance) == 0 {
		t.Fatalf("signed legacy summary: %v", err)
	}
	if err = runner.Round(ctx); err != nil {
		t.Fatal(err)
	}
	afterLegacy, err := sb.PeerData(scope)
	if err != nil || afterLegacy.Records[crdt.Key("item", oldSummary.ID)].Revision() != legacyRecord.Revision() {
		t.Fatalf("legacy summary changed in transit: %v", err)
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
	runDaemonCLI(t, client, &output, "board", "show", board.ID)
	assertBoardRetirementCLI(t, client, &output, project.ID)
	localAPIForProjects := dieterclient.New(local)
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
	for n := 0; n <= crdt.PageSize; n++ {
		if _, err = sb.PutPeerRecord(bb, "project-settings", "page_"+strconv.Itoa(n), "", []byte(`{"name":"Paged"}`), false); err != nil {
			t.Fatal(err)
		}
	}
	localAPI := dieterclient.New(local)
	first, err := localAPI.ListPeerRecords(ctx, &dieterv1.PeerSnapshotRequest{})
	if err != nil || first.GetNextKey() == "" {
		t.Fatal(first, err)
	}
	// CLI pagination uses the same bounded SQL snapshots over every routed
	// transport. The native clients use this core through the Connect adapter.
	output.Reset()
	if err = client.Run([]string{"peer", "list"}); err != nil {
		t.Fatal(err)
	}
	var routedFirst dieterv1.PeerSnapshot
	if err = protojson.Unmarshal(output.Bytes(), &routedFirst); err != nil || len(routedFirst.Records) != crdt.PageSize || routedFirst.NextKey == "" {
		t.Fatalf("routed first page: %v", err)
	}
	output.Reset()
	if err = client.Run([]string{"peer", "list", "--after", routedFirst.NextKey, "--snapshot", routedFirst.SnapshotRevision}); err != nil {
		t.Fatal(err)
	}
	var routedNext dieterv1.PeerSnapshot
	if err = protojson.Unmarshal(output.Bytes(), &routedNext); err != nil || len(routedNext.Records) == 0 {
		t.Fatalf("routed continuation: %v", err)
	}
	if crdt.Key(routedNext.Records[0].Kind, routedNext.Records[0].Id) <= routedFirst.NextKey {
		t.Fatal("routed continuation repeated a record")
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
	gatewayConn, err := grpc.NewClient(g.Address, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer gatewayConn.Close()
	gw := gatewayv1.NewGatewayServiceClient(gatewayConn)
	auth := func(i *link.Identity) context.Context {
		return metadata.AppendToOutgoingContext(ctx,
			"authorization", "Bearer "+linkauth.SignPeer(i.PrivateKey, i.ID, i.Issuer(), i.Generation, time.Now()),
			"x-dieter-client-version", "0.4.1-dev",
		)
	}
	if _, err = gw.ResolveDaemonRoute(auth(other), &gatewayv1.DaemonRef{DaemonId: b.ID}); status.Code(err) != codes.NotFound {
		t.Fatalf("cross-account route: %v", err)
	}
	if _, err = g.Store.RevokeDaemon(a.ID, 42); err != nil {
		t.Fatal(err)
	}
	if _, err = gw.GetAccount(auth(a), &emptypb.Empty{}); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("revoked proof: %v", err)
	}
	if err = runner.Round(ctx); err == nil {
		t.Fatal("revoked daemon synchronized")
	}
}
