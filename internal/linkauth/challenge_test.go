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
	if VerifyUnenrollment(certificate, "https://dieter.example", "d_test", challenge, signature) == nil {
		t.Fatal("daemon link proof was accepted as an unenrollment proof")
	}
	unenrollment := SignUnenrollment(private, "https://dieter.example", "d_test", challenge)
	if err := VerifyUnenrollment(certificate, "https://dieter.example", "d_test", challenge, unenrollment); err != nil {
		t.Fatal(err)
	}
	if VerifyCertificate(certificate, "https://dieter.example", "d_test", challenge, unenrollment) == nil {
		t.Fatal("unenrollment proof was accepted as a daemon link proof")
	}
}

func TestRecoveryProofBindsBothIdentitiesAndAction(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "d_replacement"}, NotBefore: time.Now().Add(-time.Minute), NotAfter: time.Now().Add(time.Hour)}
	raw, err := x509.CreateCertificate(rand.Reader, template, template, public, private)
	if err != nil {
		t.Fatal(err)
	}
	certificate := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: raw})
	nonce := make([]byte, 32)
	if _, err := rand.Read(nonce); err != nil {
		t.Fatal(err)
	}
	signature := SignRecovery(private, "https://dieter.example", "d_original", "d_replacement", 2, 1, nonce)
	if err := VerifyRecovery(certificate, "https://dieter.example", "d_original", "d_replacement", 2, 1, nonce, signature); err != nil {
		t.Fatal(err)
	}
	if VerifyRecovery(certificate, "https://dieter.example", "d_other", "d_replacement", 2, 1, nonce, signature) == nil ||
		VerifyRecovery(certificate, "https://dieter.example", "d_original", "d_other", 2, 1, nonce, signature) == nil ||
		VerifyRecovery(certificate, "https://other.example", "d_original", "d_replacement", 2, 1, nonce, signature) == nil ||
		VerifyRecovery(certificate, "https://dieter.example", "d_original", "d_replacement", 3, 1, nonce, signature) == nil ||
		VerifyRecovery(certificate, "https://dieter.example", "d_original", "d_replacement", 2, 2, nonce, signature) == nil ||
		VerifyRecovery(certificate, "https://dieter.example", "d_original", "d_replacement", 2, 1, make([]byte, 32), signature) == nil {
		t.Fatal("recovery proof was accepted for a different identity, gateway, generation, or nonce")
	}
	if VerifyUnenrollment(certificate, "https://dieter.example", "d_replacement", nonce, signature) == nil {
		t.Fatal("recovery proof was accepted as an unenrollment proof")
	}
}

func TestTunnelProofRejectsCertificateOutsideValidityWindow(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	for name, validity := range map[string][2]time.Time{
		"expired": {now.Add(-2 * time.Hour), now.Add(-time.Hour)},
		"future":  {now.Add(time.Hour), now.Add(2 * time.Hour)},
	} {
		t.Run(name, func(t *testing.T) {
			template := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: validity[0], NotAfter: validity[1]}
			raw, err := x509.CreateCertificate(rand.Reader, template, template, public, private)
			if err != nil {
				t.Fatal(err)
			}
			certificate := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: raw})
			challenge := []byte("isolated-certificate-validity-test")
			if err := VerifyCertificate(certificate, "https://dieter.example", "d_test", challenge, Sign(private, "https://dieter.example", "d_test", challenge)); err == nil {
				t.Fatal("tunnel proof accepted a certificate outside its validity window")
			}
			if err := VerifyUnenrollment(certificate, "https://dieter.example", "d_test", challenge, SignUnenrollment(private, "https://dieter.example", "d_test", challenge)); err != nil {
				t.Fatalf("expired enrollment owner cannot revoke its own key: %v", err)
			}
		})
	}
}
