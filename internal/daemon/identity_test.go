package daemon

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestEnrollmentRetryUpdatesOriginAndPreservesKey(t *testing.T) {
	root := t.TempDir()
	before, err := LoadOrCreateEnrollmentIdentity(root, "old name", "https://dieter.example.com")
	if err != nil {
		t.Fatal(err)
	}
	keyPath := filepath.Join(root, "daemon", "identity-key.pem")
	key, err := os.ReadFile(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	after, err := LoadOrCreateEnrollmentIdentity(root, "Mac mini", "https://gateway.getdieter.com")
	if err != nil {
		t.Fatal(err)
	}
	persisted, err := LoadIdentity(root)
	if err != nil {
		t.Fatal(err)
	}
	if after.GatewayURL != "https://gateway.getdieter.com" || persisted.GatewayURL != after.GatewayURL || persisted.Name != "Mac mini" {
		t.Fatalf("retry did not persist corrected enrollment: %#v", persisted)
	}
	keyAfter, err := os.ReadFile(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(before.PrivateKey, after.PrivateKey) || !bytes.Equal(key, keyAfter) {
		t.Fatal("retry changed the machine private key")
	}
}

func TestEnrollmentRetryPreservesCompletedIdentity(t *testing.T) {
	root := t.TempDir()
	identity, err := LoadOrCreateEnrollmentIdentity(root, "enrolled", "https://gateway.example")
	if err != nil {
		t.Fatal(err)
	}
	if err := identity.SaveCredential("d_original", "enrolled", []byte("certificate"), nil, nil, "", 1); err != nil {
		t.Fatal(err)
	}
	after, err := LoadOrCreateEnrollmentIdentity(root, "replacement", "https://other.example")
	if err != nil {
		t.Fatal(err)
	}
	if after.ID != identity.ID || after.Name != identity.Name || after.GatewayURL != identity.GatewayURL || !bytes.Equal(after.PrivateKey, identity.PrivateKey) {
		t.Fatal("retry modified a completed enrollment")
	}
}
