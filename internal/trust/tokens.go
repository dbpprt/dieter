package trust

import (
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"strings"
	"time"
)

type DaemonTokenClaims struct {
	Issuer           string `json:"iss"`
	Subject          string `json:"sub"`
	Audience         string `json:"aud"`
	ID               string `json:"jti"`
	IssuedAt         int64  `json:"iat"`
	NotBefore        int64  `json:"nbf"`
	ExpiresAt        int64  `json:"exp"`
	DaemonGeneration uint64 `json:"daemon_generation"`
	ClientThumbprint string `json:"client_key_thumbprint,omitempty"`
}

type DelegationClaims struct {
	Issuer      string `json:"iss"`
	Audience    string `json:"aud"`
	Subject     string `json:"sub"`
	ID          string `json:"jti"`
	RequestID   string `json:"request_id"`
	Method      string `json:"method"`
	PayloadHash string `json:"payload_hash"`
	Generation  uint64 `json:"generation"`
	IssuedAt    int64  `json:"iat"`
	ExpiresAt   int64  `json:"exp"`
}

// RTCConfigurationClaims binds short-lived ICE/TURN configuration to one
// authenticated operator and one enrolled daemon. The configuration itself is
// transported as protobuf; ConfigurationHash covers its deterministic wire
// representation with signed_envelope cleared.
type RTCConfigurationClaims struct {
	Issuer            string `json:"iss"`
	Audience          string `json:"aud"`
	Subject           string `json:"sub"`
	ID                string `json:"jti"`
	ConfigurationHash string `json:"configuration_hash"`
	DaemonGeneration  uint64 `json:"daemon_generation"`
	IssuedAt          int64  `json:"iat"`
	ExpiresAt         int64  `json:"exp"`
}

func SignCompact(private ed25519.PrivateKey, claims any) (string, error) {
	headerRaw, _ := json.Marshal(map[string]string{"alg": "EdDSA", "typ": "JWT", "kid": "dieter-gateway-v1"})
	claimsRaw, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	header := base64.RawURLEncoding.EncodeToString(headerRaw)
	payload := base64.RawURLEncoding.EncodeToString(claimsRaw)
	input := header + "." + payload
	signature := ed25519.Sign(private, []byte(input))
	return input + "." + base64.RawURLEncoding.EncodeToString(signature), nil
}

func ParseAndVerifyDaemonToken(public ed25519.PublicKey, token, issuer, daemonID string, generation uint64, now time.Time) (DaemonTokenClaims, error) {
	var claims DaemonTokenClaims
	if err := verifyCompact(public, token, &claims); err != nil {
		return claims, err
	}
	if claims.Issuer != strings.TrimRight(issuer, "/") || claims.Audience != "board-daemon:"+daemonID || claims.DaemonGeneration != generation {
		return claims, errors.New("daemon token target is invalid")
	}
	unix := now.UTC().Unix()
	if claims.NotBefore > unix+10 || claims.ExpiresAt <= unix-10 || claims.ID == "" || !strings.HasPrefix(claims.Subject, "github:") {
		return claims, errors.New("daemon token is expired or invalid")
	}
	return claims, nil
}

func ParseAndVerifyDelegation(public ed25519.PublicKey, token, issuer, daemonID, requestID, method string, payload []byte, generation uint64, now time.Time) (DelegationClaims, error) {
	var claims DelegationClaims
	if err := verifyCompact(public, token, &claims); err != nil {
		return claims, err
	}
	digest := sha256.Sum256(payload)
	if claims.Issuer != strings.TrimRight(issuer, "/") || claims.Audience != "board-daemon:"+daemonID || claims.RequestID != requestID || claims.Method != method || claims.PayloadHash != base64.RawURLEncoding.EncodeToString(digest[:]) || claims.Generation != generation {
		return claims, errors.New("relay assertion does not match the request")
	}
	unix := now.UTC().Unix()
	if claims.IssuedAt > unix+10 || claims.ExpiresAt <= unix-10 || claims.ID == "" {
		return claims, errors.New("relay assertion is expired or invalid")
	}
	return claims, nil
}

func ParseAndVerifyRTCConfiguration(public ed25519.PublicKey, token, issuer, daemonID, operatorSubject, configurationID string, digest []byte, generation uint64, now time.Time) (RTCConfigurationClaims, error) {
	var claims RTCConfigurationClaims
	if err := verifyCompact(public, token, &claims); err != nil {
		return claims, err
	}
	if claims.Issuer != strings.TrimRight(issuer, "/") ||
		claims.Audience != "board-daemon:"+daemonID ||
		claims.Subject != operatorSubject ||
		claims.ID != configurationID ||
		claims.ConfigurationHash != base64.RawURLEncoding.EncodeToString(digest) ||
		claims.DaemonGeneration != generation {
		return claims, errors.New("RTC configuration does not match its signed envelope")
	}
	unix := now.UTC().Unix()
	if claims.IssuedAt > unix+10 || claims.ExpiresAt <= unix-10 || claims.ID == "" || !strings.HasPrefix(claims.Subject, "github:") {
		return claims, errors.New("RTC configuration is expired or invalid")
	}
	return claims, nil
}

func PublicKeyFromPEM(raw []byte) (ed25519.PublicKey, error) {
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("public key is not PEM")
	}
	value, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	public, ok := value.(ed25519.PublicKey)
	if !ok {
		return nil, errors.New("public key is not Ed25519")
	}
	return public, nil
}

func verifyCompact(public ed25519.PublicKey, token string, claims any) error {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return errors.New("token format is invalid")
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || !ed25519.Verify(public, []byte(parts[0]+"."+parts[1]), signature) {
		return errors.New("token signature is invalid")
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || json.Unmarshal(raw, claims) != nil {
		return errors.New("token claims are invalid")
	}
	return nil
}
