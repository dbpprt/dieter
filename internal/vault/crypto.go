// Package vault implements Dieter's account vault cryptography. Every replicated
// value is ciphertext: the gateway relays and peer replicas store only sealed
// keyrings and AES-256-GCM item envelopes. Each member machine holds an
// X-Wing (ML-KEM-768 + X25519) HPKE key; a keyring with every vault key is
// sealed to it. Keys after the root are authenticated by their parent key, and
// the root is pinned out of band (join code or recovery key), so a replica or
// relay that can write peer records still cannot substitute vault keys.
package vault

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/hpke"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strings"
)

const (
	KindVault  = "vault"
	KindMember = "vault-member"
	KindItem   = "vault-item"

	// VaultRecordID is the single vault metadata record of an account.
	VaultRecordID = "vault"
	// RecoveryMemberID is the keyring holder derived from the recovery key.
	RecoveryMemberID = "recovery"

	seedBytes = 32
	keyBytes  = 32
)

var (
	ErrLocked        = errors.New("this machine is not an unlocked vault member")
	ErrTampered      = errors.New("vault data failed authentication")
	ErrWrongRecovery = errors.New("recovery key does not match this vault")
	ErrNoVault       = errors.New("no vault exists for this account; run `dieter vault init`")
)

var b64 = base64.RawStdEncoding

// Record is the plaintext metadata of the account vault. It contains no key
// material: RootHash commits to the root key that members pin when joining.
type Record struct {
	ID        string `json:"id"`
	Root      string `json:"root"`
	RootHash  string `json:"rootHash"`
	Current   string `json:"current"`
	CreatedAt string `json:"createdAt"`
}

// Member is one keyring recipient. A member without Keyring is a pending join
// request. Name and DaemonID are display hints, never authorization inputs.
type Member struct {
	PublicKey   string `json:"publicKey"`
	Keyring     string `json:"keyring,omitempty"`
	Name        string `json:"name,omitempty"`
	DaemonID    string `json:"daemonId,omitempty"`
	Recovery    bool   `json:"recovery,omitempty"`
	RequestedAt string `json:"requestedAt,omitempty"`
	ApprovedAt  string `json:"approvedAt,omitempty"`
	ApprovedBy  string `json:"approvedBy,omitempty"`
}

// Envelope is a replicated item: AES-256-GCM under vault key Key, bound to the
// vault and item IDs through associated data.
type Envelope struct {
	Key   string `json:"key"`
	Nonce string `json:"nonce"`
	Data  string `json:"data"`
}

type KeyEntry struct {
	ID     string `json:"id"`
	Key    string `json:"key"`
	Parent string `json:"parent,omitempty"`
	Auth   string `json:"auth,omitempty"`
}

// Keyring is the sealed plaintext delivered to each member.
type Keyring struct {
	VaultID string     `json:"vaultId"`
	Keys    []KeyEntry `json:"keys"`
	// RecoveryCheck authenticates the root to a holder of the recovery key.
	RecoveryCheck string `json:"recoveryCheck,omitempty"`
}

func randomBytes(n int) []byte {
	value := make([]byte, n)
	if _, err := rand.Read(value); err != nil {
		panic(err)
	}
	return value
}

// RandomID returns a prefixed 128-bit identifier valid as a peer record ID.
func RandomID(prefix string) string {
	return prefix + strings.ToLower(crockford.EncodeToString(randomBytes(16)))
}

func label(parts ...string) []byte { return []byte(strings.Join(parts, "\x00")) }

func rootHash(vaultID, rootID string, key []byte) string {
	sum := sha256.Sum256(append(label("dieter-vault-root-v1", vaultID, rootID, ""), key...))
	return b64.EncodeToString(sum[:])
}

func keyAuth(parent []byte, vaultID, id string, key []byte) []byte {
	mac := hmac.New(sha256.New, parent)
	mac.Write(label("dieter-vault-key-v1", vaultID, id, ""))
	mac.Write(key)
	return mac.Sum(nil)
}

// New creates a vault with one root key. The caller replicates the record and
// seals the keyring to the creating machine and the recovery key.
func New(now string) (Record, Keyring) {
	vaultID, rootID := RandomID("vlt_"), RandomID("k_")
	key := randomBytes(keyBytes)
	return Record{ID: vaultID, Root: rootID, RootHash: rootHash(vaultID, rootID, key), Current: rootID, CreatedAt: now},
		Keyring{VaultID: vaultID, Keys: []KeyEntry{{ID: rootID, Key: b64.EncodeToString(key)}}}
}

// Verify checks the keyring against the pinned vault ID and root commitment
// and returns every authenticated key by ID. One forged entry rejects the
// keyring; members never use a key whose chain does not reach the pinned root.
func (k Keyring) Verify(vaultID, pinnedRootHash string) (map[string][]byte, error) {
	if k.VaultID != vaultID || vaultID == "" {
		return nil, ErrTampered
	}
	entries := map[string]KeyEntry{}
	for _, entry := range k.Keys {
		if _, exists := entries[entry.ID]; exists || entry.ID == "" {
			return nil, ErrTampered
		}
		entries[entry.ID] = entry
	}
	verified := map[string][]byte{}
	var verify func(id string, depth int) ([]byte, error)
	verify = func(id string, depth int) ([]byte, error) {
		if key, ok := verified[id]; ok {
			return key, nil
		}
		entry, ok := entries[id]
		if !ok || depth > len(entries) {
			return nil, ErrTampered
		}
		key, err := b64.DecodeString(entry.Key)
		if err != nil || len(key) != keyBytes {
			return nil, ErrTampered
		}
		if entry.Parent == "" {
			if subtle.ConstantTimeCompare([]byte(rootHash(vaultID, id, key)), []byte(pinnedRootHash)) != 1 {
				return nil, ErrTampered
			}
		} else {
			parent, err := verify(entry.Parent, depth+1)
			if err != nil {
				return nil, err
			}
			auth, err := b64.DecodeString(entry.Auth)
			if err != nil || !hmac.Equal(auth, keyAuth(parent, vaultID, id, key)) {
				return nil, ErrTampered
			}
		}
		verified[id] = key
		return key, nil
	}
	for id := range entries {
		if _, err := verify(id, 0); err != nil {
			return nil, err
		}
	}
	return verified, nil
}

// Rotate appends a fresh key authenticated by parent. The keyring must already
// be verified; the returned ID becomes the vault's current key.
func (k Keyring) Rotate(keys map[string][]byte, parent string) (Keyring, string, error) {
	parentKey, ok := keys[parent]
	if !ok {
		return k, "", ErrLocked
	}
	id, key := RandomID("k_"), randomBytes(keyBytes)
	next := k
	next.Keys = append(append([]KeyEntry(nil), k.Keys...), KeyEntry{
		ID: id, Key: b64.EncodeToString(key), Parent: parent,
		Auth: b64.EncodeToString(keyAuth(parentKey, k.VaultID, id, key)),
	})
	return next, id, nil
}

// Union combines concurrently rotated keyrings of the same vault.
func Union(rings ...Keyring) Keyring {
	var result Keyring
	seen := map[string]bool{}
	for _, ring := range rings {
		if result.VaultID == "" {
			result.VaultID = ring.VaultID
		}
		if result.RecoveryCheck == "" {
			result.RecoveryCheck = ring.RecoveryCheck
		}
		for _, entry := range ring.Keys {
			if !seen[entry.ID] {
				seen[entry.ID] = true
				result.Keys = append(result.Keys, entry)
			}
		}
	}
	sort.Slice(result.Keys, func(i, j int) bool { return result.Keys[i].ID < result.Keys[j].ID })
	return result
}

func suite() (hpke.KEM, hpke.KDF, hpke.AEAD) {
	return hpke.MLKEM768X25519(), hpke.HKDFSHA256(), hpke.AES256GCM()
}

// NewMemberSeed returns a fresh private member key seed.
func NewMemberSeed() []byte { return randomBytes(seedBytes) }

// PublicKey derives the member public key from its seed.
func PublicKey(seed []byte) ([]byte, error) {
	kem, _, _ := suite()
	private, err := kem.NewPrivateKey(seed)
	if err != nil {
		return nil, err
	}
	return private.PublicKey().Bytes(), nil
}

func keyringInfo(vaultID, memberID string) []byte {
	return label("dieter-vault-keyring-v1", vaultID, memberID)
}

// Seal encrypts a keyring to one member. The info binds vault and member so a
// sealed keyring cannot be replayed to another member record.
func Seal(publicKey []byte, ring Keyring, memberID string) (string, error) {
	kem, kdf, aead := suite()
	public, err := kem.NewPublicKey(publicKey)
	if err != nil {
		return "", fmt.Errorf("invalid member public key: %w", err)
	}
	plaintext, err := json.Marshal(ring)
	if err != nil {
		return "", err
	}
	sealed, err := hpke.Seal(public, kdf, aead, keyringInfo(ring.VaultID, memberID), plaintext)
	if err != nil {
		return "", err
	}
	return b64.EncodeToString(sealed), nil
}

// Open decrypts this member's keyring. Callers must still check it with Verify.
func Open(seed []byte, sealed, vaultID, memberID string) (Keyring, error) {
	kem, kdf, aead := suite()
	private, err := kem.NewPrivateKey(seed)
	if err != nil {
		return Keyring{}, err
	}
	raw, err := b64.DecodeString(sealed)
	if err != nil {
		return Keyring{}, ErrTampered
	}
	plaintext, err := hpke.Open(private, kdf, aead, keyringInfo(vaultID, memberID), raw)
	if err != nil {
		return Keyring{}, ErrTampered
	}
	var ring Keyring
	if err := json.Unmarshal(plaintext, &ring); err != nil || ring.VaultID != vaultID {
		return Keyring{}, ErrTampered
	}
	return ring, nil
}

func itemAAD(vaultID, itemID, keyID string) []byte {
	return label("dieter-vault-item-v1", vaultID, itemID, keyID)
}

func gcm(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// SealItem encrypts an item under the current vault key.
func SealItem(keys map[string][]byte, keyID, vaultID, itemID string, item Item) (Envelope, error) {
	key, ok := keys[keyID]
	if !ok {
		return Envelope{}, ErrLocked
	}
	if err := item.Validate(); err != nil {
		return Envelope{}, err
	}
	plaintext, err := json.Marshal(item)
	if err != nil {
		return Envelope{}, err
	}
	aead, err := gcm(key)
	if err != nil {
		return Envelope{}, err
	}
	nonce := randomBytes(aead.NonceSize())
	return Envelope{Key: keyID, Nonce: b64.EncodeToString(nonce), Data: b64.EncodeToString(aead.Seal(nil, nonce, plaintext, itemAAD(vaultID, itemID, keyID)))}, nil
}

// OpenItem decrypts and authenticates an item envelope.
func OpenItem(keys map[string][]byte, vaultID, itemID string, envelope Envelope) (Item, error) {
	key, ok := keys[envelope.Key]
	if !ok {
		return Item{}, fmt.Errorf("%w: item uses an unknown vault key", ErrLocked)
	}
	nonce, nonceErr := b64.DecodeString(envelope.Nonce)
	data, dataErr := b64.DecodeString(envelope.Data)
	aead, err := gcm(key)
	if nonceErr != nil || dataErr != nil || err != nil || len(nonce) != aead.NonceSize() {
		return Item{}, ErrTampered
	}
	plaintext, err := aead.Open(nil, nonce, data, itemAAD(vaultID, itemID, envelope.Key))
	if err != nil {
		return Item{}, ErrTampered
	}
	var item Item
	if err := json.Unmarshal(plaintext, &item); err != nil {
		return Item{}, ErrTampered
	}
	return item, nil
}

// JoinCode is the out-of-band verification code for a pending member. Both the
// joining and the approving machine compute it from their own view; a relay
// that substitutes the vault root or the member key changes the code.
func JoinCode(vaultID, pinnedRootHash, memberID string, publicKey []byte) string {
	sum := sha256.Sum256(append(label("dieter-vault-join-v1", vaultID, pinnedRootHash, memberID, ""), publicKey...))
	return group(crockford.EncodeToString(sum[:10]), 4)
}

// SameCode compares a typed code, ignoring case, separators and confusable
// Crockford characters.
func SameCode(expected, typed string) bool {
	return subtle.ConstantTimeCompare([]byte(normalizeCode(expected)), []byte(normalizeCode(typed))) == 1
}

func normalizeCode(value string) string {
	value = strings.ToUpper(value)
	value = strings.NewReplacer("-", "", " ", "", "O", "0", "I", "1", "L", "1").Replace(value)
	return value
}

func group(value string, size int) string {
	var parts []string
	for len(value) > size {
		parts = append(parts, value[:size])
		value = value[size:]
	}
	return strings.Join(append(parts, value), "-")
}

var crockford = newCrockford()

func newCrockford() *base32Encoding {
	return &base32Encoding{alphabet: "0123456789ABCDEFGHJKMNPQRSTVWXYZ"}
}

// base32Encoding is unpadded Crockford base32 for human-typed codes.
type base32Encoding struct{ alphabet string }

func (e *base32Encoding) EncodeToString(data []byte) string {
	var out strings.Builder
	var buffer, bits uint
	for _, value := range data {
		buffer = buffer<<8 | uint(value)
		bits += 8
		for bits >= 5 {
			bits -= 5
			out.WriteByte(e.alphabet[(buffer>>bits)&31])
		}
	}
	if bits > 0 {
		out.WriteByte(e.alphabet[(buffer<<(5-bits))&31])
	}
	return out.String()
}

func (e *base32Encoding) DecodeString(value string) ([]byte, error) {
	var out []byte
	var buffer, bits uint
	for _, char := range normalizeCode(value) {
		index := strings.IndexRune(e.alphabet, char)
		if index < 0 {
			return nil, errors.New("invalid character")
		}
		buffer = buffer<<5 | uint(index)
		bits += 5
		if bits >= 8 {
			bits -= 8
			out = append(out, byte(buffer>>bits))
		}
	}
	return out, nil
}

const recoveryPrefix = "DVR1"

// NewRecoveryKey returns a recovery seed and its printable form.
func NewRecoveryKey() ([]byte, string) {
	seed := randomBytes(seedBytes)
	return seed, FormatRecoveryKey(seed)
}

func FormatRecoveryKey(seed []byte) string {
	sum := sha256.Sum256(append([]byte("dieter-vault-recovery-checksum-v1"), seed...))
	return recoveryPrefix + "-" + group(crockford.EncodeToString(append(append([]byte(nil), seed...), sum[:2]...)), 5)
}

// ParseRecoveryKey accepts the printed form with any spacing or case.
func ParseRecoveryKey(value string) ([]byte, error) {
	value = strings.TrimSpace(value)
	normalized := normalizeCode(value)
	if !strings.HasPrefix(normalized, recoveryPrefix) {
		return nil, errors.New("recovery key must start with " + recoveryPrefix)
	}
	raw, err := crockford.DecodeString(strings.TrimPrefix(normalized, recoveryPrefix))
	if err != nil || len(raw) != seedBytes+2 {
		return nil, errors.New("recovery key is malformed")
	}
	seed := raw[:seedBytes]
	sum := sha256.Sum256(append([]byte("dieter-vault-recovery-checksum-v1"), seed...))
	if subtle.ConstantTimeCompare(sum[:2], raw[seedBytes:]) != 1 {
		return nil, errors.New("recovery key checksum does not match; check for typing errors")
	}
	return seed, nil
}

// RecoveryCheck lets a recovery-key holder authenticate the vault root without
// trusting replicated metadata.
func RecoveryCheck(seed []byte, vaultID, rootID string, rootKey []byte) (string, error) {
	authKey, err := hkdf.Key(sha256.New, seed, nil, "dieter-vault-recovery-auth-v1", keyBytes)
	if err != nil {
		return "", err
	}
	mac := hmac.New(sha256.New, authKey)
	mac.Write(label("dieter-vault-recovery-root-v1", vaultID, rootID, ""))
	mac.Write(rootKey)
	return b64.EncodeToString(mac.Sum(nil)), nil
}

// RecoveredRoot authenticates a keyring opened with the recovery key and
// returns the root commitment to pin.
func RecoveredRoot(seed []byte, ring Keyring) (string, error) {
	for _, entry := range ring.Keys {
		if entry.Parent != "" {
			continue
		}
		key, err := b64.DecodeString(entry.Key)
		if err != nil {
			return "", ErrTampered
		}
		check, err := RecoveryCheck(seed, ring.VaultID, entry.ID, key)
		if err != nil {
			return "", err
		}
		if subtle.ConstantTimeCompare([]byte(check), []byte(ring.RecoveryCheck)) == 1 {
			return rootHash(ring.VaultID, entry.ID, key), nil
		}
	}
	return "", ErrWrongRecovery
}

// RootKey returns the verified root key of a keyring.
func (k Keyring) RootKey(keys map[string][]byte) (string, []byte, bool) {
	for _, entry := range k.Keys {
		if entry.Parent == "" {
			key, ok := keys[entry.ID]
			return entry.ID, key, ok
		}
	}
	return "", nil, false
}
