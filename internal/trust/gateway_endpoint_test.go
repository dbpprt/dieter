package trust

import (
	"crypto/ed25519"
	"crypto/rand"
	"testing"
	"time"
)

func TestGatewayEndpointRequiresPinnedKeyIdentityAccountAndFreshness(t *testing.T) {
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	now := time.Now()
	valid := GatewayEndpointClaims{Issuer: "https://old.example", Audience: "dieter-gateway-endpoint", Subject: "github:42", Endpoint: "https://new.example", Contract: "1", IssuedAt: now.Unix(), ExpiresAt: now.Add(time.Minute).Unix()}
	for name, mutate := range map[string]func(*GatewayEndpointClaims){
		"valid":            func(*GatewayEndpointClaims) {},
		"other issuer":     func(c *GatewayEndpointClaims) { c.Issuer = "https://other.example" },
		"other account":    func(c *GatewayEndpointClaims) { c.Subject = "github:43" },
		"wrong purpose":    func(c *GatewayEndpointClaims) { c.Audience = "board-daemon:d_test" },
		"wrong contract":   func(c *GatewayEndpointClaims) { c.Contract = "2" },
		"expired":          func(c *GatewayEndpointClaims) { c.ExpiresAt = now.Unix() },
		"future":           func(c *GatewayEndpointClaims) { c.IssuedAt = now.Add(time.Minute).Unix() },
		"long lifetime":    func(c *GatewayEndpointClaims) { c.ExpiresAt = now.Add(time.Hour).Unix() },
		"remote cleartext": func(c *GatewayEndpointClaims) { c.Endpoint = "http://new.example" },
		"local downgrade":  func(c *GatewayEndpointClaims) { c.Endpoint = "http://127.0.0.1:4243" },
		"credentials":      func(c *GatewayEndpointClaims) { c.Endpoint = "https://user:password@new.example" },
		"path":             func(c *GatewayEndpointClaims) { c.Endpoint = "https://new.example/move" },
	} {
		t.Run(name, func(t *testing.T) {
			claims := valid
			mutate(&claims)
			token, err := SignCompact(private, claims)
			if err != nil {
				t.Fatal(err)
			}
			_, err = VerifyGatewayEndpoint(public, token, valid.Issuer, valid.Subject, "1", now)
			if (err == nil) != (name == "valid") {
				t.Fatalf("unexpected verification: %v", err)
			}
		})
	}
	token, _ := SignCompact(private, valid)
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	if _, err := VerifyGatewayEndpoint(other, token, valid.Issuer, valid.Subject, "1", now); err == nil {
		t.Fatal("untrusted gateway authorized relocation")
	}
}
