package roster

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
)

// PushKeyBytes binds an X25519 notification recipient to one account and device.
// The Kotlin client signs these same UTF-8 bytes with its roster key.
func PushKeyBytes(account, deviceID string, publicKey []byte) []byte {
	return []byte("dieter-push-key-v1\n" + account + "\n" + deviceID + "\n" + base64.StdEncoding.EncodeToString(publicKey))
}

// VerifyPushKey prevents a gateway from substituting its own decryption key.
// Daemons use their own pinned roster; the gateway also checks its stored roster.
func VerifyPushKey(state *State, destination *gatewayv1.PushDestination) bool {
	if state == nil || destination == nil || len(destination.GetPublicKey()) != 32 {
		return false
	}
	member := state.Member(destination.GetDeviceId())
	if member == nil || !member.Connects() {
		return false
	}
	message := PushKeyBytes(state.Account(), destination.GetDeviceId(), destination.GetPublicKey())
	switch key := member.PublicKey().(type) {
	case ed25519.PublicKey:
		return ed25519.Verify(key, message, destination.GetSignature())
	case *ecdsa.PublicKey:
		digest := sha256.Sum256(message)
		return ecdsa.VerifyASN1(key, digest[:], destination.GetSignature())
	}
	return false
}
