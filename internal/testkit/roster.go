package testkit

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/security/roster"
	"github.com/dbpprt/dieter/internal/security/trust"
	"google.golang.org/protobuf/proto"
)

// TestAccount is the roster account of isolated rosters.
const TestAccount = "https://gateway.example|github:42"

// DaemonSigner describes an Ed25519 daemon key as a roster device.
func DaemonSigner(tb testing.TB, key ed25519.PrivateKey, daemonID, name string) roster.Signer {
	tb.Helper()
	descriptor, err := roster.Describe(gatewayv1.DeviceKind_DEVICE_KIND_DAEMON, "linux", name, daemonID, key.Public())
	if err != nil {
		tb.Fatal(err)
	}
	return roster.Ed25519Signer(key, descriptor)
}

// PinRoster writes the roster a daemon in root pinned, without a gateway:
// first starts it, then adds every device. It returns the verified roster.
func PinRoster(tb testing.TB, root, account string, first roster.Signer, devices ...*roster.Descriptor) *roster.State {
	tb.Helper()
	genesis, err := roster.Genesis(account, first)
	if err != nil {
		tb.Fatal(err)
	}
	state, err := roster.Verify([]*roster.Entry{genesis})
	if err != nil {
		tb.Fatal(err)
	}
	for _, device := range devices {
		entry, err := state.Add(device, first)
		if err != nil {
			tb.Fatal(err)
		}
		if state, err = state.Extend([]*roster.Entry{entry}); err != nil {
			tb.Fatal(err)
		}
	}
	WriteRoster(tb, root, state)
	return state
}

// WriteRoster replaces the pinned roster of the daemon in root.
func WriteRoster(tb testing.TB, root string, state *roster.State) {
	tb.Helper()
	raw, err := proto.Marshal(state.Proto(0))
	if err != nil {
		tb.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "daemon"), 0o700); err != nil {
		tb.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "daemon", "roster.pb"), raw, 0o600); err != nil {
		tb.Fatal(err)
	}
}

// SigningKey is a gateway signing key and its public PEM, for daemons that
// verify tokens without a gateway.
func SigningKey(tb testing.TB) (ed25519.PrivateKey, []byte) {
	tb.Helper()
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		tb.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(public)
	if err != nil {
		tb.Fatal(err)
	}
	return private, pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der})
}

// DaemonToken signs a daemon token as the gateway does, bound to the caller's
// roster device ID thumbprint.
func DaemonToken(tb testing.TB, key ed25519.PrivateKey, issuer, daemonID string, generation uint64, thumbprint string, ttl time.Duration) (string, time.Time) {
	tb.Helper()
	nonce := make([]byte, 12)
	_, _ = rand.Read(nonce)
	now := time.Now().UTC()
	expires := now.Add(ttl)
	token, err := trust.SignCompact(key, trust.DaemonTokenClaims{
		Issuer: strings.TrimRight(issuer, "/"), Subject: "github:42", Audience: "board-daemon:" + daemonID, ID: "dt_" + hex.EncodeToString(nonce),
		IssuedAt: now.Unix(), NotBefore: now.Unix(), ExpiresAt: expires.Unix(), DaemonGeneration: generation, ClientThumbprint: thumbprint,
	})
	if err != nil {
		tb.Fatal(err)
	}
	return token, time.Unix(expires.Unix(), 0)
}
