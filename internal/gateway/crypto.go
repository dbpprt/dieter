package gateway

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"math/big"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/dbpprt/dieter/internal/trust"
)

type Keys struct {
	SigningPrivate  ed25519.PrivateKey
	SigningPublic   ed25519.PublicKey
	DaemonCA        *x509.Certificate
	DaemonCAPrivate ed25519.PrivateKey
	DaemonCAPEM     []byte
}

type DaemonTokenClaims = trust.DaemonTokenClaims
type DelegationClaims = trust.DelegationClaims
type RTCConfigurationClaims = trust.RTCConfigurationClaims

func LoadOrCreateKeys(root string) (*Keys, error) {
	dir := filepath.Join(root, "signing")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, err
	}
	signingPrivate, err := loadOrCreateEd25519(filepath.Join(dir, "gateway-ed25519.pem"))
	if err != nil {
		return nil, fmt.Errorf("gateway signing key: %w", err)
	}
	caPrivate, err := loadOrCreateEd25519(filepath.Join(dir, "daemon-ca-ed25519.pem"))
	if err != nil {
		return nil, fmt.Errorf("daemon CA key: %w", err)
	}
	caPath := filepath.Join(dir, "daemon-ca.pem")
	caRaw, err := os.ReadFile(caPath)
	if errors.Is(err, os.ErrNotExist) {
		caRaw, err = createCA(caPrivate)
		if err == nil {
			err = writePrivate(caPath, caRaw, 0o644)
		}
	}
	if err != nil {
		return nil, fmt.Errorf("daemon CA certificate: %w", err)
	}
	block, _ := pem.Decode(caRaw)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, errors.New("daemon CA certificate is invalid")
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, err
	}
	return &Keys{
		SigningPrivate:  signingPrivate,
		SigningPublic:   signingPrivate.Public().(ed25519.PublicKey),
		DaemonCA:        certificate,
		DaemonCAPrivate: caPrivate,
		DaemonCAPEM:     caRaw,
	}, nil
}

func loadOrCreateEd25519(path string) (ed25519.PrivateKey, error) {
	raw, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		_, private, generateErr := ed25519.GenerateKey(rand.Reader)
		if generateErr != nil {
			return nil, generateErr
		}
		encoded, marshalErr := x509.MarshalPKCS8PrivateKey(private)
		if marshalErr != nil {
			return nil, marshalErr
		}
		if writeErr := writePrivate(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: encoded}), 0o600); writeErr != nil {
			return nil, writeErr
		}
		return private, nil
	}
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("private key is not PEM")
	}
	value, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	private, ok := value.(ed25519.PrivateKey)
	if !ok {
		return nil, errors.New("private key is not Ed25519")
	}
	return private, nil
}

func createCA(private ed25519.PrivateKey) ([]byte, error) {
	now := time.Now().UTC()
	template := &x509.Certificate{
		SerialNumber: serialNumber(), Subject: pkix.Name{CommonName: "Dieter daemon CA"},
		NotBefore: now.Add(-time.Minute), NotAfter: now.AddDate(20, 0, 0),
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign | x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true, IsCA: true, MaxPathLenZero: true,
	}
	raw, err := x509.CreateCertificate(rand.Reader, template, template, private.Public(), private)
	if err != nil {
		return nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: raw}), nil
}

func (k *Keys) IssueDaemonCertificate(daemonID string, publicDER []byte) ([]byte, time.Time, error) {
	public, err := x509.ParsePKIXPublicKey(publicDER)
	if err != nil {
		return nil, time.Time{}, fmt.Errorf("parse daemon public key: %w", err)
	}
	if _, ok := public.(ed25519.PublicKey); !ok {
		return nil, time.Time{}, errors.New("daemon public key must be Ed25519")
	}
	identity, _ := url.Parse("spiffe://board/daemon/" + daemonID)
	now := time.Now().UTC()
	expires := now.AddDate(10, 0, 0)
	if caLimit := k.DaemonCA.NotAfter.Add(-time.Hour); expires.After(caLimit) {
		expires = caLimit
	}
	template := &x509.Certificate{
		SerialNumber: serialNumber(), Subject: pkix.Name{CommonName: daemonID},
		NotBefore: now.Add(-time.Minute), NotAfter: expires,
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth},
		URIs:        []*url.URL{identity},
	}
	raw, err := x509.CreateCertificate(rand.Reader, template, k.DaemonCA, public, k.DaemonCAPrivate)
	if err != nil {
		return nil, time.Time{}, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: raw}), expires, nil
}

func (k *Keys) SigningPublicPEM() ([]byte, error) {
	raw, err := x509.MarshalPKIXPublicKey(k.SigningPublic)
	if err != nil {
		return nil, err
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: raw}), nil
}

func (k *Keys) SignDaemonToken(publicURL, daemonID string, githubID int64, generation uint64, thumbprint string, ttl time.Duration) (string, time.Time, error) {
	now := time.Now().UTC()
	expires := now.Add(ttl)
	claims := DaemonTokenClaims{
		Issuer: strings.TrimRight(publicURL, "/"), Subject: fmt.Sprintf("github:%d", githubID), Audience: "board-daemon:" + daemonID,
		ID: randomID("dt_"), IssuedAt: now.Unix(), NotBefore: now.Add(-5 * time.Second).Unix(), ExpiresAt: expires.Unix(),
		DaemonGeneration: generation, ClientThumbprint: strings.TrimSpace(thumbprint),
	}
	token, err := trust.SignCompact(k.SigningPrivate, claims)
	return token, expires, err
}

func (k *Keys) SignDelegation(publicURL string, claims DelegationClaims) (string, error) {
	claims.Issuer = strings.TrimRight(publicURL, "/")
	return trust.SignCompact(k.SigningPrivate, claims)
}

func (k *Keys) SignRTCConfiguration(publicURL string, claims RTCConfigurationClaims) (string, error) {
	claims.Issuer = strings.TrimRight(publicURL, "/")
	return trust.SignCompact(k.SigningPrivate, claims)
}

func ParseAndVerifyDaemonToken(public ed25519.PublicKey, token, issuer, daemonID string, generation uint64, now time.Time) (DaemonTokenClaims, error) {
	return trust.ParseAndVerifyDaemonToken(public, token, issuer, daemonID, generation, now)
}

func ParseAndVerifyDelegation(public ed25519.PublicKey, token, issuer, daemonID, requestID, method string, payload []byte, generation uint64, now time.Time) (DelegationClaims, error) {
	return trust.ParseAndVerifyDelegation(public, token, issuer, daemonID, requestID, method, payload, generation, now)
}

func ParseAndVerifyRTCConfiguration(public ed25519.PublicKey, token, issuer, daemonID, operatorSubject, configurationID string, digest []byte, generation uint64, now time.Time) (RTCConfigurationClaims, error) {
	return trust.ParseAndVerifyRTCConfiguration(public, token, issuer, daemonID, operatorSubject, configurationID, digest, generation, now)
}

func PublicKeyFromPEM(raw []byte) (ed25519.PublicKey, error) {
	return trust.PublicKeyFromPEM(raw)
}

func serialNumber() *big.Int {
	limit := new(big.Int).Lsh(big.NewInt(1), 128)
	value, err := rand.Int(rand.Reader, limit)
	if err != nil {
		return big.NewInt(time.Now().UnixNano())
	}
	return value
}

func randomID(prefix string) string {
	raw := make([]byte, 12)
	if _, err := rand.Read(raw); err != nil {
		return fmt.Sprintf("%s%x", prefix, time.Now().UnixNano())
	}
	return prefix + base64.RawURLEncoding.EncodeToString(raw)
}

func writePrivate(path string, raw []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".dieter-key-*")
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
