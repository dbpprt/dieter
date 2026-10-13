package link

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"errors"
	"math/big"
	"time"

	"github.com/dbpprt/dieter/internal/security/roster"
)

// Device keys travel in self-signed certificates. A certificate is only a
// container for the key: trust comes from the account's device roster, never
// from an issuer, a name or a validity period.

// DeviceCertificate returns a self-signed TLS certificate for key, an Ed25519
// daemon key or an ECDSA P-256 app key.
func DeviceCertificate(key crypto.Signer) (tls.Certificate, error) {
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 120))
	if err != nil {
		return tls.Certificate{}, err
	}
	now := time.Now().UTC()
	template := &x509.Certificate{
		SerialNumber: serial, Subject: pkix.Name{CommonName: "dieter-device"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(10 * 365 * 24 * time.Hour),
		KeyUsage:    x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, key.Public(), key)
	if err != nil {
		return tls.Certificate{}, err
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		return tls.Certificate{}, err
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}, nil
}

// ServerTLSConfig is the daemon side of every carrier: it presents the
// daemon's identity key and requires a client certificate whose key is a
// roster member that may connect.
func ServerTLSConfig(identity *Identity, trust *Trust) (*tls.Config, error) {
	if identity == nil || trust == nil {
		return nil, errors.New("daemon TLS needs its identity and device trust")
	}
	certificate, err := DeviceCertificate(identity.PrivateKey)
	if err != nil {
		return nil, err
	}
	return &tls.Config{
		MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{certificate}, NextProtos: []string{"h2"},
		ClientAuth: tls.RequireAnyClientCert,
		// VerifyConnection also runs on session resumption, so a device revoked
		// after its first handshake cannot resume.
		VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) == 0 {
				return errors.New("a device certificate is required")
			}
			if _, err := trust.Connecting(state.PeerCertificates[0].RawSubjectPublicKeyInfo); err != nil {
				return err
			}
			return nil
		},
	}, nil
}

// ClientTLSConfig presents certificate and accepts only a server whose key is
// daemonKey, the DER SubjectPublicKeyInfo of the target daemon's roster entry.
func ClientTLSConfig(certificate tls.Certificate, daemonKey []byte) (*tls.Config, error) {
	if len(daemonKey) == 0 {
		return nil, errors.New("the daemon's roster key is required")
	}
	expected := append([]byte(nil), daemonKey...)
	return &tls.Config{
		MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{certificate}, NextProtos: []string{"h2"},
		// The roster pins the exact key; there is no CA and no host name.
		InsecureSkipVerify: true,
		VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.PeerCertificates) == 0 || !bytes.Equal(state.PeerCertificates[0].RawSubjectPublicKeyInfo, expected) {
				return errors.New("daemon key does not match the device roster")
			}
			return nil
		},
	}, nil
}

// PeerDevice returns the roster device ID of a TLS peer.
func PeerDevice(state tls.ConnectionState) (string, []byte, bool) {
	if len(state.PeerCertificates) == 0 {
		return "", nil, false
	}
	spki := state.PeerCertificates[0].RawSubjectPublicKeyInfo
	return roster.DeviceID(spki), spki, true
}
