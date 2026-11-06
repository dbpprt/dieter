package gateway

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"runtime"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/platform/buildinfo"
	"github.com/dbpprt/dieter/internal/security/linkauth"
	"github.com/dbpprt/dieter/internal/transport/relay"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

const (
	tunnelOwner    = int64(1234)
	tunnelStranger = int64(5678)
	tunnelWait     = 10 * time.Second
)

// tunnelFixture is an in-process gateway on a loopback port. Daemons and
// clients reach it over HTTP/2 exactly like real ones.
type tunnelFixture struct {
	server     *Server
	address    string
	connection *grpc.ClientConn
}

func newTunnelFixture(t *testing.T) *tunnelFixture {
	t.Helper()
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	origin, _ := url.Parse("https://gateway.test")
	config := Config{
		DevInsecure: true, PublicURL: origin, SessionTTL: time.Hour, AuthSecret: []byte("tunnel-test-secret-not-a-real-secret"),
		AllowedUserIDs: map[int64]struct{}{tunnelOwner: {}, tunnelStranger: {}},
	}
	server, err := NewServer(config, store, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(server.APIGRPC.Stop)
	httpServer, err := server.httpServer()
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = httpServer.Serve(listener) }()
	t.Cleanup(func() { _ = httpServer.Close() })
	connection, err := grpc.NewClient(listener.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	return &tunnelFixture{server: server, address: listener.Addr().String(), connection: connection}
}

func (f *tunnelFixture) session(t *testing.T, githubID int64) string {
	t.Helper()
	token, _, err := f.server.Auth.createSession(githubID, "tunnel-test")
	if err != nil {
		t.Fatal(err)
	}
	return token
}

func (f *tunnelFixture) signOut(t *testing.T, githubID int64) {
	t.Helper()
	if err := f.server.Store.UpdateAuthState(func(state *AuthState) error {
		kept := state.Sessions[:0]
		for _, session := range state.Sessions {
			if session.GitHubID != githubID {
				kept = append(kept, session)
			}
		}
		state.Sessions = kept
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

// fakeDaemon speaks the daemon side of the link protocol with a real
// enrolled identity, one link per lane, and records the tunnel frames it
// receives.
type fakeDaemon struct {
	id         string
	generation uint64
	private    ed25519.PrivateKey
	links      map[relay.Lane]*fakeLink
}

type fakeLink struct {
	stream grpc.BidiStreamingClient[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame]
	cancel context.CancelFunc
	frames chan *gatewayv1.DaemonLinkFrame
	ended  chan error
}

func (f *tunnelFixture) enroll(t *testing.T, githubID int64) *fakeDaemon {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := x509.MarshalPKIXPublicKey(public)
	if err != nil {
		t.Fatal(err)
	}
	enrollment, err := f.server.Service.BeginDaemonEnrollment(t.Context(), &gatewayv1.BeginDaemonEnrollmentRequest{Name: "Tunnel test daemon", PublicKey: encoded})
	if err != nil {
		t.Fatal(err)
	}
	if err := f.server.Store.ApproveEnrollment(enrollment.GetEnrollmentId(), enrollment.GetUserCode(), githubID, "tunnel-test"); err != nil {
		t.Fatal(err)
	}
	credential, err := f.server.Service.CompleteDaemonEnrollment(t.Context(), &gatewayv1.CompleteDaemonEnrollmentRequest{EnrollmentId: enrollment.GetEnrollmentId(), EnrollmentSecret: enrollment.GetEnrollmentSecret()})
	if err != nil {
		t.Fatal(err)
	}
	return &fakeDaemon{id: credential.GetDaemonId(), generation: credential.GetGeneration(), private: private, links: map[relay.Lane]*fakeLink{}}
}

// connect opens the daemon's lanes, control first, as one process session.
func (f *tunnelFixture) connect(t *testing.T, daemon *fakeDaemon) {
	t.Helper()
	session := make([]byte, 32)
	if _, err := rand.Read(session); err != nil {
		t.Fatal(err)
	}
	client := gatewayv1.NewDaemonLinkServiceClient(f.connection)
	for _, lane := range relay.Lanes {
		ctx, cancel := context.WithCancel(context.Background())
		t.Cleanup(cancel)
		stream, err := client.Connect(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err := stream.Send(&gatewayv1.DaemonLinkFrame{
			Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO, DaemonId: daemon.id, ReleaseVersion: buildinfo.ReleaseVersion,
			Lane: lane, SessionId: hex.EncodeToString(session), Generation: daemon.generation,
		}); err != nil {
			t.Fatal(err)
		}
		challenge, err := stream.Recv()
		if err != nil || challenge.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PING {
			t.Fatalf("daemon challenge = %v, %v", challenge, err)
		}
		if err := stream.Send(&gatewayv1.DaemonLinkFrame{
			Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG, DaemonId: daemon.id, RequestId: challenge.GetRequestId(),
			Payload: linkauth.Sign(daemon.private, f.server.Config.IdentityOrigin(), daemon.id, challenge.GetPayload()),
		}); err != nil {
			t.Fatal(err)
		}
		if ack, err := stream.Recv(); err != nil || ack.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO_ACK {
			t.Fatalf("daemon hello acknowledgement = %v, %v", ack, err)
		}
		link := &fakeLink{stream: stream, cancel: cancel, frames: make(chan *gatewayv1.DaemonLinkFrame, 256), ended: make(chan error, 1)}
		go func() {
			for {
				frame, err := stream.Recv()
				if err != nil {
					link.ended <- err
					return
				}
				link.frames <- frame
			}
		}()
		daemon.links[lane] = link
	}
}

func (l *fakeLink) next(t *testing.T) *gatewayv1.DaemonLinkFrame {
	t.Helper()
	select {
	case frame := <-l.frames:
		return frame
	case err := <-l.ended:
		t.Fatalf("daemon link ended: %v", err)
	case <-time.After(tunnelWait):
		t.Fatal("daemon link received nothing")
	}
	return nil
}

func (l *fakeLink) expect(t *testing.T, kind gatewayv1.DaemonLinkFrameKind) *gatewayv1.DaemonLinkFrame {
	t.Helper()
	frame := l.next(t)
	if frame.GetKind() != kind {
		t.Fatalf("daemon link frame = %v; want %v", frame, kind)
	}
	return frame
}

func (l *fakeLink) send(t *testing.T, frame *gatewayv1.DaemonLinkFrame) {
	t.Helper()
	if err := l.stream.Send(frame); err != nil {
		t.Fatal(err)
	}
}

// accept answers the next TUNNEL_OPEN and returns its stream ID.
func (l *fakeLink) accept(t *testing.T) uint64 {
	t.Helper()
	open := l.expect(t, gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPEN)
	l.send(t, &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPENED, StreamId: open.GetStreamId()})
	return open.GetStreamId()
}

type clientTunnel = grpc.BidiStreamingClient[gatewayv1.TunnelFrame, gatewayv1.TunnelFrame]

func (f *tunnelFixture) dial(t *testing.T, authorization, daemonID string, lane relay.Lane) clientTunnel {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	ctx = metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+authorization, "x-dieter-client-version", buildinfo.ReleaseVersion)
	stream, err := gatewayv1.NewRelayServiceClient(f.connection).OpenTunnel(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// A rejected stream reports io.EOF here and its status from Recv.
	if err := stream.Send(&gatewayv1.TunnelFrame{Kind: gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPEN, DaemonId: daemonID, Lane: lane}); err != nil && !errors.Is(err, io.EOF) {
		t.Fatal(err)
	}
	return stream
}

func receive(t *testing.T, stream clientTunnel) (*gatewayv1.TunnelFrame, error) {
	t.Helper()
	type result struct {
		frame *gatewayv1.TunnelFrame
		err   error
	}
	received := make(chan result, 1)
	go func() {
		frame, err := stream.Recv()
		received <- result{frame, err}
	}()
	select {
	case value := <-received:
		return value.frame, value.err
	case <-time.After(tunnelWait):
		t.Fatal("tunnel client received nothing")
		return nil, nil
	}
}

func expectClient(t *testing.T, stream clientTunnel, kind gatewayv1.TunnelFrameKind) *gatewayv1.TunnelFrame {
	t.Helper()
	frame, err := receive(t, stream)
	if err != nil || frame.GetKind() != kind {
		t.Fatalf("tunnel client frame = %v, %v; want %v", frame, err, kind)
	}
	return frame
}

func expectClosed(t *testing.T, stream clientTunnel, code codes.Code) {
	t.Helper()
	frame := expectClient(t, stream, gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_CLOSE)
	if codes.Code(frame.GetStatusCode()) != code {
		t.Fatalf("tunnel closed with %v %q; want %v", codes.Code(frame.GetStatusCode()), frame.GetStatusMessage(), code)
	}
	if _, err := receive(t, stream); !errors.Is(err, io.EOF) {
		t.Fatalf("tunnel stream continued after CLOSE: %v", err)
	}
}

func clientData(data []byte) *gatewayv1.TunnelFrame {
	return &gatewayv1.TunnelFrame{Kind: gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_DATA, Data: data}
}

func daemonData(stream uint64, data []byte) *gatewayv1.DaemonLinkFrame {
	return &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_DATA, StreamId: stream, Payload: data}
}

func TestTunnelCarriesOpaqueBytesBothWaysWithEndToEndCredits(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	daemon := f.enroll(t, tunnelOwner)
	f.connect(t, daemon)
	client := f.dial(t, f.session(t, tunnelOwner), daemon.id, relay.Command)
	link := daemon.links[relay.Command]
	id := link.accept(t)
	expectClient(t, client, gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPENED)

	// Several full windows in each direction; each side credits what it
	// consumed, and the gateway forwards both data and credits unchanged.
	for round := range 3 {
		for i := range relay.TunnelWindow {
			payload := bytes.Repeat([]byte{byte(round), byte(i)}, relay.ChunkBytes/2)
			if err := client.Send(clientData(payload)); err != nil {
				t.Fatal(err)
			}
			if frame := link.expect(t, gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_DATA); frame.GetStreamId() != id || !bytes.Equal(frame.GetPayload(), payload) {
				t.Fatalf("daemon received %d bytes on stream %d", len(frame.GetPayload()), frame.GetStreamId())
			}
		}
		link.send(t, &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_WINDOW, StreamId: id, Credit: relay.TunnelWindow})
		if frame := expectClient(t, client, gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_WINDOW); frame.GetCredit() != relay.TunnelWindow {
			t.Fatalf("client credit = %d", frame.GetCredit())
		}
		for i := range relay.TunnelWindow {
			payload := []byte{byte(round), byte(i), 'd'}
			link.send(t, daemonData(id, payload))
			if frame := expectClient(t, client, gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_DATA); !bytes.Equal(frame.GetData(), payload) {
				t.Fatalf("client received %q", frame.GetData())
			}
			if err := client.Send(&gatewayv1.TunnelFrame{Kind: gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_WINDOW, Credit: 1}); err != nil {
				t.Fatal(err)
			}
			if frame := link.expect(t, gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_WINDOW); frame.GetCredit() != 1 || frame.GetStreamId() != id {
				t.Fatalf("daemon credit = %v", frame)
			}
		}
	}

	// The daemon ends the tunnel; the client gets its reason.
	link.send(t, &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE, StreamId: id, StatusCode: int32(codes.OK)})
	expectClosed(t, client, codes.OK)
	waitForTunnels(t, f, daemon.id, 0)
}

func waitForTunnels(t *testing.T, f *tunnelFixture, daemonID string, want uint32) {
	t.Helper()
	deadline := time.Now().Add(tunnelWait)
	for {
		var active uint32
		var queued uint64
		for _, lane := range f.server.Hub.RelayLanes(daemonID) {
			active += lane.GetActiveCalls()
			queued += lane.GetQueuedBytes()
		}
		if active == want && (want != 0 || queued == 0) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("daemon has %d tunnels and %d queued bytes; want %d tunnels", active, queued, want)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func TestTunnelClientEndingTheStreamClosesTheDaemonSide(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	daemon := f.enroll(t, tunnelOwner)
	f.connect(t, daemon)
	client := f.dial(t, f.session(t, tunnelOwner), daemon.id, relay.Subscription)
	link := daemon.links[relay.Subscription]
	id := link.accept(t)
	expectClient(t, client, gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPENED)
	if err := client.CloseSend(); err != nil {
		t.Fatal(err)
	}
	if frame := link.expect(t, gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE); frame.GetStreamId() != id {
		t.Fatalf("daemon closed stream %d; want %d", frame.GetStreamId(), id)
	}
	waitForTunnels(t, f, daemon.id, 0)
}

func TestTunnelWindowViolationsCloseOnlyThatTunnel(t *testing.T) {
	t.Parallel()
	for name, violate := range map[string]func(t *testing.T, client clientTunnel, link *fakeLink, id uint64){
		"client exceeds window": func(t *testing.T, client clientTunnel, _ *fakeLink, _ uint64) {
			for range relay.TunnelWindow + 1 {
				if err := client.Send(clientData([]byte("x"))); err != nil {
					t.Fatal(err)
				}
			}
		},
		"client oversized data": func(t *testing.T, client clientTunnel, _ *fakeLink, _ uint64) {
			if err := client.Send(clientData(make([]byte, relay.ChunkBytes+1))); err != nil {
				t.Fatal(err)
			}
		},
		"client credits unsent data": func(t *testing.T, client clientTunnel, _ *fakeLink, _ uint64) {
			if err := client.Send(&gatewayv1.TunnelFrame{Kind: gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_WINDOW, Credit: 1}); err != nil {
				t.Fatal(err)
			}
		},
		"daemon exceeds window": func(t *testing.T, _ clientTunnel, link *fakeLink, id uint64) {
			for range relay.TunnelWindow + 1 {
				link.send(t, daemonData(id, []byte("x")))
			}
		},
		"daemon credits unsent data": func(t *testing.T, _ clientTunnel, link *fakeLink, id uint64) {
			link.send(t, &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_WINDOW, StreamId: id, Credit: 1})
		},
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := newTunnelFixture(t)
			daemon := f.enroll(t, tunnelOwner)
			f.connect(t, daemon)
			token := f.session(t, tunnelOwner)
			link := daemon.links[relay.Command]
			healthy := f.dial(t, token, daemon.id, relay.Command)
			healthyID := link.accept(t)
			expectClient(t, healthy, gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPENED)
			client := f.dial(t, token, daemon.id, relay.Command)
			id := link.accept(t)
			expectClient(t, client, gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPENED)
			violate(t, client, link, id)
			// The client is told why; the daemon is told to close.
			for {
				frame, err := receive(t, client)
				if err != nil {
					t.Fatalf("violating tunnel ended without CLOSE: %v", err)
				}
				if frame.GetKind() == gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_CLOSE {
					if code := codes.Code(frame.GetStatusCode()); code != codes.ResourceExhausted && code != codes.InvalidArgument {
						t.Fatalf("violation closed with %v", code)
					}
					break
				}
			}
			for {
				frame := link.next(t)
				if frame.GetKind() == gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE {
					if frame.GetStreamId() != id {
						t.Fatalf("daemon closed stream %d; want %d", frame.GetStreamId(), id)
					}
					break
				}
			}
			// The neighbour on the same link is unaffected.
			if err := healthy.Send(clientData([]byte("still open"))); err != nil {
				t.Fatal(err)
			}
			if frame := link.expect(t, gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_DATA); frame.GetStreamId() != healthyID {
				t.Fatalf("data reached stream %d", frame.GetStreamId())
			}
			waitForTunnels(t, f, daemon.id, 1)
		})
	}
}

func TestTunnelLaneLimitRejectsExcessTunnels(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	daemon := f.enroll(t, tunnelOwner)
	f.connect(t, daemon)
	token := f.session(t, tunnelOwner)
	link := daemon.links[relay.Control]
	for range relay.TunnelLimit(relay.Control) {
		client := f.dial(t, token, daemon.id, relay.Control)
		link.accept(t)
		expectClient(t, client, gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPENED)
	}
	expectClosed(t, f.dial(t, token, daemon.id, relay.Control), codes.ResourceExhausted)
	// Another lane of the same daemon still admits tunnels.
	client := f.dial(t, token, daemon.id, relay.Replication)
	daemon.links[relay.Replication].accept(t)
	expectClient(t, client, gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPENED)
	route, err := f.server.Service.ResolveDaemonRoute(context.WithValue(t.Context(), principalKey{}, Principal{GitHubID: tunnelOwner}), &gatewayv1.DaemonRef{DaemonId: daemon.id})
	if err != nil {
		t.Fatal(err)
	}
	for _, lane := range route.GetRelayLanes() {
		if lane.GetLane() == relay.Control && (lane.GetActiveCalls() != 4 || lane.GetCallLimit() != 4 || lane.GetRejectedCalls() != 1) {
			t.Fatalf("control lane status = %v", lane)
		}
	}
}

func TestTunnelReachesOnlyTheCallersLiveDaemons(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	owned := f.enroll(t, tunnelOwner)
	f.connect(t, owned)
	foreign := f.enroll(t, tunnelStranger)
	f.connect(t, foreign)
	revoked := f.enroll(t, tunnelOwner)
	f.connect(t, revoked)
	token := f.session(t, tunnelOwner)
	if _, err := f.server.Store.RevokeDaemon(revoked.id, tunnelOwner); err != nil {
		t.Fatal(err)
	}
	for name, daemonID := range map[string]string{"foreign": foreign.id, "revoked": revoked.id, "unknown": "d_unknown"} {
		t.Run(name, func(t *testing.T) {
			expectClosed(t, f.dial(t, token, daemonID, relay.Command), codes.NotFound)
		})
	}
	select {
	case frame := <-foreign.links[relay.Command].frames:
		t.Fatalf("another account's daemon was asked to open a tunnel: %v", frame)
	default:
	}
	// A daemon proves possession of its key to open tunnels to its peers.
	peerProof := linkauth.SignPeer(owned.private, owned.id, f.server.Config.IdentityOrigin(), owned.generation, time.Now())
	other := f.enroll(t, tunnelOwner)
	f.connect(t, other)
	client := f.dial(t, peerProof, other.id, relay.Replication)
	other.links[relay.Replication].accept(t)
	expectClient(t, client, gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPENED)
	expectClosed(t, f.dial(t, peerProof, foreign.id, relay.Replication), codes.NotFound)
}

func TestTunnelRejectsInvalidOpenAndUnauthenticatedCallers(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	daemon := f.enroll(t, tunnelOwner)
	f.connect(t, daemon)
	token := f.session(t, tunnelOwner)
	expectClosed(t, f.dial(t, token, daemon.id, relay.Lane(9)), codes.InvalidArgument)

	ctx := metadata.AppendToOutgoingContext(t.Context(), "authorization", "Bearer "+token, "x-dieter-client-version", buildinfo.ReleaseVersion)
	stream, err := gatewayv1.NewRelayServiceClient(f.connection).OpenTunnel(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := stream.Send(clientData([]byte("not an open"))); err != nil {
		t.Fatal(err)
	}
	expectClosed(t, stream, codes.InvalidArgument)

	if _, err := receive(t, f.dial(t, "invalid-session", daemon.id, relay.Command)); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("invalid session opened a tunnel: %v", err)
	}
	outdated := metadata.AppendToOutgoingContext(t.Context(), "authorization", "Bearer "+token, "x-dieter-client-version", "not-a-version")
	stream, err = gatewayv1.NewRelayServiceClient(f.connection).OpenTunnel(outdated)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := receive(t, stream); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("incompatible client opened a tunnel: %v", err)
	}
}

func TestTunnelReportsTheDaemonsRefusal(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	daemon := f.enroll(t, tunnelOwner)
	f.connect(t, daemon)
	client := f.dial(t, f.session(t, tunnelOwner), daemon.id, relay.Command)
	link := daemon.links[relay.Command]
	open := link.expect(t, gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPEN)
	if open.GetDaemonId() != daemon.id || open.GetLane() != relay.Command {
		t.Fatalf("tunnel open = %v", open)
	}
	link.send(t, &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE, StreamId: open.GetStreamId(), StatusCode: int32(codes.Unavailable), StatusMessage: "direct route is not listening"})
	expectClosed(t, client, codes.Unavailable)
	waitForTunnels(t, f, daemon.id, 0)
}

func TestSigningOutClosesOpenTunnels(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	daemon := f.enroll(t, tunnelOwner)
	f.connect(t, daemon)
	client := f.dial(t, f.session(t, tunnelOwner), daemon.id, relay.Command)
	link := daemon.links[relay.Command]
	id := link.accept(t)
	expectClient(t, client, gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPENED)
	f.signOut(t, tunnelOwner)
	select {
	case frame := <-link.frames:
		if frame.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE || frame.GetStreamId() != id || codes.Code(frame.GetStatusCode()) != codes.Unauthenticated {
			t.Fatalf("daemon frame after sign-out = %v", frame)
		}
	case <-time.After(sessionCheckInterval + tunnelWait):
		t.Fatal("signed-out tunnel stayed open")
	}
	if _, err := receive(t, client); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("signed-out client stream ended with %v", err)
	}
	waitForTunnels(t, f, daemon.id, 0)
}

func TestDaemonLinkLossClosesItsTunnels(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	daemon := f.enroll(t, tunnelOwner)
	f.connect(t, daemon)
	client := f.dial(t, f.session(t, tunnelOwner), daemon.id, relay.Command)
	daemon.links[relay.Command].accept(t)
	expectClient(t, client, gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPENED)
	daemon.links[relay.Command].cancel()
	expectClosed(t, client, codes.Unavailable)
	// Revoking the machine closes the tunnels of its remaining lanes.
	other := f.dial(t, f.session(t, tunnelOwner), daemon.id, relay.Subscription)
	daemon.links[relay.Subscription].accept(t)
	expectClient(t, other, gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPENED)
	if _, err := f.server.Service.RevokeDaemon(context.WithValue(t.Context(), principalKey{}, Principal{GitHubID: tunnelOwner}), &gatewayv1.DaemonRef{DaemonId: daemon.id}); err != nil {
		t.Fatal(err)
	}
	expectClosed(t, other, codes.Unavailable)
}

func TestGatewayNoLongerServesTheDaemonAPI(t *testing.T) {
	t.Parallel()
	f := newTunnelFixture(t)
	daemon := f.enroll(t, tunnelOwner)
	f.connect(t, daemon)
	token := f.session(t, tunnelOwner)
	// The former plaintext relay paths are ordinary 404s, with or without a
	// session, and nothing reaches the daemon.
	transport := &http.Transport{Protocols: unencryptedHTTP2()}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: tunnelWait}
	for _, path := range []string{"/dieter.v1.MachineService/Health", "/dieter.v1.CardService/ListCards", "/dieter.v1.FutureService/Anything"} {
		request, err := http.NewRequest(http.MethodPost, "http://"+f.address+path, bytes.NewReader([]byte{0, 0, 0, 0, 0}))
		if err != nil {
			t.Fatal(err)
		}
		request.Header.Set("Content-Type", "application/grpc")
		request.Header.Set("Authorization", "Bearer "+token)
		request.Header.Set("X-Dieter-Daemon-Id", daemon.id)
		response, err := client.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		_ = response.Body.Close()
		if response.StatusCode != http.StatusNotFound || response.Header.Get("Grpc-Status") != "" {
			t.Fatalf("%s answered %d %v", path, response.StatusCode, response.Header)
		}
	}
	connection, err := grpc.NewClient(f.address, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	ctx := metadata.AppendToOutgoingContext(t.Context(), "authorization", "Bearer "+token, "x-dieter-daemon-id", daemon.id, "x-dieter-client-version", buildinfo.ReleaseVersion)
	if err := connection.Invoke(ctx, "/dieter.v1.MachineService/Health", &gatewayv1.DaemonRef{}, &gatewayv1.DaemonRef{}); status.Code(err) == codes.OK {
		t.Fatal("the gateway answered a daemon API call")
	}
	select {
	case frame := <-daemon.links[relay.Control].frames:
		t.Fatalf("a daemon API call reached the daemon: %v", frame)
	case frame := <-daemon.links[relay.Command].frames:
		t.Fatalf("a daemon API call reached the daemon: %v", frame)
	default:
	}
}

// Not parallel: it counts the process's goroutines.
func TestTunnelsReleaseTheirGoroutines(t *testing.T) {
	f := newTunnelFixture(t)
	daemon := f.enroll(t, tunnelOwner)
	f.connect(t, daemon)
	token := f.session(t, tunnelOwner)
	link := daemon.links[relay.Command]
	cycle := func(daemonCloses bool) {
		ctx, cancel := context.WithCancel(t.Context())
		defer cancel()
		ctx = metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+token, "x-dieter-client-version", buildinfo.ReleaseVersion)
		client, err := gatewayv1.NewRelayServiceClient(f.connection).OpenTunnel(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err := client.Send(&gatewayv1.TunnelFrame{Kind: gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPEN, DaemonId: daemon.id, Lane: relay.Command}); err != nil {
			t.Fatal(err)
		}
		id := link.accept(t)
		expectClient(t, client, gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPENED)
		if err := client.Send(clientData([]byte("payload"))); err != nil {
			t.Fatal(err)
		}
		link.expect(t, gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_DATA)
		if daemonCloses {
			link.send(t, &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE, StreamId: id})
			expectClosed(t, client, codes.OK)
		} else {
			cancel()
			link.expect(t, gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE)
		}
		waitForTunnels(t, f, daemon.id, 0)
	}
	cycle(true)
	cycle(false)
	baseline := runtime.NumGoroutine()
	for i := range 16 {
		cycle(i%2 == 0)
	}
	deadline := time.Now().Add(tunnelWait)
	for runtime.NumGoroutine() > baseline+2 {
		if time.Now().After(deadline) {
			t.Fatalf("%d goroutines after closing every tunnel; %d before", runtime.NumGoroutine(), baseline)
		}
		time.Sleep(10 * time.Millisecond)
	}
}
