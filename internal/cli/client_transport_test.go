package cli

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/security/linkauth"
)

func enrolledCLIIdentity(t *testing.T, gateway string) (*CLI, *link.Identity) {
	t.Helper()
	root := t.TempDir()
	identity, err := link.LoadOrCreateEnrollmentIdentity(root, "CLI", gateway)
	if err != nil {
		t.Fatal(err)
	}
	if err := identity.SaveCredential("d_cli", "CLI", []byte("certificate"), nil, nil, time.Now().Add(time.Hour).Format(time.RFC3339Nano), 3); err != nil {
		t.Fatal(err)
	}
	return New(root), identity
}

func TestCLIGatewayAuthenticationUsesDaemonEnrollment(t *testing.T) {
	t.Parallel()
	client, identity := enrolledCLIIdentity(t, "https://gateway.example")
	loaded, origin, err := client.gatewayIdentity()
	if err != nil {
		t.Fatal(err)
	}
	if loaded.ID != identity.ID || origin != identity.GatewayURL {
		t.Fatalf("identity=%s origin=%s", loaded.ID, origin)
	}
	metadata, err := (daemonGatewayCredential{identity: loaded, secure: true}).GetRequestMetadata(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	proof := strings.TrimPrefix(metadata["authorization"], "Bearer ")
	claims, err := linkauth.VerifyPeer(identity.PublicKey, proof, identity.GatewayURL, identity.Generation, time.Now())
	if err != nil || claims.DaemonID != identity.ID {
		t.Fatalf("daemon proof claims=%+v err=%v", claims, err)
	}
}

func TestCLIGatewayAuthenticationRequiresMatchingEnrollment(t *testing.T) {
	t.Parallel()
	client := New(t.TempDir())
	if _, _, err := client.gatewayIdentity(); err == nil || !strings.Contains(err.Error(), "dieter setup") {
		t.Fatalf("missing enrollment error=%v", err)
	}

	client, _ = enrolledCLIIdentity(t, "https://gateway.example")
	client.GatewayURL = "https://other.example"
	if _, _, err := client.gatewayIdentity(); err == nil || !strings.Contains(err.Error(), "does not match") {
		t.Fatalf("mismatched gateway error=%v", err)
	}
}

func TestClientGatewayURLRequiresEncryptedRemoteTransport(t *testing.T) {
	t.Parallel()
	for _, origin := range []string{"http://gateway.example", "http://192.168.1.2:8080", "http://localhost:8080", "https://user:password@gateway.example"} {
		if _, err := normalizeGatewayURL(origin); err == nil {
			t.Errorf("unsafe gateway URL %q was accepted", origin)
		}
	}
	for _, origin := range []string{"https://gateway.example", "http://127.0.0.1:8080", "http://[::1]:8080"} {
		if got, err := normalizeGatewayURL(origin + "/"); err != nil || got != origin {
			t.Errorf("valid gateway URL %q = (%q, %v)", origin, got, err)
		}
	}
}
