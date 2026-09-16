package daemon

import (
	"context"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/gateway"
	"github.com/dbpprt/dieter/internal/rpcraw"
	"github.com/dbpprt/dieter/internal/trust"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

func TestDirectTLSExpiryReleasesStalledNetworkStreams(t *testing.T) {
	for _, stallResponse := range []bool{false, true} {
		t.Run(map[bool]string{false: "request", true: "response"}[stallResponse], func(t *testing.T) {
			keys, err := gateway.LoadOrCreateKeys(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			identity, err := LoadOrCreateEnrollmentIdentity(t.TempDir(), "security", "https://gateway.example")
			if err != nil {
				t.Fatal(err)
			}
			public, err := identity.PublicKeyDER()
			if err != nil {
				t.Fatal(err)
			}
			certificate, expires, err := keys.IssueDaemonCertificate("d_stall", public)
			if err != nil {
				t.Fatal(err)
			}
			signing, err := keys.SigningPublicPEM()
			if err != nil {
				t.Fatal(err)
			}
			if err := identity.SaveCredential("d_stall", "security", certificate, keys.DaemonCAPEM, signing, expires.Format(time.RFC3339Nano), 1); err != nil {
				t.Fatal(err)
			}
			localStopped := make(chan struct{})
			var responses atomic.Int32
			local := grpc.NewServer(grpc.ForceServerCodec(rpcraw.Codec{}), grpc.UnknownServiceHandler(func(_ any, stream grpc.ServerStream) error {
				defer close(localStopped)
				var request rpcraw.Message
				if err := stream.RecvMsg(&request); err != nil {
					return err
				}
				response := &rpcraw.Message{Data: make([]byte, 256<<10)}
				for {
					if err := stream.SendMsg(response); err != nil {
						return err
					}
					responses.Add(1)
				}
			}))
			listener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			go func() { _ = local.Serve(listener) }()
			t.Cleanup(local.Stop)
			direct, err := NewDirectServer(identity, listener.Addr().String())
			if err != nil {
				t.Fatal(err)
			}
			publicListener, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Fatal(err)
			}
			go func() { _ = direct.Serve(publicListener) }()
			t.Cleanup(direct.Stop)
			now := time.Now()
			token, err := trust.SignCompact(keys.SigningPrivate, trust.DaemonTokenClaims{
				Issuer: identity.GatewayURL, Subject: "github:123", Audience: "board-daemon:" + identity.ID, ID: "dt_stall", DaemonGeneration: 1,
				IssuedAt: now.Add(-time.Minute).Unix(), NotBefore: now.Add(-time.Minute).Unix(), ExpiresAt: now.Add(-8 * time.Second).Unix(),
			})
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			connection, err := DialDirect(ctx, publicListener.Addr().String(), identity.ID, identity.DaemonCAPEM, token)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = connection.Close() })
			stream, err := connection.NewStream(ctx, &grpc.StreamDesc{ServerStreams: true}, "/dieter.v1.DieterService/WatchState", grpc.ForceCodec(rpcraw.Codec{}))
			if err != nil {
				t.Fatal(err)
			}
			if stallResponse {
				if err := stream.SendMsg(&rpcraw.Message{Data: []byte("request")}); err != nil {
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
				case <-time.After(3 * time.Second):
					t.Fatal("stalled output retained the local RPC beyond token expiry")
				}
				if responses.Load() == 0 {
					t.Fatal("response stream never started")
				}
			} else {
				_, err := stream.Header()
				if err == nil {
					err = stream.RecvMsg(&rpcraw.Message{})
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
			for direct.active.Load() != 0 && time.Now().Before(deadline) {
				time.Sleep(time.Millisecond)
			}
			if direct.active.Load() != 0 {
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

func (directTestTransportStream) Method() string               { return "/dieter.v1.DieterService/Health" }
func (directTestTransportStream) SetHeader(metadata.MD) error  { return nil }
func (directTestTransportStream) SendHeader(metadata.MD) error { return nil }
func (directTestTransportStream) SetTrailer(metadata.MD) error { return nil }

func TestDirectTokenExpiryTerminatesStalledRPC(t *testing.T) {
	c, private, connection, calls := relaySecurityFixture(t)
	claims := trust.DaemonTokenClaims{
		Issuer: c.Identity.GatewayURL, Subject: "github:123", Audience: "board-daemon:" + c.Identity.ID,
		ID: "dt_expiry-test", DaemonGeneration: c.Identity.Generation,
		IssuedAt: time.Now().Add(-time.Minute).Unix(), NotBefore: time.Now().Add(-time.Minute).Unix(),
		// Still accepted under clock skew; remaining lifetime is at most 1s.
		ExpiresAt: time.Now().Add(-9 * time.Second).Unix(),
	}
	token, err := trust.SignCompact(private, claims)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	ctx = metadata.NewIncomingContext(ctx, metadata.Pairs("authorization", "Bearer "+token))
	ctx = grpc.NewContextWithServerTransportStream(ctx, directTestTransportStream{})
	s := &DirectServer{identity: c.Identity, local: connection}
	started := time.Now()
	err = s.handle(nil, stalledDirectStream{ctx: ctx})
	if status.Code(err) != codes.DeadlineExceeded {
		t.Fatalf("expired direct RPC status = %v, want DeadlineExceeded", err)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("direct RPC remained open beyond its token expiry: %s", elapsed)
	}
	if calls.Load() != 0 {
		t.Fatal("stalled request reached the local daemon")
	}
}

type immediateDirectStream struct{ stalledDirectStream }

func (immediateDirectStream) RecvMsg(message any) error {
	message.(*rpcraw.Message).Data = []byte("request")
	return nil
}
func (immediateDirectStream) SendMsg(any) error { return nil }

func TestDirectRejectsRTCEnvelopeAsBearerCredential(t *testing.T) {
	c, private, connection, calls := relaySecurityFixture(t)
	envelope := trust.RTCConfigurationClaims{
		Issuer: c.Identity.GatewayURL, Subject: "github:123", Audience: "board-daemon:" + c.Identity.ID,
		ID: "rtc_configuration", ConfigurationHash: "signed-config-hash", DaemonGeneration: c.Identity.Generation,
		IssuedAt: time.Now().Unix(), ExpiresAt: time.Now().Add(time.Minute).Unix(),
	}
	token, err := trust.SignCompact(private, envelope)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	ctx = metadata.NewIncomingContext(ctx, metadata.Pairs("authorization", "Bearer "+token))
	ctx = grpc.NewContextWithServerTransportStream(ctx, directTestTransportStream{})
	s := &DirectServer{identity: c.Identity, local: connection}
	err = s.handle(nil, immediateDirectStream{stalledDirectStream{ctx: ctx}})
	if status.Code(err) != codes.Unauthenticated {
		t.Fatalf("RTC envelope accepted as a direct bearer token: %v", err)
	}
	if calls.Load() != 0 {
		t.Fatal("RTC envelope dispatched a local daemon RPC")
	}
}

func TestDirectRPCAdmissionIsBoundedAndReleased(t *testing.T) {
	c, private, connection, calls := relaySecurityFixture(t)
	now := time.Now()
	claims := trust.DaemonTokenClaims{
		Issuer: c.Identity.GatewayURL, Subject: "github:123", Audience: "board-daemon:" + c.Identity.ID,
		ID: "dt_capacity-test", DaemonGeneration: c.Identity.Generation,
		IssuedAt: now.Unix(), NotBefore: now.Add(-5 * time.Second).Unix(), ExpiresAt: now.Add(time.Minute).Unix(),
	}
	token, err := trust.SignCompact(private, claims)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	ctx = metadata.NewIncomingContext(ctx, metadata.Pairs("authorization", "Bearer "+token))
	ctx = grpc.NewContextWithServerTransportStream(ctx, directTestTransportStream{})
	s := &DirectServer{identity: c.Identity, local: connection}
	var group sync.WaitGroup
	for range maxActiveDirectRPCs {
		group.Go(func() { _ = s.handle(nil, stalledDirectStream{ctx: ctx}) })
	}
	deadline := time.Now().Add(time.Second)
	for s.active.Load() != maxActiveDirectRPCs && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if got := s.active.Load(); got != maxActiveDirectRPCs {
		t.Fatalf("active direct RPCs = %d, want %d", got, maxActiveDirectRPCs)
	}
	if err := s.handle(nil, stalledDirectStream{ctx: ctx}); status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("saturated direct admission = %v, want ResourceExhausted", err)
	}
	cancel()
	group.Wait()
	if s.active.Load() != 0 || calls.Load() != 0 {
		t.Fatalf("direct cancellation retained %d admissions or dispatched %d stalled requests", s.active.Load(), calls.Load())
	}
}
