package controlrtc_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"io"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/controlrtc"
	"github.com/dbpprt/dieter/internal/daemon"
	"github.com/dbpprt/dieter/internal/gateway"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	dieterv1 "github.com/dbpprt/dieter/internal/gen/dieter/v1"
	"github.com/dbpprt/dieter/internal/trust"
	"github.com/pion/turn/v5"
	"github.com/pion/webrtc/v4"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/emptypb"
)

type service struct {
	dieterv1.UnimplementedDieterServiceServer
	canceled chan struct{}
}

func (*service) Health(context.Context, *emptypb.Empty) (*dieterv1.HealthResponse, error) {
	return &dieterv1.HealthResponse{Status: "ok"}, nil
}
func (*service) GetState(_ context.Context, r *dieterv1.GetStateRequest) (*dieterv1.State, error) {
	return &dieterv1.State{Projects: []*dieterv1.Project{{Name: r.GetQuery()}}}, nil
}
func (s *service) WatchState(_ *dieterv1.WatchStateRequest, stream dieterv1.DieterService_WatchStateServer) error {
	if err := stream.Send(&dieterv1.State{}); err != nil {
		return err
	}
	<-stream.Context().Done()
	close(s.canceled)
	return stream.Context().Err()
}

type bearer string

func (b bearer) GetRequestMetadata(context.Context, ...string) (map[string]string, error) {
	return map[string]string{"authorization": "Bearer " + string(b)}, nil
}
func (bearer) RequireTransportSecurity() bool { return true }

type fixture struct {
	manager       *controlrtc.Manager
	configuration *gatewayv1.RTCConfiguration
	identity      *daemon.Identity
	token         string
	keys          *gateway.Keys
	local         *service
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	keys, err := gateway.LoadOrCreateKeys(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	identity, err := daemon.LoadOrCreateEnrollmentIdentity(t.TempDir(), "test", "https://gateway.example")
	if err != nil {
		t.Fatal(err)
	}
	public, _ := identity.PublicKeyDER()
	certificate, expires, err := keys.IssueDaemonCertificate("d_control", public)
	if err != nil {
		t.Fatal(err)
	}
	signing, _ := keys.SigningPublicPEM()
	if err = identity.SaveCredential("d_control", "test", certificate, keys.DaemonCAPEM, signing, expires.Format(time.RFC3339Nano), 1); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	local := grpc.NewServer(grpc.MaxRecvMsgSize(16<<20), grpc.MaxSendMsgSize(16<<20))
	handler := &service{canceled: make(chan struct{})}
	dieterv1.RegisterDieterServiceServer(local, handler)
	go local.Serve(listener)
	t.Cleanup(local.Stop)
	direct, err := daemon.NewDirectServer(identity, listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	directListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go direct.Serve(directListener)
	t.Cleanup(direct.Stop)
	manager := controlrtc.New(controlrtc.Identity{DaemonID: identity.ID, GatewayURL: identity.GatewayURL, Generation: 1, GatewaySigningPublicKey: signing}, directListener.Addr().String())
	t.Cleanup(manager.Close)
	token, _, err := keys.SignDaemonToken(identity.GatewayURL, identity.ID, 42, 1, "", 5*time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	f := &fixture{manager: manager, identity: identity, token: token, keys: keys, local: handler}
	f.configuration = &gatewayv1.RTCConfiguration{DaemonId: identity.ID, DaemonGeneration: 1, OperatorSubject: "github:42", ConfigurationId: "rtc_control", ExpiresAt: time.Now().Add(5 * time.Minute).UTC().Format(time.RFC3339Nano)}
	f.sign(t)
	return f
}
func (f *fixture) sign(t *testing.T) {
	f.configuration.SignedEnvelope = nil
	raw, _ := proto.MarshalOptions{Deterministic: true}.Marshal(f.configuration)
	digest := sha256.Sum256(raw)
	signed, err := f.keys.SignRTCConfiguration(f.identity.GatewayURL, trust.RTCConfigurationClaims{Audience: "board-daemon:" + f.identity.ID, Subject: "github:42", ID: f.configuration.ConfigurationId, ConfigurationHash: base64.RawURLEncoding.EncodeToString(digest[:]), DaemonGeneration: 1, IssuedAt: time.Now().Unix(), ExpiresAt: time.Now().Add(5 * time.Minute).Unix()})
	if err != nil {
		t.Fatal(err)
	}
	f.configuration.SignedEnvelope = []byte(signed)
}
func (f *fixture) start(ctx context.Context, r *dieterv1.StartControlConnectionRequest) (*dieterv1.ControlConnection, error) {
	return f.manager.Start(ctx, r, "github:42")
}

func TestControlTLSRPCDirectAndTURN(t *testing.T) {
	for _, relay := range []bool{false, true} {
		t.Run(map[bool]string{false: "direct", true: "turn"}[relay], func(t *testing.T) {
			f := newFixture(t)
			if relay {
				socket, err := net.ListenPacket("udp4", "127.0.0.1:0")
				if err != nil {
					t.Fatal(err)
				}
				server, err := turn.NewServer(turn.ServerConfig{Realm: "dieter-test", AuthHandler: func(request *turn.RequestAttributes) (string, []byte, bool) {
					return request.Username, turn.GenerateAuthKey(request.Username, request.Realm, "test-password"), request.Username == "test"
				}, PacketConnConfigs: []turn.PacketConnConfig{{PacketConn: socket, RelayAddressGenerator: &turn.RelayAddressGeneratorStatic{RelayAddress: net.ParseIP("127.0.0.1"), Address: "127.0.0.1"}}}})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { server.Close() })
				f.configuration.IceServers = []*gatewayv1.RTCIceServer{{Urls: []string{"turn:" + socket.LocalAddr().String() + "?transport=udp"}, Username: "test", Credential: "test-password"}}
				f.sign(t)
			}
			ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
			defer cancel()
			var stream net.Conn
			var session *dieterv1.ControlConnection
			var err error
			if !relay {
				stream, session, err = controlrtc.Dial(ctx, f.configuration, f.start)
			} else {
				config := controlrtc.Configuration(f.configuration)
				config.ICETransportPolicy = webrtc.ICETransportPolicyRelay
				peer, e := webrtc.NewPeerConnection(config)
				if e != nil {
					t.Fatal(e)
				}
				t.Cleanup(func() { peer.Close() })
				dc, e := peer.CreateDataChannel(controlrtc.Label, nil)
				if e != nil {
					t.Fatal(e)
				}
				stream = controlrtc.Stream(dc, func() { peer.Close() })
				offer, e := peer.CreateOffer(nil)
				if e != nil {
					t.Fatal(e)
				}
				gather := webrtc.GatheringCompletePromise(peer)
				if e = peer.SetLocalDescription(offer); e != nil {
					t.Fatal(e)
				}
				select {
				case <-gather:
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				}
				session, err = f.start(ctx, &dieterv1.StartControlConnectionRequest{RtcConfiguration: f.configuration, OfferSdp: peer.LocalDescription().SDP})
				if err == nil {
					err = peer.SetRemoteDescription(webrtc.SessionDescription{Type: webrtc.SDPTypeAnswer, SDP: session.AnswerSdp})
				}
			}
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { stream.Close() })
			var once sync.Once
			connection, err := daemon.DialDirectWithCredentials(ctx, "passthrough:///rtc", f.identity.ID, f.identity.DaemonCAPEM, bearer(f.token), grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
				var result net.Conn
				once.Do(func() { result = stream })
				if result == nil {
					return nil, io.EOF
				}
				return result, nil
			}))
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { connection.Close() })
			client := dieterv1.NewDieterServiceClient(connection)
			health, err := client.Health(ctx, &emptypb.Empty{})
			if err != nil || health.GetStatus() != "ok" {
				t.Fatalf("TLS gRPC health: %v %v", health, err)
			}
			state, err := f.manager.Get(session.SessionId, "github:42")
			if err != nil {
				t.Fatal(err)
			}
			expected := "direct"
			if relay {
				expected = "turn"
			}
			if state.Mode != expected {
				t.Fatalf("actual ICE mode %q, want %q", state.Mode, expected)
			}
			// Exceeds both the SCTP chunk and credit window, in both directions.
			payload := string(bytes.Repeat([]byte("large-control-rpc"), 128<<10))
			response, err := client.GetState(ctx, &dieterv1.GetStateRequest{Query: payload})
			if err != nil || len(response.GetProjects()) != 1 || response.Projects[0].Name != payload {
				t.Fatalf("large RPC: %v", err)
			}
			watchCtx, stop := context.WithCancel(ctx)
			watch, err := client.WatchState(watchCtx, &dieterv1.WatchStateRequest{})
			if err != nil {
				t.Fatal(err)
			}
			if _, err = watch.Recv(); err != nil {
				t.Fatal(err)
			}
			stop()
			select {
			case <-f.local.canceled:
			case <-ctx.Done():
				t.Fatal("watch cancellation did not propagate")
			}
			if _, err = client.Health(ctx, &emptypb.Empty{}); err != nil {
				t.Fatalf("canceling one RPC closed connection: %v", err)
			}
			if _, err = f.manager.Get(session.SessionId, "github:99"); status.Code(err) != codes.NotFound {
				t.Fatalf("foreign session access: %v", err)
			}
			if err = f.manager.CloseSession(session.SessionId, "github:42"); err != nil {
				t.Fatal(err)
			}
			if _, err = f.manager.Get(session.SessionId, "github:42"); status.Code(err) != codes.NotFound {
				t.Fatalf("closed session remains: %v", err)
			}
		})
	}
}

func TestControlRejectsTamperedConfiguration(t *testing.T) {
	f := newFixture(t)
	f.configuration.IceServers = []*gatewayv1.RTCIceServer{{Urls: []string{"stun:attacker.invalid"}}}
	_, err := f.manager.Start(t.Context(), &dieterv1.StartControlConnectionRequest{RtcConfiguration: f.configuration, OfferSdp: "offer"}, "github:42")
	if status.Code(err) != codes.Unauthenticated {
		t.Fatalf("tampered configuration accepted: %v", err)
	}
	f.sign(t)
	_, err = f.manager.Start(t.Context(), &dieterv1.StartControlConnectionRequest{RtcConfiguration: f.configuration, OfferSdp: "offer"}, "github:99")
	if status.Code(err) != codes.PermissionDenied {
		t.Fatalf("foreign configuration accepted: %v", err)
	}
}

func TestControlTLSAuthenticatesBothEndpoints(t *testing.T) {
	for _, test := range []struct {
		name, identity, token string
		want                  codes.Code
	}{
		{"missing bearer", "d_control", "", codes.Unauthenticated},
		{"invalid bearer", "d_control", "invalid", codes.Unauthenticated},
		{"wrong daemon identity", "d_other", "valid", codes.DeadlineExceeded},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := newFixture(t)
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			stream, _, err := controlrtc.Dial(ctx, f.configuration, f.start)
			if err != nil {
				t.Fatal(err)
			}
			defer stream.Close()
			token := test.token
			if token == "valid" {
				token = f.token
			}
			var once sync.Once
			conn, err := daemon.DialDirectWithCredentials(ctx, "passthrough:///rtc", test.identity, f.identity.DaemonCAPEM, bearer(token), grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) {
				var result net.Conn
				once.Do(func() { result = stream })
				if result == nil {
					return nil, io.EOF
				}
				return result, nil
			}))
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			_, err = dieterv1.NewDieterServiceClient(conn).Health(ctx, &emptypb.Empty{})
			if status.Code(err) != test.want && !(test.identity == "d_other" && status.Code(err) == codes.Unavailable) {
				t.Fatalf("authentication failure=%v, want %v", err, test.want)
			}
		})
	}
}

func TestStreamRejectsUnsolicitedCredit(t *testing.T) {
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	left, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer left.Close()
	right, err := webrtc.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		t.Fatal(err)
	}
	defer right.Close()
	streams := make(chan net.Conn, 1)
	right.OnDataChannel(func(dc *webrtc.DataChannel) { streams <- controlrtc.Stream(dc, func() { right.Close() }) })
	dc, err := left.CreateDataChannel(controlrtc.Label, nil)
	if err != nil {
		t.Fatal(err)
	}
	dc.OnOpen(func() { _ = dc.Send([]byte{1}) })
	offer, err := left.CreateOffer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gather := webrtc.GatheringCompletePromise(left)
	if err = left.SetLocalDescription(offer); err != nil {
		t.Fatal(err)
	}
	select {
	case <-gather:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	if err = right.SetRemoteDescription(*left.LocalDescription()); err != nil {
		t.Fatal(err)
	}
	answer, err := right.CreateAnswer(nil)
	if err != nil {
		t.Fatal(err)
	}
	gather = webrtc.GatheringCompletePromise(right)
	if err = right.SetLocalDescription(answer); err != nil {
		t.Fatal(err)
	}
	select {
	case <-gather:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	if err = left.SetRemoteDescription(*right.LocalDescription()); err != nil {
		t.Fatal(err)
	}
	var stream net.Conn
	select {
	case stream = <-streams:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	defer stream.Close()
	_ = stream.SetReadDeadline(time.Now().Add(time.Second))
	_, err = stream.Read(make([]byte, 1))
	if err == nil {
		t.Fatal("unsolicited credit accepted")
	}
	if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("protocol violation did not close stream")
	}
}
