package link

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/security/roster"
	"github.com/dbpprt/dieter/internal/security/trust"
	"github.com/dbpprt/dieter/internal/testkit"
	"github.com/dbpprt/dieter/internal/transport/relay"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
)

// testDevice is a device key and its roster descriptor.
type testDevice struct {
	key        crypto.Signer
	descriptor *roster.Descriptor
}

func newTestDevice(t *testing.T, kind gatewayv1.DeviceKind, daemonID string) testDevice {
	t.Helper()
	var key crypto.Signer
	var err error
	if kind == gatewayv1.DeviceKind_DEVICE_KIND_DAEMON {
		_, key, err = ed25519.GenerateKey(rand.Reader)
	} else {
		key, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	}
	if err != nil {
		t.Fatal(err)
	}
	descriptor, err := roster.Describe(kind, "jvm", "Device "+daemonID, daemonID, key.Public())
	if err != nil {
		t.Fatal(err)
	}
	return testDevice{key: key, descriptor: descriptor}
}

func (d testDevice) id() string { return d.descriptor.GetDeviceId() }

func (d testDevice) certificate(t *testing.T) tls.Certificate {
	t.Helper()
	certificate, err := DeviceCertificate(d.key)
	if err != nil {
		t.Fatal(err)
	}
	return certificate
}

// directFixture is a daemon whose roster holds a member daemon, an app and a
// revoked app, serving a recording local API through its DirectServer.
type directFixture struct {
	identity             *Identity
	signingKey           ed25519.PrivateKey
	trust                *Trust
	server               *DirectServer
	address              string
	member, app, revoked testDevice
	outsider             testDevice
	calls                atomic.Int32
	mu                   sync.Mutex
	forwarded            metadata.MD
}

func newDirectFixture(t *testing.T, handler func(grpc.ServerStream) error) *directFixture {
	t.Helper()
	identity, signingKey := testIdentity(t, "d_direct", "Direct")
	f := &directFixture{
		identity: identity, signingKey: signingKey,
		member:   newTestDevice(t, gatewayv1.DeviceKind_DEVICE_KIND_DAEMON, "d_member"),
		app:      newTestDevice(t, gatewayv1.DeviceKind_DEVICE_KIND_CLIENT, ""),
		revoked:  newTestDevice(t, gatewayv1.DeviceKind_DEVICE_KIND_CLIENT, ""),
		outsider: newTestDevice(t, gatewayv1.DeviceKind_DEVICE_KIND_CLIENT, ""),
	}
	self := testkit.DaemonSigner(t, identity.PrivateKey, identity.ID, "Direct")
	state := testkit.PinRoster(t, identity.Root, testkit.TestAccount, self, f.member.descriptor, f.app.descriptor, f.revoked.descriptor)
	revoke, err := state.Revoke(f.revoked.id(), self)
	if err != nil {
		t.Fatal(err)
	}
	if state, err = state.Extend([]*roster.Entry{revoke}); err != nil {
		t.Fatal(err)
	}
	testkit.WriteRoster(t, identity.Root, state)
	if f.trust, err = OpenTrust(identity, nil); err != nil {
		t.Fatal(err)
	}
	if handler == nil {
		handler = func(stream grpc.ServerStream) error {
			var request relay.RawMessage
			if err := stream.RecvMsg(&request); err != nil {
				return err
			}
			return stream.SendMsg(&relay.RawMessage{Data: request.Data})
		}
	}
	local := grpc.NewServer(grpc.ForceServerCodec(relay.RawCodec{}), grpc.UnknownServiceHandler(func(_ any, stream grpc.ServerStream) error {
		f.calls.Add(1)
		values, _ := metadata.FromIncomingContext(stream.Context())
		f.mu.Lock()
		f.forwarded = values
		f.mu.Unlock()
		return handler(stream)
	}))
	localListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = local.Serve(localListener) }()
	t.Cleanup(local.Stop)
	if f.server, err = NewDirectServer(identity, f.trust, localListener.Addr().String(), "local-token"); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() { _ = f.server.Serve(listener) }()
	t.Cleanup(f.server.Stop)
	f.address = listener.Addr().String()
	return f
}

func (f *directFixture) token(t *testing.T, thumbprint string) string {
	t.Helper()
	token, _ := testkit.DaemonToken(t, f.signingKey, f.identity.GatewayURL, f.identity.ID, f.identity.Generation, thumbprint, time.Minute)
	return token
}

func (f *directFixture) daemonKey(t *testing.T) []byte {
	t.Helper()
	key, err := f.identity.PublicKeyDER()
	if err != nil {
		t.Fatal(err)
	}
	return key
}

// call invokes one raw daemon RPC as device with token.
func (f *directFixture) call(t *testing.T, certificate tls.Certificate, serverKey []byte, token string, extra ...string) ([]byte, error) {
	t.Helper()
	connection, err := DialDaemon(certificate, serverKey, TokenCredentials(token), TCPDialer(f.address))
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	if len(extra) > 0 {
		ctx = metadata.AppendToOutgoingContext(ctx, extra...)
	}
	var response relay.RawMessage
	err = connection.Invoke(ctx, "/dieter.v1.MachineService/Health", &relay.RawMessage{Data: []byte("ping")}, &response, grpc.ForceCodec(relay.RawCodec{}))
	return response.Data, err
}

func TestDirectServerForwardsRosterDevicesWithFreshMetadata(t *testing.T) {
	t.Parallel()
	f := newDirectFixture(t, nil)
	for _, device := range []struct {
		device testDevice
		kind   string
	}{{f.app, "client"}, {f.member, "daemon"}} {
		response, err := f.call(t, device.device.certificate(t), f.daemonKey(t), f.token(t, device.device.id()),
			"x-dieter-operator-subject", "github:666", "x-dieter-turn-token", "forged", "x-dieter-device-id", f.outsider.id())
		if err != nil || string(response) != "ping" {
			t.Fatalf("%s call: %q %v", device.kind, response, err)
		}
		f.mu.Lock()
		forwarded := f.forwarded
		f.mu.Unlock()
		if got := forwarded.Get(OperatorSubjectMetadata); len(got) != 1 || got[0] != "github:42" {
			t.Fatalf("operator subject=%v", got)
		}
		if got := forwarded.Get(DeviceIDMetadata); len(got) != 1 || got[0] != device.device.id() {
			t.Fatalf("device id=%v", got)
		}
		if got := forwarded.Get(DeviceKindMetadata); len(got) != 1 || got[0] != device.kind {
			t.Fatalf("device kind=%v", got)
		}
		if len(forwarded.Get("x-dieter-turn-token")) != 0 {
			t.Fatal("caller metadata reached the local API")
		}
	}
}

func TestDirectServerRejectsUntrustedCallers(t *testing.T) {
	t.Parallel()
	f := newDirectFixture(t, nil)
	envelope, err := trust.SignCompact(f.signingKey, trust.RTCConfigurationClaims{
		Issuer: f.identity.GatewayURL, Subject: "github:42", Audience: "board-daemon:" + f.identity.ID,
		ID: "rtc_configuration", ConfigurationHash: "hash", DaemonGeneration: f.identity.Generation,
		IssuedAt: time.Now().Unix(), ExpiresAt: time.Now().Add(time.Minute).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name        string
		certificate tls.Certificate
		token       string
		want        codes.Code
	}{
		{"no client certificate", tls.Certificate{}, f.token(t, f.app.id()), codes.Unavailable},
		{"key outside the roster", f.outsider.certificate(t), f.token(t, f.outsider.id()), codes.Unavailable},
		{"revoked device", f.revoked.certificate(t), f.token(t, f.revoked.id()), codes.Unavailable},
		{"token bound to another device", f.app.certificate(t), f.token(t, f.member.id()), codes.Unauthenticated},
		{"token without a device", f.app.certificate(t), f.token(t, ""), codes.Unauthenticated},
		{"RTC envelope as bearer", f.app.certificate(t), envelope, codes.Unauthenticated},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := f.call(t, test.certificate, f.daemonKey(t), test.token)
			if status.Code(err) != test.want {
				t.Fatalf("status=%v, want %v", err, test.want)
			}
		})
	}
	if f.calls.Load() != 0 {
		t.Fatalf("an untrusted caller reached the local API %d times", f.calls.Load())
	}
}

func TestClientRefusesAServerWithoutTheRosterKey(t *testing.T) {
	t.Parallel()
	f := newDirectFixture(t, nil)
	memberKey, err := x509.MarshalPKIXPublicKey(f.member.key.Public())
	if err != nil {
		t.Fatal(err)
	}
	// The client expects the member daemon's key, but this endpoint is another
	// daemon: a gateway or network pointing a route elsewhere.
	if _, err := f.call(t, f.app.certificate(t), memberKey, f.token(t, f.app.id())); status.Code(err) != codes.Unavailable {
		t.Fatalf("client accepted another daemon: %v", err)
	}
	if _, err := DialDaemon(f.app.certificate(t), nil, TokenCredentials("token"), TCPDialer(f.address)); err == nil {
		t.Fatal("dialing without a roster key succeeded")
	}
	if f.calls.Load() != 0 {
		t.Fatal("a refused handshake reached the local API")
	}
}

func TestDirectTLSExpiryReleasesStalledNetworkStreams(t *testing.T) {
	t.Parallel()
	for _, stallResponse := range []bool{false, true} {
		t.Run(map[bool]string{false: "request", true: "response"}[stallResponse], func(t *testing.T) {
			localStopped := make(chan struct{})
			var responses atomic.Int32
			f := newDirectFixture(t, func(stream grpc.ServerStream) error {
				defer close(localStopped)
				var request relay.RawMessage
				if err := stream.RecvMsg(&request); err != nil {
					return err
				}
				response := &relay.RawMessage{Data: make([]byte, 256<<10)}
				for {
					if err := stream.SendMsg(response); err != nil {
						return err
					}
					responses.Add(1)
				}
			})
			now := time.Now()
			token, err := trust.SignCompact(f.signingKey, trust.DaemonTokenClaims{
				Issuer: f.identity.GatewayURL, Subject: "github:123", Audience: "board-daemon:" + f.identity.ID, ID: "dt_stall", DaemonGeneration: 1,
				IssuedAt: now.Add(-time.Minute).Unix(), NotBefore: now.Add(-time.Minute).Unix(), ExpiresAt: now.Add(-8 * time.Second).Unix(),
				ClientThumbprint: f.app.id(),
			})
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			connection, err := DialDaemon(f.app.certificate(t), f.daemonKey(t), TokenCredentials(token), TCPDialer(f.address))
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = connection.Close() })
			stream, err := connection.NewStream(ctx, &grpc.StreamDesc{ServerStreams: true}, "/dieter.v1.StateService/WatchChanges", grpc.ForceCodec(relay.RawCodec{}))
			if err != nil {
				t.Fatal(err)
			}
			if stallResponse {
				if err := stream.SendMsg(&relay.RawMessage{Data: []byte("request")}); err != nil {
					t.Fatal(err)
				}
				if err := stream.CloseSend(); err != nil {
					t.Fatal(err)
				}
				if _, err := stream.Header(); err != nil {
					t.Fatal(err)
				}
				// Never read the response: HTTP/2 flow control must stall the
				// forwarder, while credential expiry still releases admission.
				select {
				case <-localStopped:
				case <-time.After(testkit.Budget(30 * time.Second)):
					t.Fatal("stalled output retained the local RPC beyond token expiry")
				}
				if responses.Load() == 0 {
					t.Fatal("response stream never started")
				}
			} else {
				_, err := stream.Header()
				if err == nil {
					err = stream.RecvMsg(&relay.RawMessage{})
				}
				if status.Code(err) != codes.DeadlineExceeded {
					t.Fatalf("stalled request: %v", err)
				}
				select {
				case <-localStopped:
					t.Fatal("incomplete request reached daemon")
				default:
				}
			}
			deadline := time.Now().Add(time.Second)
			for f.server.active.Load() != 0 && time.Now().Before(deadline) {
				time.Sleep(time.Millisecond)
			}
			if f.server.active.Load() != 0 {
				t.Fatal("expired network stream retained direct admission")
			}
		})
	}
}

type stalledDirectStream struct{ ctx context.Context }

func (s stalledDirectStream) Context() context.Context   { return s.ctx }
func (stalledDirectStream) SetHeader(metadata.MD) error  { return nil }
func (stalledDirectStream) SendHeader(metadata.MD) error { return nil }
func (stalledDirectStream) SetTrailer(metadata.MD)       {}
func (stalledDirectStream) SendMsg(any) error            { return errors.New("unexpected response") }
func (s stalledDirectStream) RecvMsg(any) error {
	<-s.ctx.Done()
	return s.ctx.Err()
}

type directTestTransportStream struct{}

func (directTestTransportStream) Method() string               { return "/dieter.v1.MachineService/Health" }
func (directTestTransportStream) SetHeader(metadata.MD) error  { return nil }
func (directTestTransportStream) SendHeader(metadata.MD) error { return nil }
func (directTestTransportStream) SetTrailer(metadata.MD) error { return nil }

// handlerContext is the context of a direct RPC from device with token.
func (f *directFixture) handlerContext(t *testing.T, ctx context.Context, device testDevice, token string) context.Context {
	t.Helper()
	certificate := device.certificate(t)
	ctx = peer.NewContext(ctx, &peer.Peer{AuthInfo: credentials.TLSInfo{State: tls.ConnectionState{PeerCertificates: []*x509.Certificate{certificate.Leaf}}}})
	ctx = metadata.NewIncomingContext(ctx, metadata.Pairs("authorization", "Bearer "+token))
	return grpc.NewContextWithServerTransportStream(ctx, directTestTransportStream{})
}

func TestDirectTokenExpiryTerminatesStalledRPC(t *testing.T) {
	t.Parallel()
	f := newDirectFixture(t, nil)
	token, err := trust.SignCompact(f.signingKey, trust.DaemonTokenClaims{
		Issuer: f.identity.GatewayURL, Subject: "github:123", Audience: "board-daemon:" + f.identity.ID,
		ID: "dt_expiry-test", DaemonGeneration: f.identity.Generation, ClientThumbprint: f.app.id(),
		IssuedAt: time.Now().Add(-time.Minute).Unix(), NotBefore: time.Now().Add(-time.Minute).Unix(),
		// Still accepted under clock skew; remaining lifetime is at most 1s.
		ExpiresAt: time.Now().Add(-9 * time.Second).Unix(),
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	started := time.Now()
	err = f.server.handle(nil, stalledDirectStream{ctx: f.handlerContext(t, ctx, f.app, token)})
	if status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("expired direct RPC status = %v, want DeadlineExceeded", err)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("direct RPC remained open beyond its token expiry: %s", elapsed)
	}
	if f.calls.Load() != 0 {
		t.Fatal("stalled request reached the local daemon")
	}
}

func TestDirectRPCAdmissionIsBoundedAndReleased(t *testing.T) {
	t.Parallel()
	f := newDirectFixture(t, nil)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	ctx = f.handlerContext(t, ctx, f.app, f.token(t, f.app.id()))
	var group sync.WaitGroup
	for range maxActiveDirectRPCs {
		group.Go(func() { _ = f.server.handle(nil, stalledDirectStream{ctx: ctx}) })
	}
	deadline := time.Now().Add(time.Second)
	for f.server.active.Load() != maxActiveDirectRPCs && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got := f.server.active.Load(); got != maxActiveDirectRPCs {
		t.Fatalf("active direct RPCs = %d, want %d", got, maxActiveDirectRPCs)
	}
	if err := f.server.handle(nil, stalledDirectStream{ctx: ctx}); status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("saturated direct admission = %v, want ResourceExhausted", err)
	}
	cancel()
	group.Wait()
	if f.server.active.Load() != 0 || f.calls.Load() != 0 {
		t.Fatalf("direct cancellation retained %d admissions or dispatched %d stalled requests", f.server.active.Load(), f.calls.Load())
	}
}

func TestDirectServerRechecksMembershipPerCall(t *testing.T) {
	t.Parallel()
	f := newDirectFixture(t, nil)
	connection, err := DialDaemon(f.app.certificate(t), f.daemonKey(t), TokenCredentials(f.token(t, f.app.id())), TCPDialer(f.address))
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	invoke := func() error {
		var response relay.RawMessage
		return connection.Invoke(t.Context(), "/dieter.v1.MachineService/Health", &relay.RawMessage{Data: []byte("ping")}, &response, grpc.ForceCodec(relay.RawCodec{}))
	}
	if err := invoke(); err != nil {
		t.Fatal(err)
	}
	// The app is revoked while its connection stays open.
	state, _ := f.trust.snapshot()
	self := testkit.DaemonSigner(t, f.identity.PrivateKey, f.identity.ID, "Direct")
	revoke, err := state.Revoke(f.app.id(), self)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.trust.Offer([]*roster.Entry{revoke}); err != nil {
		t.Fatal(err)
	}
	if err := invoke(); status.Code(err) != codes.Unauthenticated {
		t.Fatalf("revoked device kept calling: %v", err)
	}
}
