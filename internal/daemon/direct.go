package daemon

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/rpcraw"
	"github.com/dbpprt/dieter/internal/trust"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

type DirectServer struct {
	identity *Identity
	local    *grpc.ClientConn
	server   *grpc.Server
}

func NewDirectServer(identity *Identity, localTarget string) (*DirectServer, error) {
	if identity == nil || !identity.Enrolled() {
		return nil, errors.New("daemon is not enrolled")
	}
	local, err := grpc.NewClient(localTarget, grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithDefaultCallOptions(grpc.ForceCodec(rpcraw.Codec{}), grpc.MaxCallRecvMsgSize(16<<20), grpc.MaxCallSendMsgSize(16<<20)))
	if err != nil {
		return nil, err
	}
	direct := &DirectServer{identity: identity, local: local}
	direct.server = grpc.NewServer(grpc.ForceServerCodec(rpcraw.Codec{}), grpc.UnknownServiceHandler(direct.handle), grpc.MaxRecvMsgSize(16<<20), grpc.MaxSendMsgSize(16<<20))
	return direct, nil
}

func (s *DirectServer) Serve(listener net.Listener) error {
	certificate, err := tls.X509KeyPair(s.identity.CertificatePEM, privateKeyPEM(s.identity.PrivateKey))
	if err != nil {
		return err
	}
	config := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{certificate}, NextProtos: []string{"h2"}}
	return s.server.Serve(tls.NewListener(listener, config))
}

func (s *DirectServer) Stop() {
	s.server.GracefulStop()
	s.local.Close()
}

func (s *DirectServer) handle(_ any, stream grpc.ServerStream) error {
	ctx := stream.Context()
	method, ok := grpc.Method(ctx)
	if !ok || !strings.HasPrefix(method, "/dieter.v1.DieterService/") {
		return status.Error(codes.Unimplemented, "only DieterService is available")
	}
	values, _ := metadata.FromIncomingContext(ctx)
	authorization := values.Get("authorization")
	if len(authorization) != 1 {
		return status.Error(codes.Unauthenticated, "daemon access token is required")
	}
	token := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(authorization[0]), "Bearer "))
	public, err := trust.PublicKeyFromPEM(s.identity.GatewaySigningPublicKey)
	if err != nil {
		return status.Error(codes.Internal, "daemon trust configuration is invalid")
	}
	if _, err := trust.ParseAndVerifyDaemonToken(public, token, s.identity.GatewayURL, s.identity.ID, s.identity.Generation, time.Now().UTC()); err != nil {
		return status.Error(codes.Unauthenticated, "daemon access token is invalid")
	}
	var request rpcraw.Message
	if err := stream.RecvMsg(&request); err != nil {
		return err
	}
	description := &grpc.StreamDesc{ServerStreams: true, ClientStreams: false}
	call, err := s.local.NewStream(ctx, description, method, grpc.ForceCodec(rpcraw.Codec{}))
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
		var response rpcraw.Message
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

func DialDirect(ctx context.Context, address, daemonID string, daemonCA []byte, token string) (*grpc.ClientConn, error) {
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(daemonCA) {
		return nil, errors.New("daemon CA is invalid")
	}
	tlsConfig := &tls.Config{
		MinVersion: tls.VersionTLS13, RootCAs: roots, InsecureSkipVerify: true,
		VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) == 0 {
				return errors.New("daemon certificate is missing")
			}
			chains, err := state.PeerCertificates[0].Verify(x509.VerifyOptions{Roots: roots, Intermediates: intermediates(state.PeerCertificates[1:]), KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}})
			if err != nil || len(chains) == 0 {
				return errors.New("daemon certificate is not trusted")
			}
			for _, identity := range state.PeerCertificates[0].URIs {
				if identity.String() == "spiffe://board/daemon/"+daemonID {
					return nil
				}
			}
			return errors.New("daemon certificate identity does not match the route")
		},
	}
	connection, err := grpc.NewClient(address, grpc.WithTransportCredentials(credentials.NewTLS(tlsConfig)), grpc.WithPerRPCCredentials(daemonTokenCredential{token: token}))
	if err != nil {
		return nil, err
	}
	_ = ctx
	return connection, nil
}

type daemonTokenCredential struct{ token string }

func (c daemonTokenCredential) GetRequestMetadata(context.Context, ...string) (map[string]string, error) {
	return map[string]string{"authorization": "Bearer " + c.token}, nil
}

func (daemonTokenCredential) RequireTransportSecurity() bool { return true }

func intermediates(certificates []*x509.Certificate) *x509.CertPool {
	pool := x509.NewCertPool()
	for _, certificate := range certificates {
		pool.AddCert(certificate)
	}
	return pool
}
