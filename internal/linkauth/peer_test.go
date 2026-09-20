package linkauth

import (
	"crypto/ed25519"
	"crypto/rand"
	"testing"
	"time"
)

func TestPeerProofBoundToKeyGatewayGenerationAndTime(t *testing.T) {
	public, private, _ := ed25519.GenerateKey(rand.Reader)
	now := time.Now()
	token := SignPeer(private, "daemon", "https://gateway.test", 2, now)
	if _, e := VerifyPeer(public, token, "https://gateway.test", 2, now); e != nil {
		t.Fatal(e)
	}
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	for _, tc := range []struct {
		key        ed25519.PublicKey
		gateway    string
		generation uint64
		now        time.Time
	}{{other, "https://gateway.test", 2, now}, {public, "https://other.test", 2, now}, {public, "https://gateway.test", 3, now}, {public, "https://gateway.test", 2, now.Add(61 * time.Second)}, {public, "https://gateway.test", 2, now.Add(-30 * time.Second)}} {
		if _, e := VerifyPeer(tc.key, token, tc.gateway, tc.generation, tc.now); e == nil {
			t.Fatal("invalid proof accepted")
		}
	}
}
