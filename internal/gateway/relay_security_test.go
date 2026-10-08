package gateway

import (
	"context"
	"encoding/base64"
	"io"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/relaypolicy"
	"github.com/dbpprt/dieter/internal/rpcraw"
	statuspb "google.golang.org/genproto/googleapis/rpc/status"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func TestRelayMetadataAndStatusValidation(t *testing.T) {
	binary := string([]byte{0xff, 0, 0x80})
	values := frameMetadata(map[string]string{"trace-bin": base64.StdEncoding.EncodeToString([]byte(binary)), "invalid-bin": "!", "result": "retained", "Authorization": "secret", "X-Dieter-Operator-Subject": "secret"})
	if len(values) != 2 || values.Get("trace-bin")[0] != binary || values.Get("result")[0] != "retained" {
		t.Fatalf("relay metadata changed or leaked credentials: %v", values)
	}
	// A mismatched rich status cannot override the canonical terminal status.
	raw, err := proto.Marshal(&statuspb.Status{Code: int32(codes.PermissionDenied), Message: "different"})
	if err != nil {
		t.Fatal(err)
	}
	frame := &gatewayv1.DaemonLinkFrame{StatusCode: int32(codes.InvalidArgument), StatusMessage: "record rejected"}
	err = relayFrameStatus(frame, frameMetadata(map[string]string{"grpc-status-details-bin": base64.StdEncoding.EncodeToString(raw)}))
	if status.Code(err) != codes.InvalidArgument || status.Convert(err).Message() != "record rejected" {
		t.Fatalf("mismatched rich status overrode terminal status: %v", err)
	}
}

func TestRelayCanceledOpenDoesNotWaitForSharedSendQueue(t *testing.T) {
	hub, link := newTestRelayHub(t)
	reserved := int64(relaypolicy.BufferedBytes) - link.budget.Used()
	if !link.budget.Reserve(reserved) {
		t.Fatal("cannot fill outbound byte budget")
	}
	defer func() { link.budget.Release(reserved) }()
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
				state.Sessions = append(state.Sessions, Session{TokenHash: service.auth.digest(token), GitHubID: int64(1234), ExpiresAt: time.Now().Add(time.Hour)})
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			ctx := context.WithValue(t.Context(), principalKey{}, Principal{GitHubID: int64(1234)})
			stream := &securityRelayStream{ctx: ctx, receive: func(message any) error {
				message.(*rpcraw.Message).Data = nil
				if revoke == "session" {
					return service.store.UpdateAuthState(func(state *AuthState) error { state.Sessions = nil; return nil })
				}
				_, err := service.store.RevokeDaemon(credential.GetDaemonId(), int64(1234))
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
	ctx := context.WithValue(t.Context(), principalKey{}, Principal{GitHubID: int64(1234) + 1})
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
	reserved := int64(relaypolicy.BufferedBytes) - link.budget.Used()
	if !link.budget.Reserve(reserved) {
		t.Fatal("cannot fill outbound byte budget")
	}
	defer func() { link.budget.Release(reserved) }()
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
	link.budget.Release(reserved)
	reserved = 0
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

func TestRelayBoundsWatchesAndRequestsSeparately(t *testing.T) {
	hub, link := newTestRelayHub(t)
	open := func(method string) error {
		stream, err := hub.Open(t.Context(), link.id, &gatewayv1.DaemonLinkFrame{Method: method})
		if err == nil {
			t.Cleanup(stream.Close)
			drainTestRelayOpen(t, link)
		}
		return err
	}
	for range maxDaemonRelayStreams {
		if err := open("/dieter.v1.DieterService/GetState"); err != nil {
			t.Fatal(err)
		}
	}
	if err := open("/dieter.v1.DieterService/GetState"); status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("request above its bound = %v", err)
	}
	for range maxDaemonWatchStreams {
		if err := open("/dieter.v1.DieterService/WatchChanges"); err != nil {
			t.Fatalf("watch beside exhausted requests = %v", err)
		}
	}
	if err := open("/dieter.v1.DieterService/WatchConversation"); status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("watch above its bound = %v", err)
	}
}

func TestAuthenticatedStreamsAreBoundedPerAccount(t *testing.T) {
	var budget streamBudget
	for range maxAccountStreams {
		if !budget.acquire(1) {
			t.Fatal("account stream below its bound was rejected")
		}
	}
	if budget.acquire(1) {
		t.Fatal("account exceeded its stream bound")
	}
	if !budget.acquire(2) {
		t.Fatal("one account's streams exhausted another's")
	}
	budget.release(1)
	if !budget.acquire(1) {
		t.Fatal("released stream was not returned to its account")
	}
	for account := int64(3); budget.total < maxGatewayStreams; account++ {
		for range maxAccountStreams {
			if budget.total < maxGatewayStreams && !budget.acquire(account) {
				t.Fatal("stream below the gateway bound was rejected")
			}
		}
	}
	if budget.acquire(1 << 40) {
		t.Fatal("gateway exceeded its total stream bound")
	}
}

func TestAuthenticatedSubscriptionCapacityReservesOtherTrafficClasses(t *testing.T) {
	var budget streamBudget
	for range maxAccountStreams {
		if !budget.acquireLane(1, relaypolicy.Subscription) {
			t.Fatal("subscription rejected below account ceiling")
		}
	}
	if budget.acquireLane(1, relaypolicy.Subscription) {
		t.Fatal("subscription ceiling exceeded")
	}
	for _, lane := range []relaypolicy.Lane{relaypolicy.Control, relaypolicy.Replication, relaypolicy.Command} {
		if !budget.acquireLane(1, lane) {
			t.Fatalf("subscriptions consumed %s capacity", lane)
		}
	}
	for range maxAccountStreams {
		budget.releaseLane(1, relaypolicy.Subscription)
	}
	if !budget.acquireLane(1, relaypolicy.Subscription) {
		t.Fatal("subscription reservation was not released")
	}
}

func TestRelaySessionJoinsRejectStaleProcessesAndPreserveReplacements(t *testing.T) {
	hub := NewHub(nil, Config{})
	link := func(lane relaypolicy.Lane, session string) *daemonLink {
		b := relaypolicy.NewBudget(relaypolicy.BufferedBytes, nil)
		l := &daemonLink{id: "daemon", lane: lane, sessionID: session, budget: b, outbound: relaypolicy.NewQueue(b), done: make(chan struct{}), streams: map[uint64]*relayFrameQueue{}}
		l.markSeen(time.Now())
		t.Cleanup(l.close)
		return l
	}
	a := link(relaypolicy.Control, "session-a")
	if err := hub.register(a); err != nil {
		t.Fatal(err)
	}
	auxiliary := link(relaypolicy.Subscription, "session-a")
	if err := hub.register(auxiliary); err != nil {
		t.Fatal(err)
	}
	if err := hub.register(link(relaypolicy.Command, "unrelated-session")); status.Code(err) != codes.FailedPrecondition {
		t.Fatal("unrelated process joined daemon lanes", err)
	}
	b := link(relaypolicy.Control, "session-b")
	if err := hub.register(b); err != nil {
		t.Fatal(err)
	}
	if a.isAlive(time.Now()) || auxiliary.isAlive(time.Now()) {
		t.Fatal("replaced process retained a lane")
	}
	hub.unregister(a)
	if !hub.Online("daemon") {
		t.Fatal("old cleanup removed new control connection")
	}
	if err := hub.register(link(relaypolicy.Control, "session-a")); status.Code(err) != codes.FailedPrecondition {
		t.Fatal("stale control resurrected old process", err)
	}
	if err := hub.register(link(relaypolicy.Subscription, "session-a")); status.Code(err) != codes.FailedPrecondition {
		t.Fatal("stale subscription joined new process", err)
	}
	if err := hub.register(link(relaypolicy.Subscription, "session-b")); err != nil {
		t.Fatal(err)
	}
	hub.CloseDaemon("daemon")
	for _, lane := range hub.RelayLanes("daemon") {
		if lane.Connected {
			t.Fatal("revocation left authenticated lane alive")
		}
	}
}
