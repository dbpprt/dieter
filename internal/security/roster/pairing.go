package roster

import (
	"bytes"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"errors"
)

// A new device joins with a one-time secret that only its own screen shows.
// A person types the secret's code on a trusted device. Both directions are
// authenticated by HMACs keyed with the secret, which never reaches the
// gateway: the request's proof binds the new device's descriptor, so the
// approver adds exactly that key, and the approver's confirmation binds the
// roster root and the entry that added the device, so the new device pins the
// approver's roster rather than one the gateway made up.

const (
	pairingSecretBytes  = 10
	pairingRequestLabel = "dieter-pair-request-v1"
	pairingConfirmLabel = "dieter-pair-confirm-v1"
)

// NewPairingSecret returns a fresh secret and the code its device shows.
func NewPairingSecret() ([]byte, string, error) {
	secret := make([]byte, pairingSecretBytes)
	if _, err := rand.Read(secret); err != nil {
		return nil, "", err
	}
	return secret, PairingCode(secret), nil
}

// PairingCode is the printable form of a pairing secret, e.g.
// "ABCD-EFGH-JKMN-PQRS".
func PairingCode(secret []byte) string { return groupCode(secret) }

// ParsePairingCode accepts a typed code in any case, with or without
// separators and with confusable characters.
func ParsePairingCode(code string) ([]byte, error) {
	secret, err := decodeCode(code)
	if err != nil || len(secret) != pairingSecretBytes {
		return nil, errors.New("pairing code is malformed; it has 16 characters")
	}
	return secret, nil
}

// PairingProof authenticates a pairing request's descriptor.
func PairingProof(secret []byte, device *Descriptor) []byte {
	return pairingMAC(secret, pairingRequestLabel, DescriptorBytes(device))
}

// VerifyPairingProof reports whether proof was made with secret for device.
func VerifyPairingProof(secret []byte, device *Descriptor, proof []byte) bool {
	return hmac.Equal(PairingProof(secret, device), proof)
}

// PairingConfirmation authenticates the roster a new device pins: its root
// and the hash of the entry that added the device.
func PairingConfirmation(secret, root, addHash []byte) []byte {
	return pairingMAC(secret, pairingConfirmLabel, root, addHash)
}

// VerifyPairingConfirmation reports whether confirmation was made with secret
// for that root and entry.
func VerifyPairingConfirmation(secret, root, addHash, confirmation []byte) bool {
	return hmac.Equal(PairingConfirmation(secret, root, addHash), confirmation)
}

func pairingMAC(secret []byte, label string, fields ...[]byte) []byte {
	var message bytes.Buffer
	message.WriteString(label)
	writeFields(&message, fields...)
	mac := hmac.New(sha256.New, secret)
	mac.Write(message.Bytes())
	return mac.Sum(nil)
}
