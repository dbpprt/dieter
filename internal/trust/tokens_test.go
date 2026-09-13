package trust

import (
	"crypto/ed25519"
	"crypto/rand"
	"testing"
	"time"
)

func TestDaemonBearerProfileRejectsOtherSignedClaims(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	valid := DaemonTokenClaims{Issuer: "https://gateway.example", Audience: "board-daemon:d_security", Subject: "github:123", ID: "dt_security", DaemonGeneration: 2, NotBefore: now.Add(-5 * time.Second).Unix(), IssuedAt: now.Unix(), ExpiresAt: now.Add(5 * time.Minute).Unix()}
	for name, alter := range map[string]func(*DaemonTokenClaims){
		"missing not-before": func(claims *DaemonTokenClaims) { claims.NotBefore = 0 },
		"missing issued-at":  func(claims *DaemonTokenClaims) { claims.IssuedAt = 0 },
		"RTC identifier":     func(claims *DaemonTokenClaims) { claims.ID = "rtc_security" },
		"empty identifier":   func(claims *DaemonTokenClaims) { claims.ID = "dt_" },
		"extended lifetime":  func(claims *DaemonTokenClaims) { claims.ExpiresAt++ },
		"invalid interval":   func(claims *DaemonTokenClaims) { claims.ExpiresAt = claims.IssuedAt },
		"future issued-at":   func(claims *DaemonTokenClaims) { claims.IssuedAt = now.Add(time.Minute).Unix() },
		"empty GitHub ID":    func(claims *DaemonTokenClaims) { claims.Subject = "github:" },
		"non-numeric ID":     func(claims *DaemonTokenClaims) { claims.Subject = "github:admin" },
		"negative GitHub ID": func(claims *DaemonTokenClaims) { claims.Subject = "github:-1" },
		"zero GitHub ID":     func(claims *DaemonTokenClaims) { claims.Subject = "github:0" },
		"non-canonical ID":   func(claims *DaemonTokenClaims) { claims.Subject = "github:+123" },
	} {
		t.Run(name, func(t *testing.T) {
			claims := valid
			alter(&claims)
			token, err := SignCompact(private, claims)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := ParseAndVerifyDaemonToken(public, token, valid.Issuer, "d_security", 2, now); err == nil {
				t.Fatal("invalid signed daemon bearer profile was accepted")
			}
		})
	}
	token, err := SignCompact(private, valid)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ParseAndVerifyDaemonToken(public, token, valid.Issuer, "d_security", 2, now); err != nil {
		t.Fatalf("existing valid gateway bearer profile was rejected: %v", err)
	}
}
