package linkauth

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"errors"
	"strings"
)

const (
	linkDomain     = "board-daemon-link-v1"
	unenrollDomain = "dieter-daemon-unenroll-v1"
)

func Message(gatewayURL, daemonID string, challenge []byte) []byte {
	return actionMessage(linkDomain, gatewayURL, daemonID, challenge)
}

func Sign(private ed25519.PrivateKey, gatewayURL, daemonID string, challenge []byte) []byte {
	return ed25519.Sign(private, Message(gatewayURL, daemonID, challenge))
}

func SignUnenrollment(private ed25519.PrivateKey, gatewayURL, daemonID string, nonce []byte) []byte {
	return ed25519.Sign(private, actionMessage(unenrollDomain, gatewayURL, daemonID, nonce))
}

func VerifyCertificate(certificatePEM []byte, gatewayURL, daemonID string, challenge, signature []byte) error {
	return verifyCertificate(certificatePEM, Message(gatewayURL, daemonID, challenge), signature)
}

func VerifyUnenrollment(certificatePEM []byte, gatewayURL, daemonID string, nonce, signature []byte) error {
	return verifyCertificate(certificatePEM, actionMessage(unenrollDomain, gatewayURL, daemonID, nonce), signature)
}

func actionMessage(domain, gatewayURL, daemonID string, nonce []byte) []byte {
	return []byte(domain + "\n" + strings.TrimRight(gatewayURL, "/") + "\n" + daemonID + "\n" + base64.RawURLEncoding.EncodeToString(nonce))
}

func verifyCertificate(certificatePEM, message, signature []byte) error {
	block, _ := pem.Decode(certificatePEM)
	if block == nil || block.Type != "CERTIFICATE" {
		return errors.New("daemon certificate is invalid")
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return errors.New("daemon certificate is invalid")
	}
	public, ok := certificate.PublicKey.(ed25519.PublicKey)
	if !ok || !ed25519.Verify(public, message, signature) {
		return errors.New("daemon challenge signature is invalid")
	}
	return nil
}
