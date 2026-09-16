package gateway

import (
	"context"
	"io"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/rpcraw"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestRelayCanceledOpenDoesNotWaitForSharedSendQueue(t *testing.T) {
	hub, link := newTestRelayHub(t)
	for range cap(link.send) {
		link.send <- &gatewayv1.DaemonLinkFrame{}
	}
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() {
		_, err := hub.Open(ctx, link.id, &gatewayv1.DaemonLinkFrame{})
		done <- err
	}()
	cancel()
	select {
	case err := <-done:
		if status.Code(err) != codes.Canceled {
			t.Fatalf("canceled admission = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled admission is blocked on the shared send queue")
	}
	link.mu.RLock()
	defer link.mu.RUnlock()
	if len(link.streams) != 0 {
		t.Fatal("canceled admission retained a stream slot")
	}
}

type securityRelayStream struct {
	grpc.ServerStream
	ctx     context.Context
	receive func(any) error
}

func (s *securityRelayStream) Context() context.Context  { return s.ctx }
func (s *securityRelayStream) RecvMsg(message any) error { return s.receive(message) }

func TestRelayRechecksSessionAndDaemonAfterDelayedRequestBody(t *testing.T) {
	for _, revoke := range []string{"session", "daemon"} {
		t.Run(revoke, func(t *testing.T) {
			service, _, credential := newEnrolledSecurityService(t)
			const token = "isolated-security-test-session"
			if err := service.store.UpdateAuthState(func(state *AuthState) error {
				state.Sessions = append(state.Sessions, Session{TokenHash: service.auth.digest(token), GitHubID: service.config.AllowedUserID, ExpiresAt: time.Now().Add(time.Hour)})
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			ctx := context.WithValue(t.Context(), principalKey{}, Principal{GitHubID: service.config.AllowedUserID})
			stream := &securityRelayStream{ctx: ctx, receive: func(message any) error {
				message.(*rpcraw.Message).Data = nil
				if revoke == "session" {
					return service.store.UpdateAuthState(func(state *AuthState) error { state.Sessions = nil; return nil })
				}
				_, err := service.store.RevokeDaemon(credential.GetDaemonId(), service.config.AllowedUserID)
				return err
			}}
			handler := &relayHandler{store: service.store, auth: service.auth, keys: service.keys, hub: service.hub, config: service.config}
			err := handler.relayAuthenticated(stream, "/dieter.v1.DieterService/Health", credential.GetDaemonId(), "Bearer "+token)
			want := codes.Unauthenticated
			if revoke == "daemon" {
				want = codes.NotFound
			}
			if status.Code(err) != want {
				t.Fatalf("%s revoked while receiving request: %v; want %v", revoke, err, want)
			}
		})
	}
}

func TestRelayRejectsOtherAccountBeforeReadingRequestBody(t *testing.T) {
	service, _, credential := newEnrolledSecurityService(t)
	ctx := context.WithValue(t.Context(), principalKey{}, Principal{GitHubID: service.config.AllowedUserID + 1})
	stream := &securityRelayStream{ctx: ctx, receive: func(any) error {
		t.Fatal("cross-account request reached body admission")
		return nil
	}}
	handler := &relayHandler{store: service.store, auth: service.auth, keys: service.keys, hub: service.hub, config: service.config}
	if err := handler.relayAuthenticated(stream, "/dieter.v1.DieterService/Health", credential.GetDaemonId(), "Bearer irrelevant"); status.Code(err) != codes.NotFound {
		t.Fatalf("cross-account relay = %v", err)
	}
}

func TestRelayCancellationReleasesOnlyItsStreamWithFullSendQueue(t *testing.T) {
	hub, link := newTestRelayHub(t)
	healthy, err := hub.Open(t.Context(), link.id, &gatewayv1.DaemonLinkFrame{})
	if err != nil {
		t.Fatal(err)
	}
	defer healthy.Close()
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	canceled, err := hub.Open(ctx, link.id, &gatewayv1.DaemonLinkFrame{})
	if err != nil {
		t.Fatal(err)
	}
	for len(link.send) < cap(link.send) {
		link.send <- &gatewayv1.DaemonLinkFrame{}
	}
	cancel()
	finished := make(chan error, 1)
	go func() { _, err := canceled.Recv(); finished <- err }()
	select {
	case err := <-finished:
		if err != io.EOF {
			t.Fatalf("canceled receiver = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("canceled relay held its stream while the shared send queue was full")
	}
	select {
	case frame := <-link.control:
		if frame.GetKind() != gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_CANCEL_RPC || frame.GetStreamId() != canceled.id {
			t.Fatalf("cancellation targeted the wrong stream: %v", frame)
		}
	case <-time.After(time.Second):
		t.Fatal("cancellation was not sent through the control queue")
	}
	link.dispatch(&gatewayv1.DaemonLinkFrame{Kind: gatewayv1.DaemonLinkFrameKind_DAEMON_LINK_FRAME_KIND_RESPONSE_MESSAGE, StreamId: healthy.id, Payload: []byte("healthy")})
	frame, err := healthy.Recv()
	if err != nil || string(frame.GetPayload()) != "healthy" {
		t.Fatalf("unrelated stream was canceled: %v, %v", frame, err)
	}
}

func TestRelayClosedDaemonIsImmediatelyOffline(t *testing.T) {
	hub, link := newTestRelayHub(t)
	hub.CloseDaemon(link.id)
	if hub.Online(link.id) {
		t.Fatal("closed daemon remains online until the heartbeat lease expires")
	}
}
