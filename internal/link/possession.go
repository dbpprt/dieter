package link

import (
	"context"
	"time"

	"github.com/dbpprt/dieter/internal/platform/buildinfo"
	"github.com/dbpprt/dieter/internal/security/linkauth"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

// possessionConn authenticates autonomous daemons with short-lived possession
// proofs of the enrolled key. The gateway resolves the account from current enrollment, never input.
type possessionConn struct {
	grpc.ClientConnInterface
	identity *Identity
	target   string
}

func (c possessionConn) auth(ctx context.Context) context.Context {
	values, _ := metadata.FromOutgoingContext(ctx)
	values = values.Copy()
	values.Set("authorization", "Bearer "+linkauth.SignPeer(c.identity.PrivateKey, c.identity.ID, c.identity.Issuer(), c.identity.Generation, time.Now()))
	values.Set("x-dieter-client-version", buildinfo.ReleaseVersion)
	if c.target != "" {
		values.Set("x-dieter-daemon-id", c.target)
	}
	return metadata.NewOutgoingContext(ctx, values)
}
func (c possessionConn) Invoke(ctx context.Context, method string, in, out any, opts ...grpc.CallOption) error {
	return c.ClientConnInterface.Invoke(c.auth(ctx), method, in, out, opts...)
}
func (c possessionConn) NewStream(ctx context.Context, desc *grpc.StreamDesc, method string, opts ...grpc.CallOption) (grpc.ClientStream, error) {
	return c.ClientConnInterface.NewStream(c.auth(ctx), desc, method, opts...)
}

// PossessionConn wraps conn so every call carries a fresh possession proof of
// identity's key. A non-empty target routes the call to that daemon through
// the gateway relay.
func PossessionConn(conn grpc.ClientConnInterface, identity *Identity, target string) grpc.ClientConnInterface {
	return possessionConn{conn, identity, target}
}
