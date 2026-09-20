package remotedesktop

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Android verifies a binding signed by Go, so the two implementations cannot
// accidentally agree only with their own signature serialization.
func TestAndroidScreenTrustFixture(t *testing.T) {
	seed := sha256.Sum256([]byte("Dieter screen trust fixture, test-only key"))
	key := ed25519.NewKeyFromSeed(seed[:])
	cert := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "Dieter screen trust test"}, NotBefore: time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC), NotAfter: time.Date(2100, 1, 1, 0, 0, 0, 0, time.UTC), KeyUsage: x509.KeyUsageDigitalSignature}
	der, err := x509.CreateCertificate(bytes.NewReader(make([]byte, 64)), cert, cert, key.Public(), key)
	if err != nil {
		t.Fatal(err)
	}
	epoch := bytes.Repeat([]byte{7}, 16)
	offer := sha256.Sum256([]byte("test offer"))
	message := SessionBindingMessage("session", "nonce", "sha-256 01:23:45", "2100-01-01T00:00:00Z", offer[:], true, "primary", inputProtocolVersion, epoch)
	encode := base64.StdEncoding.EncodeToString
	expected := []byte(fmt.Sprintf("certificate=%s\nepoch=%s\nsignature=%s\n", encode(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})), encode(epoch), encode(ed25519.Sign(key, message))))
	path := filepath.Join("..", "..", "apps", "android", "app", "src", "test", "resources", "screen-trust.properties")
	if os.Getenv("DIETER_UPDATE_TRUST_FIXTURE") == "1" {
		if err := os.WriteFile(path, expected, 0600); err != nil {
			t.Fatal(err)
		}
	}
	actual, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(actual, expected) {
		t.Fatal("screen trust fixture differs; regenerate with DIETER_UPDATE_TRUST_FIXTURE=1 go test ./internal/remotedesktop -run TestAndroidScreenTrustFixture")
	}
}
