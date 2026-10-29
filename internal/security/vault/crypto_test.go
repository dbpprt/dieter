package vault

import (
	"errors"
	"strings"
	"testing"
)

func TestUnionMergesConcurrentRotations(t *testing.T) {
	t.Parallel()
	record, ring, keys := memberKeyring(t)
	left, leftKey, err := ring.Rotate(keys, record.Root)
	if err != nil {
		t.Fatal(err)
	}
	right, rightKey, err := ring.Rotate(keys, record.Root)
	if err != nil {
		t.Fatal(err)
	}
	merged := Union(left, right, left)
	if len(merged.Keys) != 3 || merged.VaultID != record.ID {
		t.Fatalf("merged keyring = %+v", merged)
	}
	verified, err := merged.Verify(record.ID, record.RootHash)
	if err != nil || verified[leftKey] == nil || verified[rightKey] == nil {
		t.Fatalf("merged keys = %v, %v", verified, err)
	}
	item := Item{Name: "Rotated", Password: "value", CreatedAt: "a", UpdatedAt: "a"}
	for _, keyID := range []string{leftKey, rightKey} {
		envelope, err := SealItem(verified, keyID, record.ID, "vi_"+keyID, item)
		if err != nil {
			t.Fatal(err)
		}
		if opened, err := OpenItem(verified, record.ID, "vi_"+keyID, envelope); err != nil || opened.Name != item.Name {
			t.Fatalf("item under %s = %+v, %v", keyID, opened, err)
		}
	}
}

func TestVerifyRejectsMalformedKeyrings(t *testing.T) {
	t.Parallel()
	record, ring, keys := memberKeyring(t)
	rotated, next, err := ring.Rotate(keys, record.Root)
	if err != nil {
		t.Fatal(err)
	}
	cases := map[string]func(Keyring) Keyring{
		"another vault": func(k Keyring) Keyring { k.VaultID = "vlt_other"; return k },
		"duplicate key": func(k Keyring) Keyring {
			k.Keys = append(append([]KeyEntry(nil), k.Keys...), k.Keys[0])
			return k
		},
		"empty key id": func(k Keyring) Keyring {
			k.Keys = append(append([]KeyEntry(nil), k.Keys...), KeyEntry{Key: k.Keys[0].Key})
			return k
		},
		"short key": func(k Keyring) Keyring {
			k.Keys = append([]KeyEntry(nil), k.Keys...)
			k.Keys[0].Key = b64.EncodeToString(make([]byte, keyBytes-1))
			return k
		},
		"missing parent": func(k Keyring) Keyring {
			k.Keys = append([]KeyEntry(nil), k.Keys...)
			k.Keys[1].Parent = "k_missing"
			return k
		},
		"parent cycle": func(k Keyring) Keyring {
			k.Keys = append([]KeyEntry(nil), k.Keys...)
			k.Keys[0].Parent, k.Keys[0].Auth = next, k.Keys[1].Auth
			return k
		},
		"reauthenticated by another vault": func(k Keyring) Keyring {
			k.Keys = append([]KeyEntry(nil), k.Keys...)
			key, _ := b64.DecodeString(k.Keys[1].Key)
			k.Keys[1].Auth = b64.EncodeToString(keyAuth(keys[record.Root], "vlt_other", next, key))
			return k
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if _, err := mutate(rotated).Verify(record.ID, record.RootHash); !errors.Is(err, ErrTampered) {
				t.Fatalf("malformed keyring accepted: %v", err)
			}
		})
	}
	if _, err := rotated.Verify("", ""); !errors.Is(err, ErrTampered) {
		t.Fatalf("keyring verified without a pinned vault: %v", err)
	}
}

func TestSealedKeyringIsBoundToItsVault(t *testing.T) {
	t.Parallel()
	record, ring, _ := memberKeyring(t)
	seed := NewMemberSeed()
	public, err := PublicKey(seed)
	if err != nil {
		t.Fatal(err)
	}
	sealed, err := Seal(public, ring, "vm_a")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Open(seed, sealed, "vlt_other", "vm_a"); !errors.Is(err, ErrTampered) {
		t.Fatalf("keyring opened for another vault: %v", err)
	}
	raw, _ := b64.DecodeString(sealed)
	raw[len(raw)-1] ^= 1
	if _, err := Open(seed, b64.EncodeToString(raw), record.ID, "vm_a"); !errors.Is(err, ErrTampered) {
		t.Fatalf("modified keyring opened: %v", err)
	}
	if _, err := Open(seed, "not base64!", record.ID, "vm_a"); !errors.Is(err, ErrTampered) {
		t.Fatalf("undecodable keyring opened: %v", err)
	}
	if _, err := Seal([]byte("short"), ring, "vm_a"); err == nil {
		t.Fatal("sealed to an invalid public key")
	}
}

func TestItemEnvelopeRejectsTamperingAndKeySubstitution(t *testing.T) {
	t.Parallel()
	record, ring, keys := memberKeyring(t)
	rotated, next, err := ring.Rotate(keys, record.Root)
	if err != nil {
		t.Fatal(err)
	}
	keys, err = rotated.Verify(record.ID, record.RootHash)
	if err != nil {
		t.Fatal(err)
	}
	item := Item{Name: "Bank", Password: "value", CreatedAt: "a", UpdatedAt: "a"}
	envelope, err := SealItem(keys, record.Root, record.ID, "vi_one", item)
	if err != nil {
		t.Fatal(err)
	}
	again, err := SealItem(keys, record.Root, record.ID, "vi_one", item)
	if err != nil || again.Nonce == envelope.Nonce || again.Data == envelope.Data {
		t.Fatalf("envelopes reuse a nonce: %v", err)
	}
	data, _ := b64.DecodeString(envelope.Data)
	data[0] ^= 1
	flipped := envelope
	flipped.Data = b64.EncodeToString(data)
	substituted := envelope
	substituted.Key = next
	shortNonce := envelope
	shortNonce.Nonce = b64.EncodeToString([]byte("short"))
	for name, test := range map[string]struct {
		vaultID  string
		envelope Envelope
	}{
		"flipped ciphertext": {record.ID, flipped},
		"substituted key":    {record.ID, substituted},
		"short nonce":        {record.ID, shortNonce},
		"another vault":      {"vlt_other", envelope},
	} {
		if _, err := OpenItem(keys, test.vaultID, "vi_one", test.envelope); !errors.Is(err, ErrTampered) {
			t.Errorf("%s: %v", name, err)
		}
	}
	unknown := envelope
	unknown.Key = "k_unknown"
	if _, err := OpenItem(keys, record.ID, "vi_one", unknown); !errors.Is(err, ErrLocked) {
		t.Fatalf("unknown key: %v", err)
	}
	if _, err := SealItem(keys, "k_unknown", record.ID, "vi_one", item); !errors.Is(err, ErrLocked) {
		t.Fatalf("sealed under an unknown key: %v", err)
	}
	if _, err := SealItem(keys, record.Root, record.ID, "vi_one", Item{}); err == nil {
		t.Fatal("sealed an invalid item")
	}
}

func TestRandomIDIsLowercaseCrockford(t *testing.T) {
	t.Parallel()
	if id := RandomID("vi_"); !strings.HasPrefix(id, "vi_") || len(id) != len("vi_")+26 || id != strings.ToLower(id) {
		t.Fatalf("random ID = %q", id)
	}
}

func TestParseRecoveryKeyRejectsMalformedInput(t *testing.T) {
	t.Parallel()
	_, printed := NewRecoveryKey()
	for name, value := range map[string]string{
		"empty":          "",
		"missing prefix": strings.TrimPrefix(printed, recoveryPrefix),
		"other prefix":   "DVR2" + strings.TrimPrefix(printed, recoveryPrefix),
		"truncated":      printed[:len(printed)-3],
		"extended":       printed + "AAAA",
		"invalid letter": printed[:len(printed)-1] + "U",
	} {
		if _, err := ParseRecoveryKey(value); err == nil {
			t.Errorf("%s accepted: %q", name, value)
		}
	}
	seed, err := ParseRecoveryKey("  " + printed + "\n")
	if err != nil || FormatRecoveryKey(seed) != printed {
		t.Fatalf("surrounding whitespace rejected: %v", err)
	}
}
