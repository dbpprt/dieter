package link

import (
	"context"
	"crypto/tls"
	"net"

	"github.com/dbpprt/dieter/internal/platform/buildinfo"
	"github.com/dbpprt/dieter/internal/security/roster"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

// Dialer opens the byte stream a daemon connection runs over: a direct TCP
// candidate, a relay tunnel, or a WebRTC data channel. Every carrier runs the
// same mutually authenticated TLS, so the carrier never has to be trusted.
type Dialer func(context.Context, string) (net.Conn, error)

// TCPDialer dials a direct route candidate.
func TCPDialer(address string) Dialer {
	return func(ctx context.Context, _ string) (net.Conn, error) {
		var dialer net.Dialer
		return dialer.DialContext(ctx, "tcp", address)
	}
}

// DialDaemon returns a gRPC connection to one daemon over mutual TLS: it
// presents certificate, the caller's device key, and accepts the server only
// if its key is daemonKey, the target daemon's key in the device roster.
// bearer adds the gateway daemon token bound to the caller's device.
func DialDaemon(certificate tls.Certificate, daemonKey []byte, bearer credentials.PerRPCCredentials, dial Dialer, options ...grpc.DialOption) (*grpc.ClientConn, error) {
	config, err := ClientTLSConfig(certificate, daemonKey)
	if err != nil {
		return nil, err
	}
	options = append(options,
		grpc.WithTransportCredentials(credentials.NewTLS(config)), grpc.WithContextDialer(dial), grpc.WithPerRPCCredentials(bearer),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(16<<20), grpc.MaxCallSendMsgSize(16<<20)),
	)
	return grpc.NewClient("passthrough:///dieter-daemon", options...)
}

// DeviceCertificate presents the daemon's identity key; the CLI and peer
// sync of this machine act as its roster device.
func (i *Identity) DeviceCertificate() (tls.Certificate, error) {
	return DeviceCertificate(i.PrivateKey)
}

// DeviceID is the roster device ID of the identity key.
func (i *Identity) DeviceID() string {
	der, err := i.PublicKeyDER()
	if err != nil {
		return ""
	}
	return roster.DeviceID(der)
}

// TokenCredentials authenticates daemon calls with a gateway-issued daemon
// token bound to the caller's device.
func TokenCredentials(token string) credentials.PerRPCCredentials {
	return daemonTokenCredential{token: token}
}

type daemonTokenCredential struct{ token string }

func (c daemonTokenCredential) GetRequestMetadata(context.Context, ...string) (map[string]string, error) {
	return map[string]string{"authorization": "Bearer " + c.token, "x-dieter-client-version": buildinfo.ReleaseVersion}, nil
}

func (daemonTokenCredential) RequireTransportSecurity() bool { return true }
