package link

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fsx"
	"github.com/dbpprt/dieter/internal/security/trust"
)

type Identity struct {
	ID                      string `json:"id"`
	Name                    string `json:"name"`
	GatewayURL              string `json:"gatewayUrl"`
	GatewayIssuer           string `json:"gatewayIssuer,omitempty"`
	CertificatePEM          []byte `json:"certificatePem"`
	DaemonCAPEM             []byte `json:"daemonCaPem"`
	GatewaySigningPublicKey []byte `json:"gatewaySigningPublicKey"`
	CertificateExpiresAt    string `json:"certificateExpiresAt"`
	Generation              uint64 `json:"generation"`

	PrivateKey ed25519.PrivateKey `json:"-"`
	PublicKey  ed25519.PublicKey  `json:"-"`
	Root       string             `json:"-"`
}

func LoadIdentity(boardHome string) (*Identity, error) {
	dir := filepath.Join(boardHome, "daemon")
	raw, err := os.ReadFile(identityPath(boardHome))
	if err != nil {
		return nil, err
	}
	var identity Identity
	if err := json.Unmarshal(raw, &identity); err != nil {
		return nil, fmt.Errorf("decode daemon identity: %w", err)
	}
	privateRaw, err := os.ReadFile(filepath.Join(dir, "identity-key.pem"))
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(privateRaw)
	if block == nil {
		return nil, errors.New("daemon identity key is invalid")
	}
	value, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	private, ok := value.(ed25519.PrivateKey)
	if !ok {
		return nil, errors.New("daemon identity key is not Ed25519")
	}
	identity.PrivateKey = private
	identity.PublicKey = private.Public().(ed25519.PublicKey)
	identity.Root = boardHome
	return &identity, nil
}

func LoadOrCreateEnrollmentIdentity(boardHome, name, gatewayURL string) (*Identity, error) {
	gatewayURL, err := trust.GatewayOrigin(gatewayURL)
	if err != nil {
		return nil, err
	}
	identity, err := LoadIdentity(boardHome)
	if err == nil {
		// A failed enrollment must not pin subsequent attempts to an old origin.
		// Preserve the key so retrying never changes this machine's identity.
		if !identity.Enrolled() && (identity.GatewayURL != gatewayURL || identity.Name != name) {
			identity.GatewayURL, identity.Name = gatewayURL, name
			if err := identity.save(); err != nil {
				return nil, err
			}
		}
		return identity, nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	dir := filepath.Join(boardHome, "daemon")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, err
	}
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	privateDER, err := x509.MarshalPKCS8PrivateKey(private)
	if err != nil {
		return nil, err
	}
	key := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateDER})
	if err := writeLocked(boardHome, func() error { return fsx.WriteFile(filepath.Join(dir, "identity-key.pem"), key, 0o600) }); err != nil {
		return nil, err
	}
	identity = &Identity{Name: name, GatewayURL: gatewayURL, PrivateKey: private, PublicKey: public, Root: boardHome}
	if err := identity.save(); err != nil {
		return nil, err
	}
	return identity, nil
}

func (i *Identity) PublicKeyDER() ([]byte, error) { return x509.MarshalPKIXPublicKey(i.PublicKey) }

func (i *Identity) SaveCredential(id, name string, certificate, daemonCA, signingPublic []byte, expiresAt string, generation uint64) error {
	if i.GatewayIssuer != "" {
		issuer, err := trust.GatewayOrigin(i.GatewayIssuer)
		if err != nil || issuer != i.GatewayIssuer {
			return errors.New("invalid enrolled gateway issuer")
		}
	}
	i.ID, i.Name, i.CertificatePEM, i.DaemonCAPEM, i.GatewaySigningPublicKey, i.CertificateExpiresAt, i.Generation = id, name, certificate, daemonCA, signingPublic, expiresAt, generation
	return i.save()
}

func (i *Identity) ClearCredential() error {
	i.ID = ""
	i.CertificatePEM = nil
	i.DaemonCAPEM = nil
	i.GatewaySigningPublicKey = nil
	i.CertificateExpiresAt = ""
	i.Generation = 0
	i.GatewayIssuer = ""
	return i.save()
}

func (i *Identity) Enrolled() bool {
	return i.ID != "" && len(i.CertificatePEM) > 0 && i.GatewayURL != ""
}

// identityPath is daemon/identity.json. This package is its only writer and
// writes it under the central DIETER_HOME writer lock.
func identityPath(root string) string { return filepath.Join(root, "daemon", "identity.json") }

func (i *Identity) save() error {
	raw, err := json.MarshalIndent(i, "", "  ")
	if err != nil {
		return err
	}
	return writeLocked(i.Root, func() error {
		return fsx.WriteFile(identityPath(i.Root), append(raw, '\n'), 0o600)
	})
}

// writeLocked runs write while holding the central writer lock, so identity
// changes serialize with every other mutation of the same DIETER_HOME.
func writeLocked(root string, write func() error) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	lock, err := fsx.LockHome(ctx, root)
	if err != nil {
		return fmt.Errorf("lock daemon identity: %w", err)
	}
	defer lock.Close()
	return write()
}

// RelocateGateway commits a verified endpoint change for the enrollment that
// expected describes. Keys, enrollment generation, certificates, the issuer
// and peer identity remain byte-for-byte unchanged; it fails when the saved
// enrollment changed meanwhile. Call only after pinned-key discovery
// (ResolveGatewayEndpoint).
func RelocateGateway(expected *Identity, endpoint string) error {
	previous, issuer := expected.GatewayURL, expected.Issuer()
	for _, origin := range []string{previous, issuer, endpoint} {
		value, err := trust.GatewayOrigin(origin)
		if err != nil || value != origin {
			return errors.New("invalid gateway origin")
		}
	}
	path := identityPath(expected.Root)
	return writeLocked(expected.Root, func() error {
		raw, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var identity map[string]json.RawMessage
		if err = json.Unmarshal(raw, &identity); err != nil {
			return err
		}
		var current struct {
			ID     string `json:"id"`
			URL    string `json:"gatewayUrl"`
			Issuer string `json:"gatewayIssuer"`
			Key    []byte `json:"gatewaySigningPublicKey"`
		}
		if err = json.Unmarshal(raw, &current); err != nil {
			return err
		}
		if current.Issuer == "" {
			current.Issuer = current.URL
		}
		if current.ID != expected.ID || current.URL != previous || current.Issuer != issuer || !bytes.Equal(current.Key, expected.GatewaySigningPublicKey) {
			return errors.New("daemon enrollment changed during gateway relocation")
		}
		identity["gatewayUrl"], _ = json.Marshal(endpoint)
		identity["gatewayIssuer"], _ = json.Marshal(issuer)
		raw, err = json.MarshalIndent(identity, "", "  ")
		if err != nil {
			return err
		}
		return fsx.WriteFile(path, append(raw, '\n'), 0o600)
	})
}

func (i *Identity) CertificateExpired(now time.Time) bool {
	value, err := time.Parse(time.RFC3339Nano, i.CertificateExpiresAt)
	return err != nil || !value.After(now.UTC())
}

// Issuer is the durable authentication and peer-store namespace. GatewayURL is
// only the current HTTPS endpoint. Existing enrollments already use their URL
// as the namespace and retain it across an authenticated endpoint relocation.
func (i *Identity) Issuer() string {
	if i.GatewayIssuer != "" {
		return i.GatewayIssuer
	}
	return i.GatewayURL
}
