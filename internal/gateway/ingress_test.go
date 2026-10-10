package gateway

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/binary"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/iotest"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func grpcEnvelopeHeader(size uint32, compressed byte) []byte {
	header := make([]byte, 5)
	header[0] = compressed
	binary.BigEndian.PutUint32(header[1:], size)
	return header
}

func TestPublicGatewayEnvelopeRejectedBeforeExposingAllocationSize(t *testing.T) {
	for _, limit := range []uint32{publicGatewayMessageBytes, maxDaemonPresenceBytes} {
		for _, compressed := range []byte{0, 1} {
			header := grpcEnvelopeHeader(limit+1, compressed)
			if compressed != 0 {
				header = grpcEnvelopeHeader(1, compressed)
			}
			source := bytes.NewReader(append(header, bytes.Repeat([]byte{0}, 100)...))
			reader := limitGatewayEnvelopes(t.Context(), io.NopCloser(iotest.OneByteReader(source)), 2, limit)
			buffer := make([]byte, 4096)
			for range 2 {
				if n, err := reader.Read(buffer); n != 0 || status.Code(err) != codes.ResourceExhausted {
					t.Fatalf("limit=%d compression=%d: exposed %d bytes, error=%v", limit, compressed, n, err)
				}
			}
			if source.Len() != 100 {
				t.Fatal("oversized message payload was read")
			}
			_ = reader.Close()
		}
	}
}

func TestDaemonEnvelopeBoundsBothHelloAndProof(t *testing.T) {
	hello := append(grpcEnvelopeHeader(maxDaemonPresenceBytes, 0), make([]byte, maxDaemonPresenceBytes)...)
	source := bytes.NewReader(append(hello, grpcEnvelopeHeader(maxRelayPayload, 0)...))
	reader := limitGatewayEnvelopes(t.Context(), io.NopCloser(source), 2, maxDaemonPresenceBytes)
	defer reader.Close()
	got, err := io.ReadAll(reader)
	if !bytes.Equal(got, hello) || status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("read %d bytes, error=%v; proof envelope escaped its bound", len(got), err)
	}
}

func TestDaemonEnvelopeReadAheadWaitsForProofOrClose(t *testing.T) {
	for _, authenticate := range []bool{false, true} {
		t.Run(map[bool]string{false: "close", true: "authenticate"}[authenticate], func(t *testing.T) {
			source := bytes.NewReader(append(make([]byte, 10), []byte("authenticated relay payload")...))
			reader := limitGatewayEnvelopes(t.Context(), io.NopCloser(source), 2, maxDaemonPresenceBytes)
			defer reader.Close()
			ready := make(chan struct{})
			reader.authenticated = ready
			if _, err := io.ReadFull(reader, make([]byte, 10)); err != nil {
				t.Fatal(err)
			}
			result := make(chan error, 1)
			go func() {
				_, err := io.ReadFull(reader, make([]byte, len("authenticated relay payload")))
				result <- err
			}()
			select {
			case err := <-result:
				t.Fatalf("read ahead before proof: %v", err)
			case <-time.After(20 * time.Millisecond):
			}
			if authenticate {
				close(ready)
			} else {
				_ = reader.Close()
			}
			select {
			case err := <-result:
				if authenticate && err != nil || !authenticate && err != context.Canceled {
					t.Fatalf("read after authentication/close: %v", err)
				}
			case <-time.After(time.Second):
				t.Fatal("body reader did not unblock")
			}
		})
	}
}

func TestGatewayClientAddressTrustBoundary(t *testing.T) {
	for _, test := range []struct {
		name, remote string
		proxy        bool
		forwarded    []string
		want         string
	}{
		{"direct spoof", "192.0.2.1:42", false, []string{"198.51.100.1"}, "192.0.2.1"},
		{"nonproxy loopback", "127.0.0.1:42", false, []string{"198.51.100.1"}, "127.0.0.1"},
		{"untrusted proxy", "192.0.2.1:42", true, []string{"198.51.100.1"}, "192.0.2.1"},
		{"trusted proxy", "127.0.0.1:42", true, []string{"198.51.100.1"}, "198.51.100.1"},
		{"IPv6 proxy", "[::1]:42", true, []string{"2001:db8::1"}, "2001:db8::1"},
		{"mapped IPv4", "127.0.0.1:42", true, []string{"::ffff:198.51.100.1"}, "198.51.100.1"},
		{"chain", "127.0.0.1:42", true, []string{"192.0.2.1, 198.51.100.1"}, "127.0.0.1"},
		{"duplicate headers", "127.0.0.1:42", true, []string{"192.0.2.1", "198.51.100.1"}, "127.0.0.1"},
		{"hostname", "127.0.0.1:42", true, []string{"attacker.example"}, "127.0.0.1"},
		{"address with port", "127.0.0.1:42", true, []string{"192.0.2.1:42"}, "127.0.0.1"},
		{"zone", "127.0.0.1:42", true, []string{"fe80::1%lo0"}, "127.0.0.1"},
		{"no header", "127.0.0.1:42", true, nil, "127.0.0.1"},
	} {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "/", nil)
			request.RemoteAddr = test.remote
			request.Header["X-Forwarded-For"] = test.forwarded
			if got := gatewayClientAddress(request, test.proxy); got != test.want {
				t.Fatalf("client address=%q, want %q", got, test.want)
			}
		})
	}
}

func TestProxyAuthRateLimitsArePerClient(t *testing.T) {
	auth := NewAuth(Config{ProxyMode: true}, nil, nil)
	request := httptest.NewRequest(http.MethodGet, "/auth/github/start", nil)
	request.RemoteAddr = "127.0.0.1:42"
	request.Header.Set("X-Forwarded-For", "192.0.2.1")
	for range 30 {
		if !auth.allow(request) {
			t.Fatal("first client exhausted early")
		}
	}
	if auth.allow(request) {
		t.Fatal("exhausted client was allowed")
	}
	request.Header.Set("X-Forwarded-For", "192.0.2.2")
	if !auth.allow(request) {
		t.Fatal("one client's limit blocked another")
	}
}

func TestProxyEnrollmentRateLimitsThroughHTTP2(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	gateway, err := NewServer(Config{ProxyMode: true}, store, nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(gateway.APIGRPC.Stop)
	t.Cleanup(gateway.RelayGRPC.Stop)
	server, err := gateway.httpServer()
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Close() })
	connection, err := grpc.NewClient(listener.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	client := gatewayv1.NewGatewayServiceClient(connection)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	first := metadata.NewOutgoingContext(ctx, metadata.Pairs("x-forwarded-for", "192.0.2.1"))
	for range 10 {
		_, err := client.BeginDaemonEnrollment(first, &gatewayv1.BeginDaemonEnrollmentRequest{})
		if status.Code(err) != codes.InvalidArgument {
			t.Fatalf("first client exhausted early: %v", err)
		}
	}
	if _, err := client.BeginDaemonEnrollment(first, &gatewayv1.BeginDaemonEnrollmentRequest{}); status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("first client escaped limit: %v", err)
	}
	second := metadata.NewOutgoingContext(ctx, metadata.Pairs("x-forwarded-for", "192.0.2.2"))
	if _, err := client.BeginDaemonEnrollment(second, &gatewayv1.BeginDaemonEnrollmentRequest{}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("first client blocked second: %v", err)
	}
}

func TestGatewayRejectsOversizedEnvelopesThroughTLSProxyWithoutPayload(t *testing.T) {
	gateway, frontend := securityTLSProxy(t, Config{AllowedUserIDs: map[int64]struct{}{1234: {}}})
	public, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := x509.MarshalPKIXPublicKey(public)
	if err != nil {
		t.Fatal(err)
	}
	enrollment, err := gateway.Service.BeginDaemonEnrollment(t.Context(), &gatewayv1.BeginDaemonEnrollmentRequest{Name: "bounded ingress", PublicKey: encoded})
	if err != nil {
		t.Fatal(err)
	}
	if err := gateway.Store.ApproveEnrollment(enrollment.GetEnrollmentId(), enrollment.GetUserCode(), 1234, "test"); err != nil {
		t.Fatal(err)
	}
	credential, err := gateway.Service.CompleteDaemonEnrollment(t.Context(), &gatewayv1.CompleteDaemonEnrollmentRequest{EnrollmentId: enrollment.GetEnrollmentId(), EnrollmentSecret: enrollment.GetEnrollmentSecret()})
	if err != nil {
		t.Fatal(err)
	}
	hello, err := proto.Marshal(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO, DaemonId: credential.GetDaemonId(), SessionId: strings.Repeat("a", 64), Generation: credential.GetGeneration()})
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name, path string
		prefix     []byte
		compressed byte
	}{
		{"hello", "/dieter.gateway.v1.DaemonLinkService/Connect", nil, 0},
		{"proof", "/dieter.gateway.v1.DaemonLinkService/Connect", append(grpcEnvelopeHeader(uint32(len(hello)), 0), hello...), 0},
		{"compressed hello", "/dieter.gateway.v1.DaemonLinkService/Connect", nil, 1},
		{"enrollment", "/dieter.gateway.v1.GatewayService/BeginDaemonEnrollment", nil, 0},
		{"compatibility", "/dieter.gateway.v1.GatewayService/GetCompatibility", nil, 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			// Advertise 16 MiB but send only the envelope. The gateway must
			// reject its size instead of allocating and reporting a short body.
			prefix := append(bytes.Clone(test.prefix), grpcEnvelopeHeader(maxRelayPayload, test.compressed)...)
			ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
			defer cancel()
			request, err := http.NewRequestWithContext(ctx, http.MethodPost, frontend.URL+test.path, bytes.NewReader(prefix))
			if err != nil {
				t.Fatal(err)
			}
			request.Header.Set("Content-Type", "application/grpc")
			request.Header.Set("TE", "trailers")
			response, err := frontend.Client().Do(request)
			if err != nil {
				t.Fatal(err)
			}
			defer response.Body.Close()
			if _, err := io.Copy(io.Discard, response.Body); err != nil {
				t.Fatal(err)
			}
			code := response.Trailer.Get("Grpc-Status")
			if code == "" {
				code = response.Header.Get("Grpc-Status")
			}
			// grpc-go maps streaming Body read errors to Unavailable while
			// retaining the original limit error; unary decoding retains its code.
			if code != "8" && !(code == "14" && strings.Contains(response.Trailer.Get("Grpc-Message"), "ResourceExhausted")) {
				t.Fatalf("envelope rejection status=%q, headers=%v, trailers=%v", code, response.Header, response.Trailer)
			}
		})
	}
}

func TestGatewayRejectsExcessHandshakesBeforeReadingBody(t *testing.T) {
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	gateway, err := NewServer(Config{}, store, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer gateway.APIGRPC.Stop()
	defer gateway.RelayGRPC.Stop()
	for range cap(gateway.Hub.handshakes) {
		gateway.Hub.handshakes <- struct{}{}
	}
	body := &repeatedBody{}
	request := httptest.NewRequest(http.MethodPost, "/dieter.gateway.v1.DaemonLinkService/Connect", body)
	request.ProtoMajor = 2
	response := httptest.NewRecorder()
	gateway.HTTPHandler.ServeHTTP(response, request)
	if response.Header().Get("Grpc-Status") != "8" || body.read != 0 {
		t.Fatalf("excess handshake read %d bytes, headers=%v", body.read, response.Header())
	}
}

func TestTLSProxyForwardingCannotBeSpoofed(t *testing.T) {
	gateway, frontend := securityTLSProxy(t, Config{})
	for i := range 31 {
		request, err := http.NewRequest(http.MethodGet, frontend.URL+"/auth/github/start", nil)
		if err != nil {
			t.Fatal(err)
		}
		request.Header.Set("X-Forwarded-For", "192.0.2.1")
		request.Header.Set("Forwarded", "for=198.51.100.1")
		response, err := frontend.Client().Do(request)
		if err != nil {
			t.Fatal(err)
		}
		response.Body.Close()
		if i == 30 && response.StatusCode != http.StatusTooManyRequests {
			t.Fatalf("spoofed headers bypassed rate limit: %d", response.StatusCode)
		}
	}
	for address := range gateway.Auth.rates {
		if address != "127.0.0.1" && address != "::/64" {
			t.Fatalf("untrusted forwarded address used: %s", address)
		}
	}
}
