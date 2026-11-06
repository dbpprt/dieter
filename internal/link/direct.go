package link

import (
	"context"
	"errors"
	"io"
	"net"
	"strings"
	"sync/atomic"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/security/localauth"
	"github.com/dbpprt/dieter/internal/security/trust"
	"github.com/dbpprt/dieter/internal/transport/relay"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/peer"
	"google.golang.org/grpc/status"
)

// DirectServer is the daemon's only endpoint for remote calls, whatever the
// carrier: direct TCP, a WebRTC data channel, or a gateway relay tunnel. It
// runs mutual TLS pinned to the device roster and forwards verified calls to
// the raw local API.
type DirectServer struct {
	identity *Identity
	trust    *Trust
	local    *grpc.ClientConn
	server   *grpc.Server
	active   atomic.Int32
}

const maxActiveDirectRPCs = 64

// Metadata the DirectServer sets on every forwarded call. Caller metadata is
// never forwarded, so a remote caller cannot forge these.
const (
	OperatorSubjectMetadata = "x-dieter-operator-subject"
	DeviceIDMetadata        = "x-dieter-device-id"
	DeviceKindMetadata      = "x-dieter-device-kind"
)

// NewDirectServer forwards verified direct RPCs to the raw local API, which
// admits them with the daemon's local API token.
func NewDirectServer(identity *Identity, deviceTrust *Trust, localTarget, localToken string) (*DirectServer, error) {
	if identity == nil || !identity.Enrolled() {
		return nil, errors.New("daemon is not enrolled")
	}
	config, err := ServerTLSConfig(identity, deviceTrust)
	if err != nil {
		return nil, err
	}
	local, err := grpc.NewClient(localTarget, grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithPerRPCCredentials(localauth.Credentials{Token: localToken}), grpc.WithDefaultCallOptions(grpc.ForceCodec(relay.RawCodec{}), grpc.MaxCallRecvMsgSize(16<<20), grpc.MaxCallSendMsgSize(16<<20)))
	if err != nil {
		return nil, err
	}
	direct := &DirectServer{identity: identity, trust: deviceTrust, local: local}
	direct.server = grpc.NewServer(grpc.Creds(credentials.NewTLS(config)), grpc.ConnectionTimeout(10*time.Second), grpc.ForceServerCodec(relay.RawCodec{}), grpc.UnknownServiceHandler(direct.handle), grpc.MaxRecvMsgSize(16<<20), grpc.MaxSendMsgSize(16<<20))
	return direct, nil
}

func (s *DirectServer) Serve(listener net.Listener) error { return s.server.Serve(listener) }

func (s *DirectServer) Stop() {
	s.server.GracefulStop()
	s.local.Close()
}

// caller authenticates the TLS peer and its daemon token.
func (s *DirectServer) caller(ctx context.Context) (trust.DaemonTokenClaims, string, string, error) {
	var claims trust.DaemonTokenClaims
	info, ok := peer.FromContext(ctx)
	if !ok {
		return claims, "", "", status.Error(codes.Unauthenticated, "a device certificate is required")
	}
	tlsInfo, ok := info.AuthInfo.(credentials.TLSInfo)
	if !ok {
		return claims, "", "", status.Error(codes.Unauthenticated, "a device certificate is required")
	}
	deviceID, spki, ok := PeerDevice(tlsInfo.State)
	if !ok {
		return claims, "", "", status.Error(codes.Unauthenticated, "a device certificate is required")
	}
	// Membership is checked again per call: a revocation applies to
	// connections that were established before it.
	member, err := s.trust.Connecting(spki)
	if err != nil {
		return claims, "", "", status.Error(codes.Unauthenticated, "the device is not a member of the account's device roster")
	}
	values, _ := metadata.FromIncomingContext(ctx)
	authorization := values.Get("authorization")
	if len(authorization) != 1 {
		return claims, "", "", status.Error(codes.Unauthenticated, "daemon access token is required")
	}
	token := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(authorization[0]), "Bearer "))
	public, err := trust.PublicKeyFromPEM(s.identity.GatewaySigningPublicKey)
	if err != nil {
		return claims, "", "", status.Error(codes.Internal, "daemon trust configuration is invalid")
	}
	claims, err = trust.ParseAndVerifyDaemonToken(public, token, s.identity.Issuer(), s.identity.ID, s.identity.Generation, time.Now().UTC())
	if err != nil {
		return claims, "", "", status.Error(codes.Unauthenticated, "daemon access token is invalid")
	}
	// The token is bound to the device that presented it: a stolen bearer is
	// useless without the device key, and the gateway alone gets nothing.
	if claims.ClientThumbprint == "" || claims.ClientThumbprint != deviceID {
		return claims, "", "", status.Error(codes.Unauthenticated, "daemon access token belongs to another device")
	}
	kind := "client"
	if member.Descriptor.GetKind() == gatewayv1.DeviceKind_DEVICE_KIND_DAEMON {
		kind = "daemon"
	}
	return claims, deviceID, kind, nil
}

func (s *DirectServer) handle(_ any, stream grpc.ServerStream) error {
	ctx := stream.Context()
	method, ok := grpc.Method(ctx)
	if !ok || !relay.DaemonMethod(method) {
		return status.Error(codes.Unimplemented, "only the Dieter daemon API is available")
	}
	claims, deviceID, deviceKind, err := s.caller(ctx)
	if err != nil {
		return err
	}
	values, _ := metadata.FromIncomingContext(ctx)
	clientVersions := values.Get("x-dieter-client-version")
	clientVersion := ""
	if len(clientVersions) > 0 {
		clientVersion = clientVersions[0]
		for _, value := range clientVersions[1:] {
			if value != clientVersion {
				clientVersion = ""
				break
			}
		}
	}
	if s.active.Add(1) > maxActiveDirectRPCs {
		s.active.Add(-1)
		return status.Error(codes.ResourceExhausted, "daemon direct concurrency is exhausted")
	}
	defer s.active.Add(-1)
	// A bearer authorizes the entire direct RPC only for its accepted lifetime.
	// The extra ten seconds matches the verifier's clock-skew allowance. Return
	// from the handler on expiry even if a peer stalls RecvMsg or SendMsg; gRPC
	// then cancels the transport and releases the forwarding goroutine.
	ctx, cancel := context.WithDeadline(ctx, time.Unix(claims.ExpiresAt, 0).Add(10*time.Second))
	defer cancel()
	forwarded := metadata.Pairs(
		OperatorSubjectMetadata, claims.Subject,
		"x-dieter-client-version", clientVersion,
		DeviceIDMetadata, deviceID,
		DeviceKindMetadata, deviceKind,
	)
	completed := make(chan error, 1)
	go func() { completed <- s.forward(ctx, stream, method, forwarded) }()
	select {
	case err := <-completed:
		return err
	case <-ctx.Done():
		return status.FromContextError(ctx.Err()).Err()
	}
}

func (s *DirectServer) forward(ctx context.Context, stream grpc.ServerStream, method string, forwarded metadata.MD) error {
	var request relay.RawMessage
	if err := stream.RecvMsg(&request); err != nil {
		return err
	}
	description := &grpc.StreamDesc{ServerStreams: true, ClientStreams: false}
	call, err := s.local.NewStream(metadata.NewOutgoingContext(ctx, forwarded), description, method, grpc.ForceCodec(relay.RawCodec{}))
	if err != nil {
		return err
	}
	if err := call.SendMsg(&request); err != nil {
		return err
	}
	if err := call.CloseSend(); err != nil {
		return err
	}
	if headers, err := call.Header(); err == nil {
		_ = stream.SendHeader(headers)
	}
	for {
		var response relay.RawMessage
		err := call.RecvMsg(&response)
		if errors.Is(err, io.EOF) {
			stream.SetTrailer(call.Trailer())
			return nil
		}
		if err != nil {
			return err
		}
		if err := stream.SendMsg(&response); err != nil {
			return err
		}
	}
}
