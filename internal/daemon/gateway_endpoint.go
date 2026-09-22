package daemon

import (
	"context"
	"crypto/ed25519"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/protocol"
	"github.com/dbpprt/dieter/internal/trust"
	"google.golang.org/protobuf/types/known/emptypb"
)

// ResolveGatewayEndpoint runs before daemon workers start. Both the current
// endpoint and proposed destination must authenticate the existing enrollment,
// and the destination must be authorized by the pinned gateway signing key.
// It never mutates identity or falls back to unverified redirects.
func ResolveGatewayEndpoint(ctx context.Context, identity *Identity) (string, error) {
	if identity == nil || !identity.Enrolled() {
		return "", errors.New("daemon is not enrolled")
	}
	block, _ := pem.Decode(identity.GatewaySigningPublicKey)
	if block == nil {
		return "", errors.New("gateway signing key is invalid")
	}
	parsed, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return "", err
	}
	public, ok := parsed.(ed25519.PublicKey)
	if !ok {
		return "", errors.New("gateway signing key is not Ed25519")
	}
	accountAt := func(value *Identity) (*gatewayv1.Account, error) {
		conn, err := dialGateway(ctx, value, false)
		if err != nil {
			return nil, err
		}
		defer conn.Close()
		return gatewayv1.NewGatewayServiceClient(peerGatewayConn{conn, value, ""}).GetAccount(ctx, &emptypb.Empty{})
	}
	account, err := accountAt(identity)
	if err != nil {
		return "", err
	}
	if account.GetSignedGatewayEndpoint() == "" {
		return identity.GatewayURL, nil
	}
	subject := fmt.Sprintf("github:%d", account.GetGithubId())
	claims, err := trust.VerifyGatewayEndpoint(public, account.GetSignedGatewayEndpoint(), identity.Issuer(), subject, protocol.Version, time.Now())
	if err != nil {
		return "", err
	}
	if claims.Endpoint == identity.GatewayURL {
		return identity.GatewayURL, nil
	}
	candidate := *identity
	candidate.GatewayIssuer, candidate.GatewayURL = identity.Issuer(), claims.Endpoint
	next, err := accountAt(&candidate)
	if err != nil {
		return "", err
	}
	if next.GetGithubId() != account.GetGithubId() {
		return "", errors.New("gateway destination belongs to another account")
	}
	verified, err := trust.VerifyGatewayEndpoint(public, next.GetSignedGatewayEndpoint(), identity.Issuer(), subject, protocol.Version, time.Now())
	if err != nil {
		return "", err
	}
	if verified.Endpoint != claims.Endpoint {
		return "", errors.New("gateway destination disagrees with the signed endpoint")
	}
	return claims.Endpoint, nil
}
