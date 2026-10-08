package gateway

import (
	"bytes"
	"context"
	"fmt"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/protobuf/proto"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/cli"
	"github.com/dbpprt/dieter/internal/daemon"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/linkauth"
	"github.com/dbpprt/dieter/internal/peerstore"
	"github.com/dbpprt/dieter/internal/relaypolicy"
	"github.com/dbpprt/dieter/internal/rpcraw"
	"github.com/dbpprt/dieter/internal/server"
	"github.com/dbpprt/dieter/internal/store"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/emptypb"
)

type relayFleet struct {
	gateway                  *Server
	target, source           *daemon.Identity
	targetStore, sourceStore *store.Store
	client                   dieterv1.DieterServiceClient
	context                  context.Context
	enroll                   func(string) *daemon.Identity
}

func newRelayFleet(t *testing.T, setup ...func(*Server)) *relayFleet {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 45*time.Second)
	t.Cleanup(cancel)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	origin, _ := url.Parse("http://" + listener.Addr().String())
	config := Config{Root: t.TempDir(), Address: listener.Addr().String(), PublicURL: origin, AllowedUserIDs: map[int64]struct{}{1234: {}}, AuthSecret: []byte("0123456789abcdef0123456789abcdef"), DevInsecure: true, SessionTTL: time.Hour}
	data, err := OpenStore(config.Root)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { data.Close() })
	g, err := NewServer(config, data, log)
	if err != nil {
		t.Fatal(err)
	}
	for _, configure := range setup {
		configure(g)
	}
	go func() { _ = g.Serve(listener) }()
	t.Cleanup(func() { g.APIGRPC.Stop(); g.RelayGRPC.Stop(); listener.Close() })
	enroll := func(name string) *daemon.Identity {
		id, err := daemon.LoadOrCreateEnrollmentIdentity(t.TempDir(), name, origin.String())
		if err != nil {
			t.Fatal(err)
		}
		e, err := daemon.BeginEnrollment(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		if err = data.ApproveEnrollment(e.EnrollmentId, e.UserCode, 1234, "test"); err != nil {
			t.Fatal(err)
		}
		c, err := daemon.CompleteEnrollment(ctx, id, e.EnrollmentId, e.EnrollmentSecret)
		if err != nil {
			t.Fatal(err)
		}
		id.GatewayIssuer = c.GatewayIssuer
		if err = id.SaveCredential(c.DaemonId, c.DaemonName, c.CertificatePem, c.DaemonCaPem, c.GatewaySigningPublicKey, c.ExpiresAt, c.Generation); err != nil {
			t.Fatal(err)
		}
		return id
	}
	target, source := enroll("target"), enroll("source")
	ts, ss := store.New(target.Root), store.New(source.Root)
	scope := peerstore.Revision([]string{target.Issuer(), "github:1234"})
	if _, err = ts.BindPeerAccount(scope, "github:1234", target.ID, target.Issuer()); err != nil {
		t.Fatal(err)
	}
	if _, err = ss.BindPeerAccount(scope, "github:1234", source.ID, source.Issuer()); err != nil {
		t.Fatal(err)
	}
	local, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	app := server.NewWithOptions(ts, log, server.Options{})
	httpServer := &http.Server{Handler: app.Handler()}
	go func() { _ = httpServer.Serve(local) }()
	t.Cleanup(func() { httpServer.Close() })
	tunnelCtx, stop := context.WithCancel(ctx)
	done := make(chan error, 1)
	tunnel := &daemon.GatewayClient{Identity: target, LocalTarget: local.Addr().String(), Version: "0.4.1-dev", Log: log, Timing: daemon.GatewayTiming{ReconnectInitialBackoff: 20 * time.Millisecond, ReconnectMaximumBackoff: 50 * time.Millisecond}}
	go func() { done <- tunnel.Run(tunnelCtx) }()
	t.Cleanup(func() {
		stop()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Error("tunnel workers did not stop")
		}
	})
	waitRelay(t, func() bool { return g.Hub.RelayReady(target.ID) }, "all authenticated lanes")
	conn, err := grpc.NewClient(listener.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	proof := linkauth.SignPeer(source.PrivateKey, source.ID, source.Issuer(), source.Generation, time.Now())
	authorized := metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+proof, "x-dieter-client-version", "0.4.1-dev", "x-dieter-daemon-id", target.ID)
	return &relayFleet{gateway: g, target: target, source: source, targetStore: ts, sourceStore: ss, client: dieterv1.NewDieterServiceClient(conn), context: authorized, enroll: enroll}
}
func waitRelay(t *testing.T, condition func() bool, what string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}
func (f *relayFleet) command(t *testing.T, args ...string) string {
	t.Helper()
	c := cli.New(f.sourceStore)
	c.Machine = f.target.ID
	c.Timeout = 3 * time.Second
	var out bytes.Buffer
	c.Out = &out
	c.Err = &out
	if err := c.Run(args); err != nil {
		t.Fatalf("CLI %v: %v (%s)", args, err, out.String())
	}
	return out.String()
}
func TestRelayFleetWatchSaturationPreservesCLIHealthAndReplication(t *testing.T) {
	f := newRelayFleet(t)
	var stop []context.CancelFunc
	defer func() {
		for _, cancel := range stop {
			cancel()
		}
	}()
	for range relaypolicy.Limit(relaypolicy.Subscription) {
		ctx, cancel := context.WithCancel(f.context)
		stop = append(stop, cancel)
		watch, err := f.client.WatchKV(ctx, &dieterv1.KVWatchRequest{Namespace: "navigation"})
		if err != nil {
			t.Fatal(err)
		}
		if _, err = watch.Recv(); err != nil {
			t.Fatalf("watch below declared limit: %v", err)
		}
	}
	overflow, err := f.client.WatchKV(f.context, &dieterv1.KVWatchRequest{Namespace: "navigation"})
	if err == nil {
		_, err = overflow.Recv()
	}
	if status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("watch above limit = %v", err)
	}
	ctx, cancel := context.WithTimeout(f.context, 2*time.Second)
	defer cancel()
	if _, err = f.client.Health(ctx, &emptypb.Empty{}); err != nil {
		t.Fatalf("watches starved control: %v", err)
	}
	f.command(t, "status")
	f.command(t, "peer", "status")
	// Real peer exchange must converge while every subscription slot is occupied.
	binding, err := f.sourceStore.BindPeerAccount(peerstore.Revision([]string{f.source.Issuer(), "github:1234"}), "github:1234", f.source.ID, f.source.Issuer())
	if err != nil {
		t.Fatal(err)
	}
	record, err := f.sourceStore.PutPeerRecord(binding, "project-settings", "saturation", "", []byte(`{"name":"Shared while full"}`), false)
	if err != nil {
		t.Fatal(err)
	}
	syncer := &daemon.PeerSync{Identity: f.source, Store: f.sourceStore}
	if err = syncer.Round(ctx); err != nil {
		t.Fatal(err)
	}
	remote, err := f.targetStore.PeerData(binding.Account)
	if err != nil || remote.Records["project-settings/saturation"].Revision() != record.Revision() {
		t.Fatalf("replication failed under watch saturation: %v", err)
	}
	route := f.command(t, "machine", "route", f.target.ID)
	if !strings.Contains(route, "relay_lanes") || !strings.Contains(route, "rejected_calls") {
		t.Fatal("machine route omitted lane diagnostics")
	}
	// Cancel one watch and immediately reuse its capacity, without affecting peers.
	stop[0]()
	waitRelay(t, func() bool { return f.gateway.Hub.RelayLanes(f.target.ID)[3].ActiveCalls == 63 }, "canceled watch admission")
	replacement, err := f.client.WatchKV(f.context, &dieterv1.KVWatchRequest{Namespace: "navigation"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = replacement.Recv(); err != nil {
		t.Fatal(err)
	}
	f.command(t, "status")
}
func TestRelayFleetSubscriptionReconnectPreservesCommandsAndWatchCursor(t *testing.T) {
	f := newRelayFleet(t)
	watch, err := f.client.WatchKV(f.context, &dieterv1.KVWatchRequest{Namespace: "navigation"})
	if err != nil {
		t.Fatal(err)
	}
	baseline, err := watch.Recv()
	if err != nil {
		t.Fatal(err)
	}
	hub := f.gateway.Hub
	hub.mu.RLock()
	old := hub.relayLinks[f.target.ID][relaypolicy.Subscription]
	control := hub.relayLinks[f.target.ID][relaypolicy.Control]
	command := hub.relayLinks[f.target.ID][relaypolicy.Command]
	replication := hub.relayLinks[f.target.ID][relaypolicy.Replication]
	hub.mu.RUnlock()
	old.close()
	if _, err = watch.Recv(); status.Code(err) != codes.Unavailable {
		t.Fatalf("lost watch = %v", err)
	}
	f.command(t, "status")
	entry, err := f.client.PutKV(f.context, &dieterv1.KVPutRequest{Ref: &dieterv1.KVRef{Account: baseline.Account, Namespace: "navigation", Key: "projects-folder.resume.name"}, ValueJson: []byte(`"retained"`), OperationId: "one-mutation", DaemonId: f.target.ID})
	if err != nil {
		t.Fatal(err)
	}
	waitRelay(t, func() bool { return hub.RelayReady(f.target.ID) }, "independent subscription reconnect")
	hub.mu.RLock()
	same := hub.relayLinks[f.target.ID][relaypolicy.Control] == control && hub.relayLinks[f.target.ID][relaypolicy.Command] == command && hub.relayLinks[f.target.ID][relaypolicy.Replication] == replication && hub.relayLinks[f.target.ID][relaypolicy.Subscription] != old
	hub.mu.RUnlock()
	if !same {
		t.Fatal("subscription recovery replaced healthy channels")
	}
	resumed, err := f.client.WatchKV(f.context, &dieterv1.KVWatchRequest{Namespace: "navigation", After: baseline.Cursor})
	if err != nil {
		t.Fatal(err)
	}
	frame, err := resumed.Recv()
	if err != nil || len(frame.Entries) != 1 || frame.Entries[0].Revision != entry.Revision {
		t.Fatalf("watch resume lost committed mutation: %v, %v", frame, err)
	}
	// Explicit retry of the same idempotent operation returns the same receipt.
	repeated, err := f.client.PutKV(f.context, &dieterv1.KVPutRequest{Ref: &dieterv1.KVRef{Account: baseline.Account, Namespace: "navigation", Key: "projects-folder.resume.name"}, ValueJson: []byte(`"retained"`), OperationId: "one-mutation", DaemonId: f.target.ID})
	if err != nil || repeated.Revision != entry.Revision {
		t.Fatalf("mutation dispatched twice: %v", err)
	}
	if _, err = f.gateway.Store.RevokeDaemon(f.target.ID, 1234); err != nil {
		t.Fatal(err)
	}
	hub.CloseDaemon(f.target.ID)
	for _, lane := range hub.RelayLanes(f.target.ID) {
		if lane.Connected {
			t.Fatal("revocation failed to close a lane")
		}
	}
}

// The fault is injected after possession authentication, inside an actual gRPC
// Send. Returning Connect cancels the real transport and releases the writer.
type blockedLaneHub struct {
	gatewayv1.UnimplementedDaemonLinkServiceServer
	hub           *Hub
	armed         atomic.Bool
	blocked       chan struct{}
	pauseControl  atomic.Bool
	controlPaused chan struct{}
	resumeControl chan struct{}
}
type blockedLaneStream struct {
	grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame]
	fault *blockedLaneHub
	lane  relaypolicy.Lane
}

func (s *blockedLaneStream) Recv() (*gatewayv1.DaemonLinkFrame, error) {
	f, err := s.BidiStreamingServer.Recv()
	if f.GetKind() == gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO {
		s.lane = f.Lane
		if s.lane == relaypolicy.Control && s.fault.pauseControl.CompareAndSwap(true, false) {
			close(s.fault.controlPaused)
			select {
			case <-s.fault.resumeControl:
			case <-s.Context().Done():
				return nil, s.Context().Err()
			}
		}
	}
	return f, err
}
func (s *blockedLaneStream) Send(f *gatewayv1.DaemonLinkFrame) error {
	if s.lane == relaypolicy.Subscription && f.Kind == gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_OPEN_RPC && s.fault.armed.CompareAndSwap(true, false) {
		close(s.fault.blocked)
		<-s.Context().Done()
		return s.Context().Err()
	}
	return s.BidiStreamingServer.Send(f)
}
func (f *blockedLaneHub) Connect(s grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame]) error {
	return f.hub.Connect(&blockedLaneStream{BidiStreamingServer: s, fault: f})
}

func installRelayFault(t *testing.T, g *Server, fault *blockedLaneHub) {
	t.Helper()
	fault.hub = g.Hub
	rpc := grpc.NewServer()
	gatewayv1.RegisterDaemonLinkServiceServer(rpc, fault)
	t.Cleanup(rpc.Stop)
	original := g.HTTPHandler
	g.HTTPHandler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/dieter.gateway.v1.DaemonLinkService/Connect" {
			rpc.ServeHTTP(w, r)
		} else {
			original.ServeHTTP(w, r)
		}
	})
}

func TestRelayFleetBlockedWriterResetsOnlySubscriptionLane(t *testing.T) {
	fault := &blockedLaneHub{blocked: make(chan struct{})}
	f := newRelayFleet(t, func(g *Server) {
		installRelayFault(t, g, fault)
		g.Hub.writeTimeout = 300 * time.Millisecond
		g.Hub.leaseCheck = 20 * time.Millisecond
	})
	hub := f.gateway.Hub
	hub.mu.RLock()
	control := hub.relayLinks[f.target.ID][relaypolicy.Control]
	replication := hub.relayLinks[f.target.ID][relaypolicy.Replication]
	command := hub.relayLinks[f.target.ID][relaypolicy.Command]
	old := hub.relayLinks[f.target.ID][relaypolicy.Subscription]
	hub.mu.RUnlock()
	fault.armed.Store(true)
	watch, err := f.client.WatchKV(f.context, &dieterv1.KVWatchRequest{Namespace: "navigation"})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-fault.blocked:
	case <-time.After(2 * time.Second):
		t.Fatal("writer was not blocked")
	}
	ctx, cancel := context.WithTimeout(f.context, 200*time.Millisecond)
	defer cancel()
	if _, err = f.client.Health(ctx, &emptypb.Empty{}); err != nil {
		t.Fatalf("blocked writer starved control lane: %v", err)
	}
	f.command(t, "status")
	f.command(t, "peer", "status")
	if _, err = watch.Recv(); status.Code(err) != codes.Unavailable {
		t.Fatalf("stalled transport did not terminate: %v", err)
	}
	waitRelay(t, func() bool { return hub.RelayReady(f.target.ID) }, "writer stall recovery")
	hub.mu.RLock()
	same := hub.relayLinks[f.target.ID][relaypolicy.Control] == control && hub.relayLinks[f.target.ID][relaypolicy.Replication] == replication && hub.relayLinks[f.target.ID][relaypolicy.Command] == command && hub.relayLinks[f.target.ID][relaypolicy.Subscription] != old
	hub.mu.RUnlock()
	if !same {
		t.Fatal("writer stall reset unrelated channels")
	}
	recovered, err := f.client.WatchKV(f.context, &dieterv1.KVWatchRequest{Namespace: "navigation"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = recovered.Recv(); err != nil {
		t.Fatal(err)
	}
}

func TestRelayFleetLargeResponsesPreservePayloadAcrossFragments(t *testing.T) {
	f := newRelayFleet(t)
	account := peerstore.Revision([]string{f.target.Issuer(), "github:1234"})
	value := []byte(`"` + strings.Repeat("z", 31<<10) + `"`)
	for i := range 8 {
		if _, err := f.client.PutKV(f.context, &dieterv1.KVPutRequest{Ref: &dieterv1.KVRef{Account: account, Namespace: "fragment-fixture", Key: fmt.Sprintf("entry-%d", i)}, ValueJson: value, OperationId: fmt.Sprintf("fragment-%d", i), DaemonId: f.target.ID}); err != nil {
			t.Fatal(err)
		}
	}
	page, err := f.client.ListKV(f.context, &dieterv1.KVListRequest{Account: account, Namespace: "fragment-fixture"})
	if err != nil {
		t.Fatal(err)
	}
	if proto.Size(page) <= relaypolicy.ChunkBytes || len(page.Entries) != 8 {
		t.Fatal("fixture did not exceed a relay fragment")
	}
	for _, entry := range page.Entries {
		if !bytes.Equal(entry.ValueJson, value) {
			t.Fatal("large response corrupted")
		}
	}
	watch, err := f.client.WatchKV(f.context, &dieterv1.KVWatchRequest{Account: account, Namespace: "fragment-fixture"})
	if err != nil {
		t.Fatal(err)
	}
	frame, err := watch.Recv()
	if err != nil || len(frame.Entries) != 8 || proto.Size(frame) <= relaypolicy.ChunkBytes {
		t.Fatal("large subscription response lost", err)
	}
	for _, entry := range frame.Entries {
		if !bytes.Equal(entry.ValueJson, value) {
			t.Fatal("fragmented watch corrupted")
		}
	}
	// The return direction then forwards a batch exceeding one fragment. The
	// daemon verifies the delegation over the complete reconstructed request.
	syncer := &daemon.PeerSync{Identity: f.source, Store: f.sourceStore}
	for range 2 {
		if err := syncer.Round(f.context); err != nil {
			t.Fatal(err)
		}
	}
	replica, err := f.sourceStore.PeerData(account)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range page.Entries {
		if replica.Records["kv.fragment-fixture/"+entry.Key].Revision() != entry.Revision {
			t.Fatal("fragmented peer exchange lost a record")
		}
	}

	f.command(t, "status")
}

func TestRelayFleetStalledPeerDoesNotDelayHealthyPeerConvergence(t *testing.T) {
	f := newRelayFleet(t)
	stalled := f.enroll("stalled")
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	entered := make(chan struct{})
	var enteredOnce sync.Once
	local := grpc.NewServer(grpc.ForceServerCodec(rpcraw.Codec{}), grpc.UnknownServiceHandler(func(_ any, s grpc.ServerStream) error {
		var message rpcraw.Message
		if err := s.RecvMsg(&message); err != nil {
			return err
		}
		enteredOnce.Do(func() { close(entered) })
		<-s.Context().Done()
		return s.Context().Err()
	}))
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = local.Serve(listener) }()
	defer local.Stop()
	tunnelCtx, cancelTunnel := context.WithCancel(f.context)
	defer cancelTunnel()
	tunnelDone := make(chan error, 1)
	go func() {
		tunnelDone <- (&daemon.GatewayClient{Identity: stalled, LocalTarget: listener.Addr().String(), Version: "0.4.1-dev", Log: log}).Run(tunnelCtx)
	}()
	defer func() {
		cancelTunnel()
		select {
		case <-tunnelDone:
		case <-time.After(2 * time.Second):
			t.Error("stalled-peer tunnel did not stop")
		}
	}()
	waitRelay(t, func() bool { return f.gateway.Hub.RelayReady(stalled.ID) }, "stalled peer enrollment")
	binding, err := f.sourceStore.BindPeerAccount(peerstore.Revision([]string{f.source.Issuer(), "github:1234"}), "github:1234", f.source.ID, f.source.Issuer())
	if err != nil {
		t.Fatal(err)
	}
	first, err := f.sourceStore.PutPeerRecord(binding, "project-settings", "independent", "", []byte(`{"name":"first"}`), false)
	if err != nil {
		t.Fatal(err)
	}
	syncCtx, cancelSync := context.WithCancel(f.context)
	done := make(chan struct{})
	syncer := &daemon.PeerSync{Identity: f.source, Store: f.sourceStore, Interval: 30 * time.Millisecond, Log: log}
	go func() { defer close(done); syncer.Run(syncCtx) }()
	defer func() {
		cancelSync()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Error("peer workers survived cancellation")
		}
	}()
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("stalled exchange was not admitted")
	}
	converged := func(revision string) bool {
		remote, err := f.targetStore.PeerData(binding.Account)
		return err == nil && remote.Records["project-settings/independent"].Revision() == revision
	}
	waitRelay(t, func() bool { return converged(first.Revision()) }, "first healthy convergence")
	second, err := f.sourceStore.PutPeerRecord(binding, "project-settings", "independent", first.Revision(), []byte(`{"name":"second"}`), false)
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	waitRelay(t, func() bool { return converged(second.Revision()) }, "healthy exchange while another peer hangs")
	if time.Since(start) > 3*time.Second {
		t.Fatal("stalled peer delayed healthy cadence")
	}
	syncerSnapshot := f.gateway.Hub.RelayLanes(stalled.ID)
	if syncerSnapshot[1].ActiveCalls != 1 {
		t.Fatal("stalled peer was retried concurrently or escaped the fixture")
	}
}

func TestRelayFleetControlReconnectRetainsPresenceAndExistingWatch(t *testing.T) {
	fault := &blockedLaneHub{controlPaused: make(chan struct{}), resumeControl: make(chan struct{})}
	resume := sync.OnceFunc(func() { close(fault.resumeControl) })
	defer resume()
	f := newRelayFleet(t, func(g *Server) { installRelayFault(t, g, fault) })
	watch, err := f.client.WatchKV(f.context, &dieterv1.KVWatchRequest{Namespace: "navigation"})
	if err != nil {
		t.Fatal(err)
	}
	baseline, err := watch.Recv()
	if err != nil {
		t.Fatal(err)
	}
	hub := f.gateway.Hub
	hub.mu.RLock()
	old := hub.relayLinks[f.target.ID][relaypolicy.Control]
	subscription := hub.relayLinks[f.target.ID][relaypolicy.Subscription]
	command := hub.relayLinks[f.target.ID][relaypolicy.Command]
	hub.mu.RUnlock()
	fault.pauseControl.Store(true)
	old.close()
	select {
	case <-fault.controlPaused:
	case <-time.After(3 * time.Second):
		t.Fatal("control reconnect was not paused")
	}
	if !hub.Online(f.target.ID) {
		t.Fatal("control reconnect made live daemon offline")
	}
	f.command(t, "kv", "list", "--namespace", "navigation")
	entry, err := f.client.PutKV(f.context, &dieterv1.KVPutRequest{Ref: &dieterv1.KVRef{Account: baseline.Account, Namespace: "navigation", Key: "projects-folder.control.name"}, ValueJson: []byte(`"Still live"`), OperationId: "control-recovery", DaemonId: f.target.ID})
	if err != nil {
		t.Fatal(err)
	}
	for {
		frame, err := watch.Recv()
		if err != nil {
			t.Fatal("control reconnect terminated existing subscription", err)
		}
		found := false
		for _, item := range frame.Entries {
			if item.Revision == entry.Revision {
				found = true
			}
		}
		if found {
			break
		}
	}
	resume()
	waitRelay(t, func() bool { return hub.RelayReady(f.target.ID) }, "control reconnect")
	hub.mu.RLock()
	same := hub.relayLinks[f.target.ID][relaypolicy.Subscription] == subscription && hub.relayLinks[f.target.ID][relaypolicy.Command] == command && hub.relayLinks[f.target.ID][relaypolicy.Control] != old
	hub.mu.RUnlock()
	if !same {
		t.Fatal("control recovery replaced working channels")
	}
}

func TestRelayFleetRecordRejectionPreservesStructuredDiagnostics(t *testing.T) {
	f := newRelayFleet(t)
	account := peerstore.Revision([]string{f.target.Issuer(), "github:1234"})
	hub := f.gateway.Hub
	hub.mu.RLock()
	before := hub.relayLinks[f.target.ID][relaypolicy.Replication]
	hub.mu.RUnlock()
	_, err := f.client.MergePeerRecords(f.context, &dieterv1.MergePeerRecordsRequest{Account: account, Records: []*dieterv1.PeerRecord{{Kind: "project-settings", Id: "rejected"}}})
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("record rejection became transport failure: %v", err)
	}
	var detail *errdetails.ErrorInfo
	for _, value := range status.Convert(err).Details() {
		if info, ok := value.(*errdetails.ErrorInfo); ok {
			detail = info
		}
	}
	if detail == nil || detail.Domain != "dieter.peer" || detail.Metadata["id"] != "rejected" || detail.Metadata["kind"] != "project-settings" {
		t.Fatalf("rejection lost bounded record diagnostics: %v", err)
	}
	f.command(t, "peer", "status")
	hub.mu.RLock()
	same := hub.relayLinks[f.target.ID][relaypolicy.Replication] == before
	hub.mu.RUnlock()
	if !same {
		t.Fatal("a rejected record reset the replication transport")
	}
}
