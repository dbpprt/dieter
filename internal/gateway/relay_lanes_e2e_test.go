//go:build e2e

package gateway_test

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/cli"
	"github.com/dbpprt/dieter/internal/gateway"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/peersync"
	"github.com/dbpprt/dieter/internal/store"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/testkit/topology"
	"github.com/dbpprt/dieter/internal/transport/dieterclient"
	"github.com/dbpprt/dieter/internal/transport/relay"
	"google.golang.org/genproto/googleapis/rpc/errdetails"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

const fleetAccount int64 = 1234

// relayFleet is a target daemon behind an in-process gateway, a source
// machine whose daemon the test plays (peer sync and the CLI run from its
// home), and a paired app. Every call reaches the target over mutual TLS
// inside relay tunnels; the gateway only splices ciphertext onto lanes.
type relayFleet struct {
	gateway                  *topology.Gateway
	target                   *topology.Daemon
	source                   *link.Identity
	sourceTrust              *link.Trust
	targetStore, sourceStore *store.Store
	app                      *topology.Client
	// client reaches the target on the command lane.
	client  dieterclient.Client
	context context.Context
	account string
}

func newRelayFleet(t *testing.T) *relayFleet {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 60*time.Second)
	t.Cleanup(cancel)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	g := topology.StartGateway(t, topology.GatewayOptions{Accounts: []int64{fleetAccount}, Logger: log})
	targetIdentity := topology.Machine(t, g, "target", fleetAccount)
	source := topology.Machine(t, g, "source", fleetAccount)
	ts, ss := store.New(targetIdentity.Root), store.New(source.Root)
	account := crdt.Revision([]string{targetIdentity.Issuer(), fmt.Sprintf("github:%d", fleetAccount)})
	if _, err := ts.Replica.BindPeerAccount(account, fmt.Sprintf("github:%d", fleetAccount), targetIdentity.ID, targetIdentity.Issuer()); err != nil {
		t.Fatal(err)
	}
	if _, err := ss.Replica.BindPeerAccount(account, fmt.Sprintf("github:%d", fleetAccount), source.ID, source.Issuer()); err != nil {
		t.Fatal(err)
	}
	target := topology.StartDaemon(t, g, topology.DaemonOptions{Identity: targetIdentity, Store: ts, Account: fleetAccount, Logger: log, Tunnel: func(tunnel *link.GatewayClient) {
		tunnel.Timing = link.GatewayTiming{ReconnectInitialBackoff: 20 * time.Millisecond, ReconnectMaximumBackoff: 50 * time.Millisecond}
	}})
	sourceTrust := topology.Join(t, g, target, source)
	app := topology.StartClient(t, g, target, "Test phone")
	f := &relayFleet{gateway: g, target: target, source: source, sourceTrust: sourceTrust, targetStore: ts, sourceStore: ss, app: app, context: ctx, account: account}
	f.client = dieterclient.New(f.dial(t, relay.Command))
	return f
}

// dial connects the app to the target over a tunnel on lane. Every
// reconnect of the returned connection opens a fresh tunnel.
func (f *relayFleet) dial(t *testing.T, lane relay.Lane) *grpc.ClientConn {
	t.Helper()
	daemonID := f.target.Identity.ID
	key, err := f.app.DaemonKey(f.context, daemonID)
	if err != nil {
		t.Fatal(err)
	}
	token, err := f.app.Token(f.context, daemonID)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := f.app.Certificate()
	if err != nil {
		t.Fatal(err)
	}
	connection, err := link.DialDaemon(certificate, key, link.TokenCredentials(token), func(ctx context.Context, _ string) (net.Conn, error) {
		return link.DialTunnel(ctx, f.app.Gateway, daemonID, lane)
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	return connection
}

func (f *relayFleet) link(lane relay.Lane) *gateway.LaneLink {
	return f.gateway.Server.Hub.LaneLink(f.target.Identity.ID, lane)
}

func (f *relayFleet) tunnels(lane relay.Lane) uint32 {
	return f.gateway.Server.Hub.RelayLanes(f.target.Identity.ID)[lane].GetActiveCalls()
}

func (f *relayFleet) put(t *testing.T, client dieterclient.Client, key, value, operation string) *dieterv1.KVEntry {
	t.Helper()
	entry, err := client.PutKV(f.context, &dieterv1.KVPutRequest{Ref: &dieterv1.KVRef{Account: f.account, Namespace: "navigation", Key: key}, ValueJson: []byte(value), OperationId: operation, DaemonId: f.target.Identity.ID})
	if err != nil {
		t.Fatal(err)
	}
	return entry
}

func waitRelay(t *testing.T, condition func() bool, what string) {
	t.Helper()
	testkit.Eventually(t, 10*time.Second, condition, "%s", what)
}

func (f *relayFleet) command(t *testing.T, args ...string) string {
	t.Helper()
	c := cli.New(f.sourceStore.Root)
	c.Machine = f.target.Identity.ID
	c.Timeout = 10 * time.Second
	var out bytes.Buffer
	c.Out = &out
	c.Err = &out
	if err := c.Run(args); err != nil {
		t.Fatalf("CLI %v: %v (%s)", args, err, out.String())
	}
	return out.String()
}

func TestRelayFleetSubscriptionTunnelSaturationPreservesCommandsAndReplication(t *testing.T) {
	t.Parallel()
	f := newRelayFleet(t)
	var watches []*grpc.ClientConn
	for range relay.TunnelLimit(relay.Subscription) {
		connection := f.dial(t, relay.Subscription)
		watch, err := dieterclient.New(connection).WatchKV(f.context, &dieterv1.KVWatchRequest{Namespace: "navigation"})
		if err != nil {
			t.Fatal(err)
		}
		if _, err = watch.Recv(); err != nil {
			t.Fatalf("watch below the tunnel limit: %v", err)
		}
		watches = append(watches, connection)
	}
	if tunnel, err := link.DialTunnel(f.context, f.app.Gateway, f.target.Identity.ID, relay.Subscription); status.Code(err) != codes.ResourceExhausted {
		if tunnel != nil {
			_ = tunnel.Close()
		}
		t.Fatalf("subscription tunnel above its limit = %v", err)
	}
	ctx, cancel := context.WithTimeout(f.context, 5*time.Second)
	defer cancel()
	if _, err := f.client.Health(ctx, &emptypb.Empty{}); err != nil {
		t.Fatalf("subscription tunnels starved commands: %v", err)
	}
	f.command(t, "status")
	f.command(t, "peer", "status")
	// Real peer exchange on the replication lane converges while every
	// subscription tunnel is taken.
	binding, err := f.sourceStore.Replica.BindPeerAccount(f.account, fmt.Sprintf("github:%d", fleetAccount), f.source.ID, f.source.Issuer())
	if err != nil {
		t.Fatal(err)
	}
	record, err := f.sourceStore.Replica.PutPeerRecord(binding, "project-settings", "saturation", "", []byte(`{"name":"Shared while full"}`), false)
	if err != nil {
		t.Fatal(err)
	}
	syncer := &peersync.PeerSync{Identity: f.source, Trust: f.sourceTrust, Store: f.sourceStore}
	if err = syncer.Round(ctx); err != nil {
		t.Fatal(err)
	}
	remote, err := f.targetStore.Replica.PeerData(binding.Account)
	if err != nil || remote.Records["project-settings/saturation"].Revision() != record.Revision() {
		t.Fatalf("replication failed under subscription saturation: %v", err)
	}
	route := f.command(t, "machine", "route", f.target.Identity.ID)
	if !strings.Contains(route, "relay_lanes") || !strings.Contains(route, "rejected_calls") {
		t.Fatal("machine route omitted lane diagnostics")
	}
	// Closing one connection frees its tunnel for another client at once.
	_ = watches[0].Close()
	waitRelay(t, func() bool { return int(f.tunnels(relay.Subscription)) == relay.TunnelLimit(relay.Subscription)-1 }, "closed tunnel release")
	replacement, err := dieterclient.New(f.dial(t, relay.Subscription)).WatchKV(f.context, &dieterv1.KVWatchRequest{Namespace: "navigation"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = replacement.Recv(); err != nil {
		t.Fatal(err)
	}
	f.command(t, "status")
}

func TestRelayFleetSubscriptionLinkLossEndsOnlyItsTunnels(t *testing.T) {
	t.Parallel()
	f := newRelayFleet(t)
	watch, err := dieterclient.New(f.dial(t, relay.Subscription)).WatchKV(f.context, &dieterv1.KVWatchRequest{Namespace: "navigation"})
	if err != nil {
		t.Fatal(err)
	}
	baseline, err := watch.Recv()
	if err != nil {
		t.Fatal(err)
	}
	old, control, command, replication := f.link(relay.Subscription), f.link(relay.Control), f.link(relay.Command), f.link(relay.Replication)
	old.Close()
	if _, err = watch.Recv(); status.Code(err) != codes.Unavailable {
		t.Fatalf("watch on a lost lane = %v", err)
	}
	// The command tunnel and the CLI never noticed.
	f.command(t, "status")
	entry := f.put(t, f.client, "projects-folder.resume.name", `"retained"`, "one-mutation")
	hub := f.gateway.Server.Hub
	waitRelay(t, func() bool { return hub.RelayReady(f.target.Identity.ID) }, "independent subscription reconnect")
	if f.link(relay.Control) != control || f.link(relay.Command) != command || f.link(relay.Replication) != replication || f.link(relay.Subscription) == old {
		t.Fatal("subscription recovery replaced healthy lanes")
	}
	resumed, err := dieterclient.New(f.dial(t, relay.Subscription)).WatchKV(f.context, &dieterv1.KVWatchRequest{Namespace: "navigation", After: baseline.Cursor})
	if err != nil {
		t.Fatal(err)
	}
	frame, err := resumed.Recv()
	if err != nil || len(frame.Entries) != 1 || frame.Entries[0].Revision != entry.Revision {
		t.Fatalf("watch resume lost committed mutation: %v, %v", frame, err)
	}
	// An explicit retry of the same idempotent operation returns its receipt.
	if repeated := f.put(t, f.client, "projects-folder.resume.name", `"retained"`, "one-mutation"); repeated.Revision != entry.Revision {
		t.Fatal("mutation dispatched twice")
	}
	if _, err = f.gateway.Store.RevokeDaemon(f.target.Identity.ID, fleetAccount); err != nil {
		t.Fatal(err)
	}
	hub.CloseDaemon(f.target.Identity.ID)
	for _, lane := range hub.RelayLanes(f.target.Identity.ID) {
		if lane.Connected {
			t.Fatal("revocation failed to close a lane")
		}
	}
	if _, err := f.client.Health(f.context, &emptypb.Empty{}); err == nil {
		t.Fatal("a revoked machine still answered through its tunnel")
	}
}

func TestRelayFleetControlReconnectKeepsPresenceAndOtherTunnels(t *testing.T) {
	t.Parallel()
	f := newRelayFleet(t)
	watch, err := dieterclient.New(f.dial(t, relay.Subscription)).WatchKV(f.context, &dieterv1.KVWatchRequest{Namespace: "navigation"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := watch.Recv(); err != nil {
		t.Fatal(err)
	}
	hub := f.gateway.Server.Hub
	old, subscription, command := f.link(relay.Control), f.link(relay.Subscription), f.link(relay.Command)
	old.Close()
	if !hub.Online(f.target.Identity.ID) {
		t.Fatal("control reconnect made a live daemon offline")
	}
	f.command(t, "kv", "list", "--namespace", "navigation")
	entry := f.put(t, f.client, "projects-folder.control.name", `"Still live"`, "control-recovery")
	for found := false; !found; {
		frame, err := watch.Recv()
		if err != nil {
			t.Fatal("control reconnect ended an existing subscription tunnel", err)
		}
		for _, item := range frame.Entries {
			found = found || item.Revision == entry.Revision
		}
	}
	waitRelay(t, func() bool { return hub.RelayReady(f.target.Identity.ID) }, "control reconnect")
	if f.link(relay.Subscription) != subscription || f.link(relay.Command) != command || f.link(relay.Control) == old {
		t.Fatal("control recovery replaced working lanes")
	}
}

func TestRelayFleetLargePayloadsCrossManyTunnelFrames(t *testing.T) {
	t.Parallel()
	f := newRelayFleet(t)
	value := []byte(`"` + strings.Repeat("z", 31<<10) + `"`)
	for i := range 8 {
		if _, err := f.client.PutKV(f.context, &dieterv1.KVPutRequest{Ref: &dieterv1.KVRef{Account: f.account, Namespace: "fragment-fixture", Key: fmt.Sprintf("entry-%d", i)}, ValueJson: value, OperationId: fmt.Sprintf("fragment-%d", i), DaemonId: f.target.Identity.ID}); err != nil {
			t.Fatal(err)
		}
	}
	page, err := f.client.ListKV(f.context, &dieterv1.KVListRequest{Account: f.account, Namespace: "fragment-fixture"})
	if err != nil {
		t.Fatal(err)
	}
	// Each response spans several tunnel DATA frames and credit windows.
	if proto.Size(page) <= 3*relay.ChunkBytes || len(page.Entries) != 8 {
		t.Fatal("fixture did not exceed several tunnel frames")
	}
	for _, entry := range page.Entries {
		if !bytes.Equal(entry.ValueJson, value) {
			t.Fatal("large response corrupted")
		}
	}
	watch, err := dieterclient.New(f.dial(t, relay.Subscription)).WatchKV(f.context, &dieterv1.KVWatchRequest{Account: f.account, Namespace: "fragment-fixture"})
	if err != nil {
		t.Fatal(err)
	}
	frame, err := watch.Recv()
	if err != nil || len(frame.Entries) != 8 || proto.Size(frame) <= relay.ChunkBytes {
		t.Fatal("large subscription response lost", err)
	}
	for _, entry := range frame.Entries {
		if !bytes.Equal(entry.ValueJson, value) {
			t.Fatal("large watch corrupted")
		}
	}
	// The replication lane carries the batches back the other way.
	syncer := &peersync.PeerSync{Identity: f.source, Trust: f.sourceTrust, Store: f.sourceStore}
	for range 2 {
		if err := syncer.Round(f.context); err != nil {
			t.Fatal(err)
		}
	}
	replica, err := f.sourceStore.Replica.PeerData(f.account)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range page.Entries {
		if replica.Records["kv.fragment-fixture/"+entry.Key].Revision() != entry.Revision {
			t.Fatal("large peer exchange lost a record")
		}
	}
	f.command(t, "status")
}

func TestRelayFleetStalledPeerDoesNotDelayHealthyPeerConvergence(t *testing.T) {
	t.Parallel()
	f := newRelayFleet(t)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	// A paired machine whose endpoint accepts connections and never answers:
	// its tunnels open, and the TLS handshake inside them hangs.
	stalled := topology.Machine(t, f.gateway, "stalled", fleetAccount)
	topology.Join(t, f.gateway, f.target, stalled)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	var held sync.Mutex
	var accepted []net.Conn
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			held.Lock()
			accepted = append(accepted, connection)
			held.Unlock()
		}
	}()
	defer func() {
		_ = listener.Close()
		held.Lock()
		defer held.Unlock()
		for _, connection := range accepted {
			_ = connection.Close()
		}
	}()
	tunnelCtx, cancelTunnel := context.WithCancel(f.context)
	tunnelDone := make(chan error, 1)
	go func() {
		tunnelDone <- (&link.GatewayClient{Identity: stalled, TunnelTarget: listener.Addr().String(), Version: topology.ClientVersion, Log: log}).Run(tunnelCtx)
	}()
	defer func() {
		cancelTunnel()
		select {
		case <-tunnelDone:
		case <-time.After(2 * time.Second):
			t.Error("stalled-peer tunnel did not stop")
		}
	}()
	hub := f.gateway.Server.Hub
	waitRelay(t, func() bool { return hub.RelayReady(stalled.ID) }, "stalled peer link")
	binding, err := f.sourceStore.Replica.BindPeerAccount(f.account, fmt.Sprintf("github:%d", fleetAccount), f.source.ID, f.source.Issuer())
	if err != nil {
		t.Fatal(err)
	}
	first, err := f.sourceStore.Replica.PutPeerRecord(binding, "project-settings", "independent", "", []byte(`{"name":"first"}`), false)
	if err != nil {
		t.Fatal(err)
	}
	syncCtx, cancelSync := context.WithCancel(f.context)
	done := make(chan struct{})
	syncer := &peersync.PeerSync{Identity: f.source, Trust: f.sourceTrust, Store: f.sourceStore, Interval: 30 * time.Millisecond, Log: log}
	go func() { defer close(done); syncer.Run(syncCtx) }()
	defer func() {
		cancelSync()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("peer workers survived cancellation")
		}
	}()
	stalledTunnels := func() uint32 { return hub.RelayLanes(stalled.ID)[relay.Replication].GetActiveCalls() }
	waitRelay(t, func() bool { return stalledTunnels() == 1 }, "a held tunnel to the stalled peer")
	converged := func(revision string) bool {
		remote, err := f.targetStore.Replica.PeerData(binding.Account)
		return err == nil && remote.Records["project-settings/independent"].Revision() == revision
	}
	waitRelay(t, func() bool { return converged(first.Revision()) }, "first healthy convergence")
	second, err := f.sourceStore.Replica.PutPeerRecord(binding, "project-settings", "independent", first.Revision(), []byte(`{"name":"second"}`), false)
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	waitRelay(t, func() bool { return converged(second.Revision()) }, "healthy exchange while another peer hangs")
	if time.Since(start) > 3*time.Second {
		t.Fatal("stalled peer delayed healthy cadence")
	}
	if stalledTunnels() != 1 {
		t.Fatal("stalled peer was retried concurrently or escaped the fixture")
	}
}

func TestRelayFleetRecordRejectionPreservesStructuredDiagnostics(t *testing.T) {
	t.Parallel()
	f := newRelayFleet(t)
	before := f.link(relay.Replication)
	peer, err := peersync.DialPeer(f.context, f.source, f.sourceTrust, topology.Dial(t, f.gateway), f.target.Identity.ID)
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	if peer.Route != "relay" {
		t.Fatalf("peer route = %q; want the relay tunnel", peer.Route)
	}
	_, err = peer.Client.MergePeerRecords(f.context, &dieterv1.MergePeerRecordsRequest{Account: f.account, Records: []*dieterv1.PeerRecord{{Kind: "project-settings", Id: "rejected"}}})
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
	if f.link(relay.Replication) != before {
		t.Fatal("a rejected record reset the replication lane")
	}
}
