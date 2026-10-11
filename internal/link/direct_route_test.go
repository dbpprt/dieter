package link

import (
	"crypto/ed25519"
	"crypto/rand"
	"testing"
)

func TestNewDirectRouteAdvertisesEphemeralLoopback(t *testing.T) {
	t.Parallel()
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	identity := &Identity{
		ID:             "d_local",
		GatewayURL:     "https://dieter.example.com",
		CertificatePEM: []byte("enrolled"),
		PrivateKey:     private,
	}
	route, err := NewDirectRoute(identity, "127.0.0.1:4242", "local-token", "loopback", "127.0.0.1:0", "127.0.0.1", "loopback", 1000)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		route.Server.Stop()
		_ = route.Listener.Close()
	})
	if route.Candidate.GetId() != "loopback" || route.Candidate.GetHost() != "127.0.0.1" || route.Candidate.GetNetwork() != "loopback" {
		t.Fatalf("candidate=%#v", route.Candidate)
	}
	if route.Candidate.GetPort() == 0 || route.Candidate.GetPriority() != 1000 {
		t.Fatalf("candidate=%#v", route.Candidate)
	}
	if route.Candidate.GetCertificateIdentity() != identity.ID {
		t.Fatalf("certificate identity=%q", route.Candidate.GetCertificateIdentity())
	}
}
