package linkauth

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"testing"
	"time"
)

func TestChallengeBindsGatewayDaemonAndNonce(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "d_test"}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour)}
	raw, err := x509.CreateCertificate(rand.Reader, template, template, public, private)
	if err != nil {
		t.Fatal(err)
	}
	certificate := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: raw})
	challenge := []byte("unique challenge")
	signature := Sign(private, "https://dieter.example", "d_test", challenge)
	if err := VerifyCertificate(certificate, "https://dieter.example", "d_test", challenge, signature); err != nil {
		t.Fatal(err)
	}
	if VerifyCertificate(certificate, "https://dieter.example", "d_other", challenge, signature) == nil {
		t.Fatal("signature was not bound to the daemon ID")
	}
}
