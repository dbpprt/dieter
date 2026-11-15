package link

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/security/roster"
	"os"
	"testing"

	"github.com/dbpprt/dieter/internal/model"
)

func TestAttentionTransitionsFollowUnreadAndQuestionState(t *testing.T) {
	t.Parallel()
	tracker := attentionTracker{}
	card := model.Card{ID: "card", OwnerDaemonID: "owner", Runtime: "running"}
	if count, ids := tracker.update([]model.Card{card}, "owner"); count != 0 || len(ids) != 0 {
		t.Fatalf("baseline: %d %v", count, ids)
	}
	card.Runtime = "idle"
	card.ResponseSeq = 1
	if count, ids := tracker.update([]model.Card{card}, "owner"); count != 1 || len(ids) != 1 || ids[0] != card.ID {
		t.Fatalf("reply: %d %v", count, ids)
	}
	card.Title = "Rename"
	if _, ids := tracker.update([]model.Card{card}, "owner"); len(ids) != 0 {
		t.Fatal("rename repeated reply")
	}
	card.SeenResponseSeq = 1
	if count, _ := tracker.update([]model.Card{card}, "owner"); count != 0 {
		t.Fatal("read reply still counted")
	}
	card.Lane = "review"
	if count, _ := tracker.update([]model.Card{card}, "owner"); count != 0 {
		t.Fatal("Review alone is unread")
	}
	card.Runtime = "waiting_for_user"
	if count, ids := tracker.update([]model.Card{card}, "owner"); count != 1 || len(ids) != 1 {
		t.Fatal("question did not alert")
	}
	card.Archived = true
	if count, _ := tracker.update([]model.Card{card}, "owner"); count != 0 {
		t.Fatal("archived question counted")
	}
	card.Archived = false
	if count, _ := tracker.update([]model.Card{card}, "other"); count != 0 {
		t.Fatal("foreign owner counted twice")
	}
	fresh := attentionTracker{}
	if count, ids := fresh.update([]model.Card{card}, "owner"); count != 1 || len(ids) != 0 {
		t.Fatal("cold baseline replayed backlog")
	}
}

func TestSealedAttentionRequiresRecipientAndAuthenticatesCiphertext(t *testing.T) {
	t.Parallel()
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sealed, err := sealAttention(key.PublicKey().Bytes(), "c_private_card")
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(sealed, []byte("c_private_card")) {
		t.Fatal("plaintext destination leaked")
	}

	plain, err := openAttentionVector(key, sealed)
	if err != nil {
		t.Fatal(err)
	}
	var destination map[string]string
	if err := json.Unmarshal(plain, &destination); err != nil || destination["cardId"] != "c_private_card" {
		t.Fatalf("destination: %s %v", plain, err)
	}
	wrong, _ := ecdh.X25519().GenerateKey(rand.Reader)
	if _, err = openAttentionVector(wrong, sealed); err == nil {
		t.Fatal("another account decrypted destination")
	}
	sealed[len(sealed)-1] ^= 1
	if _, err = openAttentionVector(key, sealed); err == nil {
		t.Fatal("tampered destination accepted")
	}
	if _, err = sealAttention(make([]byte, 32), "card"); err == nil {
		t.Fatal("low-order recipient key accepted")
	}
}

func TestPushRecipientProofRejectsGatewaySubstitution(t *testing.T) {
	t.Parallel()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	device, err := roster.Describe(gatewayv1.DeviceKind_DEVICE_KIND_CLIENT, "ios", "phone", "", key.Public())
	if err != nil {
		t.Fatal(err)
	}
	signer := roster.ECDSASigner(key, device)
	genesis, err := roster.Genesis("https://gateway.example|github:1", signer)
	if err != nil {
		t.Fatal(err)
	}
	state, err := roster.Verify([]*roster.Entry{genesis})
	if err != nil {
		t.Fatal(err)
	}
	agreement, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	public := agreement.PublicKey().Bytes()
	message := []byte("dieter-push-key-v1\n" + state.Account() + "\n" + device.DeviceId + "\n" + base64.StdEncoding.EncodeToString(public))
	signature, err := signer.Sign(message)
	if err != nil {
		t.Fatal(err)
	}
	destination := &gatewayv1.PushDestination{DeviceId: device.DeviceId, PublicKey: public, Signature: signature}
	if !validPushDestination(state, destination) {
		t.Fatal("paired phone's signed key was rejected")
	}
	destination.PublicKey = bytes.Repeat([]byte{7}, 32)
	if validPushDestination(state, destination) {
		t.Fatal("gateway substituted a decryption key")
	}
	destination.PublicKey = public
	destination.DeviceId = "dv_unknown"
	if validPushDestination(state, destination) {
		t.Fatal("gateway substituted a device")
	}
	destination.DeviceId = device.DeviceId
	foreign, _ := roster.Genesis("https://gateway.example|github:2", signer)
	other, _ := roster.Verify([]*roster.Entry{foreign})
	if validPushDestination(other, destination) {
		t.Fatal("a proof crossed account boundaries")
	}
	backupKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	backup, err := roster.Describe(gatewayv1.DeviceKind_DEVICE_KIND_CLIENT, "macos", "backup", "", backupKey.Public())
	if err != nil {
		t.Fatal(err)
	}
	added, err := state.Add(backup, signer)
	if err != nil {
		t.Fatal(err)
	}
	state, err = roster.Verify([]*roster.Entry{genesis, added})
	if err != nil {
		t.Fatal(err)
	}
	revoked, err := state.Revoke(device.DeviceId, roster.ECDSASigner(backupKey, backup))
	if err != nil {
		t.Fatal(err)
	}
	after, err := roster.Verify([]*roster.Entry{genesis, added, revoked})
	if err != nil {
		t.Fatal(err)
	}
	if validPushDestination(after, destination) {
		t.Fatal("revoked phone retained delivery")
	}
}

func openAttentionVector(private *ecdh.PrivateKey, payload []byte) ([]byte, error) {
	ephemeral, e := ecdh.X25519().NewPublicKey(payload[:32])
	if e != nil {
		return nil, e
	}
	shared, e := private.ECDH(ephemeral)
	if e != nil {
		return nil, e
	}
	derived, e := hkdf.Key(sha256.New, shared, nil, "dieter-attention-v1", 32)
	if e != nil {
		return nil, e
	}
	block, e := aes.NewCipher(derived)
	if e != nil {
		return nil, e
	}
	aead, e := cipher.NewGCM(block)
	if e != nil {
		return nil, e
	}
	return aead.Open(nil, payload[32:44], payload[44:], []byte("dieter-attention-v1"))
}

// This daemon envelope is consumed by Android's platform crypto unit test too.
func TestPushEnvelopeMatchesAndroidVector(t *testing.T) {
	t.Parallel()
	raw, err := os.ReadFile("../../tests/fixtures/push-envelope.json")
	if err != nil {
		t.Fatal(err)
	}
	var vector struct{ PrivateKey, Sealed, CardID string }
	if err := json.Unmarshal(raw, &vector); err != nil {
		t.Fatal(err)
	}
	private, _ := base64.StdEncoding.DecodeString(vector.PrivateKey)
	sealed, _ := base64.StdEncoding.DecodeString(vector.Sealed)
	key, err := ecdh.X25519().NewPrivateKey(private)
	if err != nil {
		t.Fatal(err)
	}
	plain, err := openAttentionVector(key, sealed)
	if err != nil {
		t.Fatal(err)
	}
	var payload struct{ CardID string }
	if err := json.Unmarshal(plain, &payload); err != nil || payload.CardID != vector.CardID {
		t.Fatal("cross-platform envelope drift", err)
	}
}
