package daemon

import (
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
)

type Identity struct {
	ID                      string `json:"id"`
	Name                    string `json:"name"`
	GatewayURL              string `json:"gatewayUrl"`
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
	raw, err := os.ReadFile(filepath.Join(dir, "identity.json"))
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
	identity, err := LoadIdentity(boardHome)
	if err == nil {
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
	if err := atomicWrite(filepath.Join(dir, "identity-key.pem"), pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: privateDER}), 0o600); err != nil {
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
	i.ID, i.Name, i.CertificatePEM, i.DaemonCAPEM, i.GatewaySigningPublicKey, i.CertificateExpiresAt, i.Generation = id, name, certificate, daemonCA, signingPublic, expiresAt, generation
	return i.save()
}

func (i *Identity) Enrolled() bool {
	return i.ID != "" && len(i.CertificatePEM) > 0 && i.GatewayURL != ""
}

func (i *Identity) save() error {
	raw, err := json.MarshalIndent(i, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(filepath.Join(i.Root, "daemon", "identity.json"), append(raw, '\n'), 0o600)
}

func atomicWrite(path string, raw []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".nauclio-daemon-*")
	if err != nil {
		return err
	}
	name := temporary.Name()
	defer os.Remove(name)
	if err := temporary.Chmod(mode); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(raw); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}

func (i *Identity) CertificateExpired(now time.Time) bool {
	value, err := time.Parse(time.RFC3339Nano, i.CertificateExpiresAt)
	return err != nil || !value.After(now.UTC())
}
