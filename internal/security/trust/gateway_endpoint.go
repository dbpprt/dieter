package trust

import (
	"crypto/ed25519"
	"errors"
	"strings"
	"time"
)

// GatewayEndpointClaims separates a gateway's durable authentication namespace
// from its current network location. Moving a host must not change peer account
// IDs or invalidate owner signatures on replicated records.
type GatewayEndpointClaims struct {
	Issuer    string `json:"iss"`
	Audience  string `json:"aud"`
	Subject   string `json:"sub"`
	Endpoint  string `json:"endpoint"`
	IssuedAt  int64  `json:"iat"`
	ExpiresAt int64  `json:"exp"`
}

func VerifyGatewayEndpoint(public ed25519.PublicKey, token, issuer, subject string, now time.Time) (GatewayEndpointClaims, error) {
	var claims GatewayEndpointClaims
	if len(token) > 4096 {
		return claims, errors.New("gateway endpoint assertion exceeds limit")
	}
	if err := verifyCompact(public, token, &claims); err != nil {
		return claims, err
	}
	origin, err := GatewayOrigin(claims.Endpoint)
	if err != nil || origin != claims.Endpoint || (strings.HasPrefix(issuer, "https:") && !strings.HasPrefix(origin, "https:")) || claims.Issuer != issuer || claims.Subject != subject ||
		!validGitHubSubject(subject) || claims.Audience != "dieter-gateway-endpoint" ||
		claims.IssuedAt <= 0 || claims.IssuedAt > now.Unix()+10 || claims.ExpiresAt <= now.Unix() ||
		claims.ExpiresAt <= claims.IssuedAt || claims.ExpiresAt-claims.IssuedAt > 300 {
		return claims, errors.New("gateway endpoint assertion is invalid or expired")
	}
	return claims, nil
}
