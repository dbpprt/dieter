package daemon

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/rpcraw"
	"github.com/dbpprt/dieter/internal/trust"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

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
