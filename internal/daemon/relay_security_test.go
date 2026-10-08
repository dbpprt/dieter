package daemon

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"io"
	"log/slog"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/relaypolicy"
	"github.com/dbpprt/dieter/internal/rpcraw"
	"github.com/dbpprt/dieter/internal/trust"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestRelayBinaryMetadataIsSafeForProtobuf(t *testing.T) {
	values := firstMetadata(metadata.MD{"trace-bin": {string([]byte{0xff, 0, 0x80})}, "result": {"retained"}, "Authorization": {"secret"}, "Cookie": {"secret"}, "X-Dieter-Operator-Subject": {"secret"}})
	frame := &gatewayv1.DaemonLinkFrame{Metadata: values}
	raw, err := proto.Marshal(frame)
	if err != nil {
		t.Fatal("binary metadata broke relay serialization", err)
	}
	decoded := &gatewayv1.DaemonLinkFrame{}
	if err := proto.Unmarshal(raw, decoded); err != nil {
		t.Fatal(err)
	}
	value, err := base64.StdEncoding.DecodeString(decoded.Metadata["trace-bin"])
	if err != nil || string(value) != string([]byte{0xff, 0, 0x80}) || decoded.Metadata["result"] != "retained" || len(decoded.Metadata) != 2 {
		t.Fatalf("binary metadata or credential filtering changed: %v, %v", decoded.Metadata, err)
	}
}

func relaySecurityFixture(t *testing.T) (*GatewayClient, ed25519.PrivateKey, *grpc.ClientConn, *atomic.Int32) {
	t.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(public)
	if err != nil {
		t.Fatal(err)
	}
	c := &GatewayClient{
		Identity: &Identity{ID: "d_security", GatewayURL: "https://gateway.example", Generation: 2, GatewaySigningPublicKey: pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})},
		Log:      slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	var calls atomic.Int32
	local := grpc.NewServer(grpc.ForceServerCodec(rpcraw.Codec{}), grpc.UnknownServiceHandler(func(_ any, stream grpc.ServerStream) error {
		var request rpcraw.Message
		if err := stream.RecvMsg(&request); err != nil {
			return err
		}
		calls.Add(1)
		values, _ := metadata.FromIncomingContext(stream.Context())
		if got := values.Get("x-dieter-operator-subject"); len(got) != 1 || got[0] != "github:123" {
			return status.Error(codes.Unauthenticated, "operator subject is missing")
		}
		return stream.SendMsg(&rpcraw.Message{Data: []byte("isolated-response")})
	}))
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go local.Serve(listener)
	t.Cleanup(local.Stop)
	connection, err := grpc.NewClient(listener.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { connection.Close() })
	return c, private, connection, &calls
}

func signedRelayFrame(t *testing.T, c *GatewayClient, private ed25519.PrivateKey, alter func(*gatewayv1.DaemonLinkFrame, *trust.DelegationClaims)) *gatewayv1.DaemonLinkFrame {
	t.Helper()
	frame := &gatewayv1.DaemonLinkFrame{DaemonId: c.Identity.ID, Generation: c.Identity.Generation, StreamId: 1, RequestId: "request-1", Method: "/dieter.v1.DieterService/Health", Payload: []byte("request")}
	digest := sha256.Sum256(frame.Payload)
	claims := trust.DelegationClaims{
		Issuer: c.Identity.GatewayURL, Audience: "board-daemon:" + c.Identity.ID, Subject: "github:123", ID: "proof-1",
		RequestID: frame.RequestId, Method: frame.Method, Generation: frame.Generation, PayloadHash: base64.RawURLEncoding.EncodeToString(digest[:]),
		IssuedAt: time.Now().Unix(), ExpiresAt: time.Now().Add(30 * time.Second).Unix(),
	}
	if alter != nil {
		alter(frame, &claims)
	}
	var err error
	frame.DelegationAssertion, err = trust.SignCompact(private, claims)
	if err != nil {
		t.Fatal(err)
	}
	return frame
}

func invokeRelay(t *testing.T, c *GatewayClient, connection *grpc.ClientConn, frame *gatewayv1.DaemonLinkFrame) codes.Code {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	result := codes.Unknown
	c.relayLocal(ctx, connection, frame, func(_ context.Context, response *gatewayv1.DaemonLinkFrame, _ bool) bool {
		if response.Kind == gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RPC_ERROR || response.Kind == gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_END {
			result = codes.Code(response.StatusCode)
		}
		return true
	})
	return result
}

func TestRelayRejectsStaleEnrollmentAndTamperedTargets(t *testing.T) {
	for name, alter := range map[string]func(*gatewayv1.DaemonLinkFrame, *trust.DelegationClaims){
		"stale signed generation": func(frame *gatewayv1.DaemonLinkFrame, claims *trust.DelegationClaims) {
			frame.Generation--
			claims.Generation--
		},
		"wrong daemon frame": func(frame *gatewayv1.DaemonLinkFrame, _ *trust.DelegationClaims) { frame.DaemonId = "another-daemon" },
		"changed method": func(frame *gatewayv1.DaemonLinkFrame, _ *trust.DelegationClaims) {
			frame.Method = "/dieter.v1.DieterService/DeleteCard"
		},
		"changed payload": func(frame *gatewayv1.DaemonLinkFrame, _ *trust.DelegationClaims) { frame.Payload = []byte("changed") },
		"changed request": func(frame *gatewayv1.DaemonLinkFrame, _ *trust.DelegationClaims) { frame.RequestId = "another-request" },
		"expired assertion": func(_ *gatewayv1.DaemonLinkFrame, claims *trust.DelegationClaims) {
			claims.ExpiresAt = time.Now().Add(-time.Minute).Unix()
		},
		"missing subject": func(_ *gatewayv1.DaemonLinkFrame, claims *trust.DelegationClaims) { claims.Subject = "" },
	} {
		t.Run(name, func(t *testing.T) {
			c, private, connection, calls := relaySecurityFixture(t)
			frame := signedRelayFrame(t, c, private, alter)
			if got := invokeRelay(t, c, connection, frame); got != codes.Unauthenticated {
				t.Fatalf("relay status = %v, want Unauthenticated", got)
			}
			if got := calls.Load(); got != 0 {
				t.Fatalf("unauthorized relay invoked local daemon %d times", got)
			}
		})
	}
}

func TestRelayAssertionDispatchesAtMostOnce(t *testing.T) {
	c, private, connection, calls := relaySecurityFixture(t)
	frame := signedRelayFrame(t, c, private, nil)
	if got := invokeRelay(t, c, connection, frame); got != codes.OK {
		t.Fatalf("authorized relay status = %v", got)
	}
	frame.StreamId++
	if got := invokeRelay(t, c, connection, frame); got != codes.Unauthenticated {
		t.Fatalf("replayed assertion status = %v, want Unauthenticated", got)
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("same authorized request dispatched %d times, want 1", got)
	}
}

func TestRelayProofConsumptionIsAtomicAndBounded(t *testing.T) {
	c := &GatewayClient{}
	now := time.Now()
	claims := trust.DelegationClaims{ID: "same-proof", ExpiresAt: now.Add(30 * time.Second).Unix()}
	var accepted atomic.Int32
	var group sync.WaitGroup
	for range 64 {
		group.Go(func() {
			if c.consumeRelayProof(claims, now) == nil {
				accepted.Add(1)
			}
		})
	}
	group.Wait()
	if accepted.Load() != 1 {
		t.Fatalf("concurrent proof admissions = %d, want 1", accepted.Load())
	}
	c.relayProofs = make(map[string]int64, maxGatewayRelayProofs)
	for i := range maxGatewayRelayProofs {
		c.relayProofs[string(rune(i))] = claims.ExpiresAt
	}
	if code := status.Code(c.consumeRelayProof(claims, now)); code != codes.ResourceExhausted {
		t.Fatalf("full cache admission = %v, want ResourceExhausted", code)
	}
	if err := c.consumeRelayProof(claims, now.Add(41*time.Second)); err != nil {
		t.Fatalf("expired proof entries were not reclaimed: %v", err)
	}
}

func TestDaemonRejectsCleartextGatewayBeforeDialOrEnrollment(t *testing.T) {
	identity := &Identity{GatewayURL: "http://gateway.example"}
	if connection, err := dialGateway(context.Background(), identity, false); err == nil {
		connection.Close()
		t.Fatal("daemon accepted a remote cleartext gateway")
	}
	if _, err := LoadOrCreateEnrollmentIdentity(t.TempDir(), "security-test", identity.GatewayURL); err == nil {
		t.Fatal("enrollment accepted a remote cleartext gateway")
	}
}

func TestCanceledRelayEscapesSaturatedResponseQueue(t *testing.T) {
	for _, priority := range []bool{false, true} {
		t.Run(map[bool]string{false: "stream", true: "command"}[priority], func(t *testing.T) {
			c, private, connection, calls := relaySecurityFixture(t)
			frame := signedRelayFrame(t, c, private, func(frame *gatewayv1.DaemonLinkFrame, claims *trust.DelegationClaims) {
				if !priority {
					frame.Method = "/dieter.v1.DieterService/WatchChanges"
					claims.Method = frame.Method
				}
			})
			linkCtx, closeLink := context.WithCancel(t.Context())
			defer closeLink()
			callCtx, cancel := context.WithCancel(linkCtx)
			defer cancel()
			queue := relaypolicy.NewQueue(&relaypolicy.Budget{})
			defer queue.Close()
			for range 8 {
				if err := queue.Add(&gatewayv1.DaemonLinkFrame{StreamId: 1}); err != nil {
					t.Fatal(err)
				}
			}
			entered, done := make(chan struct{}), make(chan struct{})
			go func() {
				defer close(done)
				c.relayLocal(callCtx, connection, frame, func(ctx context.Context, response *gatewayv1.DaemonLinkFrame, _ bool) bool {
					close(entered)
					return queue.AddWait(ctx, response) == nil
				})
			}()
			select {
			case <-entered:
			case <-time.After(2 * time.Second):
				t.Fatal("RPC did not reach response queue")
			}
			cancel()
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("canceled relay retained its worker behind a full queue")
			}
			if linkCtx.Err() != nil || queue.Bytes() == 0 || calls.Load() != 1 {
				t.Fatal("cancel affected the link or dispatched another operation")
			}
			frame = signedRelayFrame(t, c, private, func(frame *gatewayv1.DaemonLinkFrame, claims *trust.DelegationClaims) {
				frame.StreamId = 2
				frame.RequestId = "next"
				claims.RequestID = "next"
				claims.ID = "next-proof"
			})
			if got := invokeRelay(t, c, connection, frame); got != codes.OK {
				t.Fatalf("next independent relay failed: %v", got)
			}
		})
	}
}

func TestRelayResponseAdmissionHonorsBothCancellationScopes(t *testing.T) {
	for _, cancelRPC := range []bool{true, false} {
		linkCtx, cancelLink := context.WithCancel(t.Context())
		callCtx, cancelCall := context.WithCancel(linkCtx)
		queue := relaypolicy.NewQueue(&relaypolicy.Budget{})
		if cancelRPC {
			cancelCall()
		} else {
			cancelLink()
		}
		if queue.AddWait(callCtx, &gatewayv1.DaemonLinkFrame{}) == nil || queue.Bytes() != 0 {
			t.Error("enqueued response after cancellation")
		}
		cancelCall()
		cancelLink()
		queue.Close()
	}
}

type stalledControlGateway struct {
	gatewayv1.UnimplementedDaemonLinkServiceServer
	generation uint64
	alterAck   func(*gatewayv1.DaemonLinkFrame)
}

func (g *stalledControlGateway) Connect(stream grpc.BidiStreamingServer[gatewayv1.DaemonLinkFrame, gatewayv1.DaemonLinkFrame]) error {
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
	ack := &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO_ACK, ReleaseVersion: "0.4.1-dev", Compatibility: gatewayv1.CompatibilityStatus_COMPATIBILITY_STATUS_COMPATIBLE, DaemonId: hello.GetDaemonId(), Generation: g.generation, Lane: hello.Lane, SessionId: hello.SessionId}
	if g.alterAck != nil {
		g.alterAck(ack)
	}
	if err := stream.Send(ack); err != nil {
		return err
	}
	if g.alterAck != nil {
		<-stream.Context().Done()
		return stream.Context().Err()
	}
	// Stop reading after handshake. The daemon's output flow-control window
	// fills, then control admission must close the link instead of blocking
	// the receive loop behind RPC responses or waiting for caller shutdown.
	for range 20_000 {
		if err := stream.Send(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_OPEN_RPC}); err != nil {
			return err
		}
	}
	<-stream.Context().Done()
	return stream.Context().Err()
}

func TestGatewayMustAcknowledgeCurrentRelayContract(t *testing.T) {
	for name, alter := range map[string]func(*gatewayv1.DaemonLinkFrame){
		"missing process session": func(f *gatewayv1.DaemonLinkFrame) { f.SessionId = "" },
		"another process session": func(f *gatewayv1.DaemonLinkFrame) { f.SessionId = strings.Repeat("0", 64) },
		"another lane":            func(f *gatewayv1.DaemonLinkFrame) { f.Lane = relaypolicy.Command },
	} {
		t.Run(name, func(t *testing.T) {
			c, private, local, _ := relaySecurityFixture(t)
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			gateway := grpc.NewServer()
			gatewayv1.RegisterDaemonLinkServiceServer(gateway, &stalledControlGateway{generation: c.Identity.Generation, alterAck: alter})
			go func() { _ = gateway.Serve(listener) }()
			t.Cleanup(gateway.Stop)
			c.Identity.GatewayURL, c.Identity.PrivateKey = "http://"+listener.Addr().String(), private
			c.LocalTarget = local.Target()
			c.OnAcknowledged = func(time.Time) { t.Error("incompatible relay was declared connected") }
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			_, err = c.runOnce(ctx)
			if err == nil || !strings.Contains(err.Error(), "did not acknowledge the relay lane") {
				t.Fatalf("incompatible relay contract accepted: %v", err)
			}
		})
	}
}

func TestStalledGatewayControlQueueClosesLinkWithoutCallerCancellation(t *testing.T) {
	c, private, local, _ := relaySecurityFixture(t)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	gateway := grpc.NewServer(grpc.StaticStreamWindowSize(65535), grpc.StaticConnWindowSize(65535))
	gatewayv1.RegisterDaemonLinkServiceServer(gateway, &stalledControlGateway{generation: c.Identity.Generation})
	go func() { _ = gateway.Serve(listener) }()
	t.Cleanup(gateway.Stop)
	c.Identity.GatewayURL, c.Identity.PrivateKey = "http://"+listener.Addr().String(), private
	c.LocalTarget = local.Target()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	_, err = c.runOnce(ctx)
	if ctx.Err() != nil || err == nil || !strings.Contains(err.Error(), "control queue is stalled") {
		t.Fatalf("stalled tunnel: err=%v caller=%v", err, ctx.Err())
	}
}
