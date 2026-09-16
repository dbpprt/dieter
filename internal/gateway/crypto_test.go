package gateway

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"os"
	"path/filepath"
	"testing"
)

func TestConcurrentKeyInitializationPreservesOneTrustRoot(t *testing.T) {
	root := t.TempDir()
	start := make(chan struct{})
	type result struct {
		keys *Keys
		err  error
	}
	results := make(chan result, 16)
	for range cap(results) {
		go func() {
			<-start
			keys, err := LoadOrCreateKeys(root)
			results <- result{keys, err}
		}()
	}
	close(start)
	var first *Keys
	for range cap(results) {
		result := <-results
		if result.err != nil {
			t.Errorf("initialize keys: %v", result.err)
			continue
		}
		if first == nil {
			first = result.keys
		}
		if !bytes.Equal(first.SigningPrivate, result.keys.SigningPrivate) || !bytes.Equal(first.DaemonCAPrivate, result.keys.DaemonCAPrivate) || !bytes.Equal(first.DaemonCAPEM, result.keys.DaemonCAPEM) {
			t.Error("concurrent gateway starts loaded different trust roots")
		}
	}
	if t.Failed() {
		return
	}
	reloaded, err := LoadOrCreateKeys(root)
	if err != nil || !bytes.Equal(first.SigningPrivate, reloaded.SigningPrivate) || !bytes.Equal(first.DaemonCAPEM, reloaded.DaemonCAPEM) {
		t.Fatalf("persisted trust root changed: %v", err)
	}
	for _, name := range []string{"gateway-ed25519.pem", "daemon-ca-ed25519.pem"} {
		info, err := os.Stat(filepath.Join(root, "signing", name))
		if err != nil || info.Mode().Perm() != 0o600 {
			t.Fatalf("private key permissions: %v %v", info, err)
		}
	}
}

func TestLoadKeysRejectsMismatchedCACertificate(t *testing.T) {
	root := t.TempDir()
	if _, err := LoadOrCreateKeys(root); err != nil {
		t.Fatal(err)
	}
	_, other, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	certificate, err := createCA(other)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "signing", "daemon-ca.pem"), certificate, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadOrCreateKeys(root); err == nil {
		t.Fatal("gateway started with a CA certificate from another private key")
	}
}
