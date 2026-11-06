package link

import (
	"bytes"
	"context"
	"crypto/rand"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/transport/relay"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
)

// echoServer accepts connections and echoes every byte; closed reports each
// connection that ended.
func echoServer(t *testing.T) (string, chan struct{}) {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	closed := make(chan struct{}, 64)
	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				_, _ = io.Copy(connection, connection)
				_ = connection.Close()
				closed <- struct{}{}
			}()
		}
	}()
	return listener.Addr().String(), closed
}

// linkGateway is a gateway's side of one daemon lane: it completes the
// handshake and then hands frames to the test.
type linkGateway struct {
	gatewayv1.UnimplementedDaemonLinkServiceServer
	generation uint64
	streams    chan grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame]
}

func (g *linkGateway) Connect(stream grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame]) error {
	hello, err := stream.Recv()
	if err != nil {
		return err
	}
	if err := stream.Send(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PING, DaemonId: hello.GetDaemonId(), Payload: make([]byte, 32)}); err != nil {
		return err
	}
	if _, err := stream.Recv(); err != nil {
		return err
	}
	if err := stream.Send(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO_ACK, ReleaseVersion: "0.4.1-dev", Compatibility: gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_COMPATIBLE, DaemonId: hello.GetDaemonId(), Generation: g.generation, Lane: hello.Lane, SessionId: hello.SessionId}); err != nil {
		return err
	}
	g.streams <- stream
	<-stream.Context().Done()
	return stream.Context().Err()
}

// linkedDaemon runs a daemon's control lane against a test gateway whose
// tunnels reach target.
func linkedDaemon(t *testing.T, target string) (*GatewayClient, grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame], context.CancelFunc, chan error) {
	t.Helper()
	identity, _ := testIdentity(t, "d_tunnel", "Tunnel")
	gateway := &linkGateway{generation: identity.Generation, streams: make(chan grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame], 1)}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer()
	gatewayv1.RegisterDaemonLinkServiceServer(server, gateway)
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(server.Stop)
	identity.GatewayURL = "http://" + listener.Addr().String()
	client := &GatewayClient{Identity: identity, TunnelTarget: target, Version: "0.4.1-dev", Log: testLogger()}
	ctx, cancel := context.WithCancel(t.Context())
	result := make(chan error, 1)
	go func() {
		_, err := client.runOnce(ctx)
		result <- err
	}()
	select {
	case stream := <-gateway.streams:
		return client, stream, cancel, result
	case err := <-result:
		t.Fatalf("link ended before the handshake: %v", err)
	case <-time.After(testkit.Budget(10 * time.Second)):
		t.Fatal("link handshake timed out")
	}
	return nil, nil, nil, nil
}

// tunnelFrames collects the daemon's frames per tunnel.
type tunnelFrames struct {
	mu     sync.Mutex
	frames map[uint64][]*gatewayv1.DaemonLinkFrame
	wake   chan struct{}
}

func collectFrames(stream grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame]) *tunnelFrames {
	collected := &tunnelFrames{frames: map[uint64][]*gatewayv1.DaemonLinkFrame{}, wake: make(chan struct{}, 1)}
	go func() {
		for {
			frame, err := stream.Recv()
			if err != nil {
				return
			}
			collected.mu.Lock()
			collected.frames[frame.GetStreamId()] = append(collected.frames[frame.GetStreamId()], frame)
			collected.mu.Unlock()
			select {
			case collected.wake <- struct{}{}:
			default:
			}
		}
	}()
	return collected
}

// next waits for the next frame of id that matches kind.
func (c *tunnelFrames) next(t *testing.T, id uint64, kind gatewayv1.DaemonLinkFrameKind) *gatewayv1.DaemonLinkFrame {
	t.Helper()
	deadline := time.After(testkit.Budget(10 * time.Second))
	for {
		c.mu.Lock()
		for index, frame := range c.frames[id] {
			if frame.GetKind() == kind {
				c.frames[id] = append(c.frames[id][:index:index], c.frames[id][index+1:]...)
				c.mu.Unlock()
				return frame
			}
		}
		c.mu.Unlock()
		select {
		case <-c.wake:
		case <-time.After(10 * time.Millisecond):
		case <-deadline:
			t.Fatalf("tunnel %d: no %v frame", id, kind)
		}
	}
}

func openFrame(id uint64, daemonID string, lane relay.Lane) *gatewayv1.DaemonLinkFrame {
	return &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPEN, StreamId: id, DaemonId: daemonID, Lane: lane}
}

func dataFrame(id uint64, data []byte) *gatewayv1.DaemonLinkFrame {
	return &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_DATA, StreamId: id, Payload: data}
}

func TestDaemonLinkSplicesTunnelsWithEndToEndCredits(t *testing.T) {
	t.Parallel()
	target, closed := echoServer(t)
	client, stream, cancel, done := linkedDaemon(t, target)
	frames := collectFrames(stream)
	id := client.Identity.ID
	if err := stream.Send(openFrame(1, id, relay.Control)); err != nil {
		t.Fatal(err)
	}
	frames.next(t, 1, gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPENED)
	// More than a window of data in both directions: the echo can only flow
	// while each side returns credit after writing a frame to its socket.
	payload := make([]byte, 3*relay.TunnelWindow*1024)
	_, _ = rand.Read(payload)
	sent, credits := 0, relay.TunnelWindow
	var echoed []byte
	for len(echoed) < len(payload) {
		for credits > 0 && sent < len(payload) {
			chunk := payload[sent:min(sent+1024, len(payload))]
			if err := stream.Send(dataFrame(1, chunk)); err != nil {
				t.Fatal(err)
			}
			sent += len(chunk)
			credits--
		}
		frames.mu.Lock()
		pending := append([]*gatewayv1.DaemonLinkFrame(nil), frames.frames[1]...)
		frames.frames[1] = nil
		frames.mu.Unlock()
		for _, frame := range pending {
			switch frame.GetKind() {
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_WINDOW:
				credits += int(frame.GetCredit())
			case gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_DATA:
				if len(frame.GetPayload()) > relay.ChunkBytes {
					t.Fatal("daemon sent an oversized frame")
				}
				echoed = append(echoed, frame.GetPayload()...)
				if err := stream.Send(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_WINDOW, StreamId: 1, Credit: 1}); err != nil {
					t.Fatal(err)
				}
			default:
				t.Fatalf("unexpected frame %v", frame)
			}
		}
		if credits > relay.TunnelWindow {
			t.Fatalf("daemon granted %d credits", credits)
		}
		if len(echoed) >= len(payload) {
			break
		}
		select {
		case <-frames.wake:
		case <-time.After(testkit.Budget(5 * time.Second)):
			t.Fatalf("echo stalled at %d of %d bytes", len(echoed), len(payload))
		}
	}
	if !bytes.Equal(echoed, payload) {
		t.Fatal("tunnel bytes changed")
	}
	// A peer that ignores its window resets only its own tunnel.
	if err := stream.Send(openFrame(2, id, relay.Control)); err != nil {
		t.Fatal(err)
	}
	frames.next(t, 2, gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPENED)
	// Without credit for its echo, the endpoint and then the daemon stop
	// consuming, so a sender that ignores the window soon exceeds it.
	big := make([]byte, relay.ChunkBytes)
	var reset *gatewayv1.DaemonLinkFrame
	for sent := 0; reset == nil; sent++ {
		if sent > 1024 {
			t.Fatal("an unbounded sender was never reset")
		}
		if err := stream.Send(dataFrame(2, big)); err != nil {
			t.Fatal(err)
		}
		frames.mu.Lock()
		for _, frame := range frames.frames[2] {
			if frame.GetKind() == gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE {
				reset = frame
			}
		}
		frames.mu.Unlock()
	}
	if codes.Code(reset.GetStatusCode()) == codes.OK {
		t.Fatal("window violation closed without an error status")
	}
	if err := stream.Send(dataFrame(1, []byte("still open"))); err != nil {
		t.Fatal(err)
	}
	if echo := frames.next(t, 1, gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_DATA); string(echo.GetPayload()) != "still open" {
		t.Fatalf("other tunnel affected: %q", echo.GetPayload())
	}
	// A link disconnect closes the remaining tunnel's socket.
	cancel()
	<-done
	for range 2 {
		select {
		case <-closed:
		case <-time.After(testkit.Budget(5 * time.Second)):
			t.Fatal("tunnel socket outlived its link")
		}
	}
}

func TestDaemonLinkRefusesInvalidAndExcessTunnels(t *testing.T) {
	t.Parallel()
	target, _ := echoServer(t)
	client, stream, cancel, done := linkedDaemon(t, target)
	defer func() {
		cancel()
		<-done
	}()
	frames := collectFrames(stream)
	id := client.Identity.ID
	for index, open := range []*gatewayv1.DaemonLinkFrame{openFrame(1, "d_other", relay.Control), openFrame(2, id, relay.Command)} {
		if err := stream.Send(open); err != nil {
			t.Fatal(err)
		}
		if refused := frames.next(t, open.GetStreamId(), gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE); codes.Code(refused.GetStatusCode()) != codes.InvalidArgument {
			t.Fatalf("invalid open %d: %v", index, refused)
		}
	}
	limit := relay.TunnelLimit(relay.Control)
	for index := range limit {
		if err := stream.Send(openFrame(uint64(10+index), id, relay.Control)); err != nil {
			t.Fatal(err)
		}
		frames.next(t, uint64(10+index), gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPENED)
	}
	if err := stream.Send(openFrame(99, id, relay.Control)); err != nil {
		t.Fatal(err)
	}
	if refused := frames.next(t, 99, gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE); codes.Code(refused.GetStatusCode()) != codes.ResourceExhausted {
		t.Fatalf("excess tunnel: %v", refused)
	}
	// Closing a tunnel frees its slot.
	if err := stream.Send(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE, StreamId: 10}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(testkit.Budget(5 * time.Second))
	for {
		if err := stream.Send(openFrame(100, id, relay.Control)); err != nil {
			t.Fatal(err)
		}
		frames.mu.Lock()
		frames.frames[100] = nil
		frames.mu.Unlock()
		select {
		case <-frames.wake:
		case <-time.After(50 * time.Millisecond):
		}
		frames.mu.Lock()
		var opened bool
		for _, frame := range frames.frames[100] {
			opened = opened || frame.GetKind() == gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_OPENED
		}
		frames.mu.Unlock()
		if opened {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("a closed tunnel kept its slot")
		}
	}
}

func TestDaemonLinkClosesTunnelsToAnUnavailableEndpoint(t *testing.T) {
	t.Parallel()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	target := listener.Addr().String()
	_ = listener.Close()
	client, stream, cancel, done := linkedDaemon(t, target)
	defer func() {
		cancel()
		<-done
	}()
	frames := collectFrames(stream)
	if err := stream.Send(openFrame(1, client.Identity.ID, relay.Control)); err != nil {
		t.Fatal(err)
	}
	if refused := frames.next(t, 1, gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_TUNNEL_CLOSE); codes.Code(refused.GetStatusCode()) != codes.Unavailable {
		t.Fatalf("unreachable endpoint: %v", refused)
	}
}

// relayGateway answers OpenTunnel like the gateway with an echoing daemon,
// and checks that the client respects its window.
type relayGateway struct {
	gatewayv1.UnimplementedRelayServiceServer
	refuse   codes.Code
	opened   chan *gatewayv1.TunnelFrame
	violated chan string
}

func (g *relayGateway) OpenTunnel(stream grpc.BidiStreamingServer[gatewayv1.TunnelFrame, gatewayv1.TunnelFrame]) error {
	open, err := stream.Recv()
	if err != nil {
		return err
	}
	g.opened <- open
	if g.refuse != codes.OK {
		return stream.Send(&gatewayv1.TunnelFrame{Kind: gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_CLOSE, StatusCode: int32(g.refuse), StatusMessage: "refused"})
	}
	if err := stream.Send(&gatewayv1.TunnelFrame{Kind: gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPENED}); err != nil {
		return err
	}
	outstanding, credits := 0, relay.TunnelWindow
	var queue [][]byte
	for {
		frame, err := stream.Recv()
		if err != nil {
			return nil
		}
		switch frame.GetKind() {
		case gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_DATA:
			if outstanding++; outstanding > relay.TunnelWindow {
				g.violated <- "client exceeded its window"
				return nil
			}
			queue = append(queue, frame.GetData())
			// The echoing daemon consumed the frame.
			outstanding--
			if err := stream.Send(&gatewayv1.TunnelFrame{Kind: gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_WINDOW, Credit: 1}); err != nil {
				return err
			}
		case gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_WINDOW:
			credits += int(frame.GetCredit())
		case gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_CLOSE:
			return nil
		}
		for credits > 0 && len(queue) > 0 {
			if err := stream.Send(&gatewayv1.TunnelFrame{Kind: gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_DATA, Data: queue[0]}); err != nil {
				return err
			}
			queue, credits = queue[1:], credits-1
		}
	}
}

func relayConnection(t *testing.T, gateway *relayGateway) *grpc.ClientConn {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer()
	gatewayv1.RegisterRelayServiceServer(server, gateway)
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(server.Stop)
	connection, err := grpc.NewClient(listener.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = connection.Close() })
	return connection
}

func TestDialTunnelCarriesBytesWithinTheWindow(t *testing.T) {
	t.Parallel()
	gateway := &relayGateway{opened: make(chan *gatewayv1.TunnelFrame, 1), violated: make(chan string, 1)}
	connection := relayConnection(t, gateway)
	conn, err := DialTunnel(t.Context(), connection, "d_target", relay.Replication)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if open := <-gateway.opened; open.GetKind() != gatewayv1.TunnelFrameKind_TUNNEL_FRAME_KIND_OPEN || open.GetDaemonId() != "d_target" || open.GetLane() != relay.Replication {
		t.Fatalf("open frame %v", open)
	}
	payload := make([]byte, 2<<20)
	_, _ = rand.Read(payload)
	go func() { _, _ = conn.Write(payload) }()
	echoed := make([]byte, len(payload))
	_ = conn.SetReadDeadline(time.Now().Add(testkit.Budget(20 * time.Second)))
	if _, err := io.ReadFull(conn, echoed); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(echoed, payload) {
		t.Fatal("tunnel bytes changed")
	}
	select {
	case violation := <-gateway.violated:
		t.Fatal(violation)
	default:
	}
}

func TestDialTunnelReportsARefusal(t *testing.T) {
	t.Parallel()
	gateway := &relayGateway{refuse: codes.ResourceExhausted, opened: make(chan *gatewayv1.TunnelFrame, 1), violated: make(chan string, 1)}
	connection := relayConnection(t, gateway)
	if _, err := DialTunnel(t.Context(), connection, "d_target", relay.Command); status.Code(err) != codes.ResourceExhausted || !strings.Contains(err.Error(), "refused") {
		t.Fatalf("refused tunnel: %v", err)
	}
	if _, err := DialTunnel(t.Context(), connection, "", relay.Command); err == nil {
		t.Fatal("tunnel without a target")
	}
}
