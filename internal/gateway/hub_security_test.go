package gateway

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"io"
	"log/slog"
	"net"
	"net/url"
	"strconv"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/linkauth"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
)

type securityLinkStream struct {
	grpc.ServerStream
	ctx  context.Context
	recv chan *gatewayv1.DaemonLinkFrame
	sent chan *gatewayv1.DaemonLinkFrame
}

func (s *securityLinkStream) Context() context.Context { return s.ctx }
func (s *securityLinkStream) Recv() (*gatewayv1.DaemonLinkFrame, error) {
	select {
	case value := <-s.recv:
		return value, nil
	case <-s.ctx.Done():
		return nil, s.ctx.Err()
	}
}
func (s *securityLinkStream) Send(value *gatewayv1.DaemonLinkFrame) error {
	select {
	case s.sent <- value:
		return nil
	case <-s.ctx.Done():
		return s.ctx.Err()
	}
}

func newSecurityLinkStream(t *testing.T) *securityLinkStream {
	t.Helper()
	ctx, cancel := context.WithCancel(t.Context())
	t.Cleanup(cancel)
	return &securityLinkStream{ctx: ctx, recv: make(chan *gatewayv1.DaemonLinkFrame, 2), sent: make(chan *gatewayv1.DaemonLinkFrame, 2)}
}

func TestDaemonHandshakeBoundsIdleUnauthenticatedConnections(t *testing.T) {
	hub := NewHub(nil, Config{})
	stream := newSecurityLinkStream(t)
	if err := hub.connect(stream, 20*time.Millisecond); status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("idle handshake = %v", err)
	}
	if len(hub.handshakes) != 0 {
		t.Fatal("timed-out handshake retained admission")
	}
	for range cap(hub.handshakes) {
		hub.handshakes <- struct{}{}
	}
	if err := hub.Connect(stream); status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("excess handshake = %v", err)
	}
}

func TestDaemonHandshakeRejectsOversizedPresenceBeforeLoadingIdentity(t *testing.T) {
	hub := NewHub(nil, Config{})
	stream := newSecurityLinkStream(t)
	stream.recv <- &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO, DaemonId: "unknown-daemon", Payload: make([]byte, maxDaemonPresenceBytes)}
	if err := hub.Connect(stream); status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("oversized unauthenticated presence = %v", err)
	}
}

func TestDaemonHandshakeRejectsWrongKeyAndReplayedProof(t *testing.T) {
	service, private, credential := newEnrolledSecurityService(t)
	hub := service.hub
	_, wrongPrivate, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	var captured []byte
	for _, test := range []struct {
		name  string
		valid bool
		sign  func([]byte) []byte
	}{
		{"valid", true, func(challenge []byte) []byte {
			captured = linkauth.Sign(private, service.config.PublicURL.String(), credential.GetDaemonId(), challenge)
			return captured
		}},
		{"replay", false, func([]byte) []byte { return captured }},
		{"wrong key", false, func(challenge []byte) []byte {
			return linkauth.Sign(wrongPrivate, service.config.PublicURL.String(), credential.GetDaemonId(), challenge)
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			stream := newSecurityLinkStream(t)
			stream.recv <- &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO, DaemonId: credential.GetDaemonId()}
			result := make(chan daemonHandshake, 1)
			go func() { result <- hub.authenticateLink(stream, time.Second) }()
			challenge := <-stream.sent
			stream.recv <- &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG, DaemonId: credential.GetDaemonId(), RequestId: challenge.GetRequestId(), Payload: test.sign(challenge.GetPayload())}
			authenticated := <-result
			if test.valid && authenticated.err != nil {
				t.Fatal(authenticated.err)
			}
			if !test.valid && status.Code(authenticated.err) != codes.Unauthenticated {
				t.Fatalf("invalid proof = %v", authenticated.err)
			}
		})
	}
}

func TestDaemonHandshakeRejectsRemovedAccount(t *testing.T) {
	service, _, credential := newEnrolledSecurityService(t)
	service.hub.config.AllowedUserID++
	stream := newSecurityLinkStream(t)
	stream.recv <- &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO, DaemonId: credential.GetDaemonId()}
	if err := service.hub.Connect(stream); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("removed account opened a tunnel: %v", err)
	}
}

type blockedSecurityLinkStream struct {
	*securityLinkStream
	blocked chan struct{}
}

func (s *blockedSecurityLinkStream) Send(frame *gatewayv1.DaemonLinkFrame) error {
	if frame.GetKind() == gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_OPEN_RPC {
		close(s.blocked)
	}
	return s.securityLinkStream.Send(frame)
}

func TestDaemonRevocationClosesTransportEvenWhenSendIsBlocked(t *testing.T) {
	service, private, credential := newEnrolledSecurityService(t)
	stream := &blockedSecurityLinkStream{securityLinkStream: newSecurityLinkStream(t), blocked: make(chan struct{})}
	stream.sent = make(chan *gatewayv1.DaemonLinkFrame, 1)
	result := make(chan error, 1)
	go func() { result <- service.hub.Connect(stream) }()
	stream.recv <- &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO, DaemonId: credential.GetDaemonId()}
	challenge := <-stream.sent
	stream.recv <- &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_PONG, DaemonId: credential.GetDaemonId(), RequestId: challenge.GetRequestId(), Payload: linkauth.Sign(private, service.config.PublicURL.String(), credential.GetDaemonId(), challenge.GetPayload())}
	if ack := <-stream.sent; ack.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_HELLO_ACK {
		t.Fatalf("handshake acknowledgement = %v", ack)
	}
	// Leave the simulated peer's receive window full while the gateway opens
	// an RPC. Its Send and Recv are now both blocked on the transport.
	stream.sent <- &gatewayv1.DaemonLinkFrame{}
	relay, err := service.hub.Open(t.Context(), credential.GetDaemonId(), &gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_OPEN_RPC})
	if err != nil {
		t.Fatal(err)
	}
	defer relay.Close()
	<-stream.blocked
	service.hub.CloseDaemon(credential.GetDaemonId())
	select {
	case <-result:
	case <-time.After(time.Second):
		t.Fatal("revocation did not terminate the blocked daemon transport")
	}
}

func TestEnrollmentRatePeerStateIsBoundedAndExpires(t *testing.T) {
	service := NewService(nil, nil, nil, nil, Config{})
	for i := range maxEnrollmentRatePeers {
		service.enrollAttempts[strconv.Itoa(i)] = []time.Time{time.Now()}
	}
	ctx := peer.NewContext(t.Context(), &peer.Peer{Addr: &net.TCPAddr{IP: net.ParseIP("192.0.2.1"), Port: 1234}})
	if service.allowEnrollment(ctx) || len(service.enrollAttempts) != maxEnrollmentRatePeers {
		t.Fatal("enrollment peer state exceeded its bound")
	}
	for key := range service.enrollAttempts {
		service.enrollAttempts[key] = []time.Time{time.Now().Add(-2 * time.Minute)}
	}
	if !service.allowEnrollment(ctx) || len(service.enrollAttempts) != 1 {
		t.Fatal("expired enrollment peers were not reclaimed")
	}
}

func newEnrolledSecurityService(t *testing.T) (*Service, ed25519.PrivateKey, *gatewayv1.DaemonCredential) {
	t.Helper()
	store, err := OpenStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	keys, err := LoadOrCreateKeys(store.Root)
	if err != nil {
		t.Fatal(err)
	}
	publicURL, _ := url.Parse("https://gateway.example")
	config := Config{PublicURL: publicURL, AllowedUserID: 1234, AuthSecret: []byte("security-test-secret-not-a-real-secret")}
	auth := NewAuth(config, store, slog.New(slog.NewTextHandler(io.Discard, nil)))
	service := NewService(store, auth, keys, NewHub(store, config), config)
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := x509.MarshalPKIXPublicKey(public)
	if err != nil {
		t.Fatal(err)
	}
	enrollment, err := service.BeginDaemonEnrollment(t.Context(), &gatewayv1.BeginDaemonEnrollmentRequest{Name: "Security test daemon", PublicKey: encoded})
	if err != nil {
		t.Fatal(err)
	}
	if err := store.ApproveEnrollment(enrollment.GetEnrollmentId(), enrollment.GetUserCode(), config.AllowedUserID, "security-test"); err != nil {
		t.Fatal(err)
	}
	credential, err := service.CompleteDaemonEnrollment(t.Context(), &gatewayv1.CompleteDaemonEnrollmentRequest{EnrollmentId: enrollment.GetEnrollmentId(), EnrollmentSecret: enrollment.GetEnrollmentSecret()})
	if err != nil {
		t.Fatal(err)
	}
	return service, private, credential
}
