package vault

import (
	"encoding/base32"
	"errors"
	"strings"
	"testing"
	"time"
)

func memberKeyring(t *testing.T) (Record, Keyring, map[string][]byte) {
	t.Helper()
	record, ring := New("2026-10-10T00:00:00Z")
	keys, err := ring.Verify(record.ID, record.RootHash)
	if err != nil {
		t.Fatal(err)
	}
	return record, ring, keys
}

func TestKeyringSealOpenAndRotationChain(t *testing.T) {
	record, ring, keys := memberKeyring(t)
	rotated, next, err := ring.Rotate(keys, record.Root)
	if err != nil {
		t.Fatal(err)
	}
	seed := NewMemberSeed()
	public, err := PublicKey(seed)
	if err != nil {
		t.Fatal(err)
	}
	sealed, err := Seal(public, rotated, "vm_a")
	if err != nil {
		t.Fatal(err)
	}
	opened, err := Open(seed, sealed, record.ID, "vm_a")
	if err != nil {
		t.Fatal(err)
	}
	verified, err := opened.Verify(record.ID, record.RootHash)
	if err != nil || len(verified) != 2 || verified[next] == nil {
		t.Fatalf("keys = %v, %v", verified, err)
	}
	if _, err := Open(seed, sealed, record.ID, "vm_b"); !errors.Is(err, ErrTampered) {
		t.Fatalf("keyring replayed to another member: %v", err)
	}
	if _, err := Open(NewMemberSeed(), sealed, record.ID, "vm_a"); !errors.Is(err, ErrTampered) {
		t.Fatalf("foreign seed opened keyring: %v", err)
	}
}

func TestKeyringRejectsSubstitutedRootAndForgedKeys(t *testing.T) {
	record, _, _ := memberKeyring(t)
	otherRecord, otherRing := New("2026-10-10T00:00:00Z")
	otherRing.VaultID = record.ID
	if _, err := otherRing.Verify(record.ID, record.RootHash); !errors.Is(err, ErrTampered) {
		t.Fatalf("substituted root accepted: %v", err)
	}
	_, ring, keys := memberKeyring(t)
	_ = otherRecord
	forged := ring
	forged.Keys = append(forged.Keys, KeyEntry{ID: "k_forged", Key: b64.EncodeToString(make([]byte, 32)), Parent: ring.Keys[0].ID, Auth: b64.EncodeToString(make([]byte, 32))})
	if _, err := forged.Verify(ring.VaultID, rootHash(ring.VaultID, ring.Keys[0].ID, keys[ring.Keys[0].ID])); !errors.Is(err, ErrTampered) {
		t.Fatalf("forged key accepted: %v", err)
	}
}

func TestItemEnvelopeBindsVaultItemAndKey(t *testing.T) {
	record, _, keys := memberKeyring(t)
	item := Item{Name: "GitHub", URLs: []string{"https://github.com/login"}, Username: "octo", Password: "s3cret-value", CreatedAt: "a", UpdatedAt: "a"}
	envelope, err := SealItem(keys, record.Root, record.ID, "vi_one", item)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(envelope.Data, "s3cret") || strings.Contains(envelope.Data, "GitHub") {
		t.Fatal("envelope leaks plaintext")
	}
	opened, err := OpenItem(keys, record.ID, "vi_one", envelope)
	if err != nil || opened.Password != item.Password || opened.Name != "GitHub" {
		t.Fatalf("opened = %+v, %v", opened, err)
	}
	if _, err := OpenItem(keys, record.ID, "vi_two", envelope); !errors.Is(err, ErrTampered) {
		t.Fatalf("envelope moved between items: %v", err)
	}
}

func TestRecoveryKeyRoundTripAndAuthentication(t *testing.T) {
	record, ring, keys := memberKeyring(t)
	seed, printed := NewRecoveryKey()
	parsed, err := ParseRecoveryKey(strings.ToLower(strings.ReplaceAll(printed, "-", " ")))
	if err != nil || string(parsed) != string(seed) {
		t.Fatalf("parse = %v", err)
	}
	broken := []byte(printed)
	if broken[10] == 'A' {
		broken[10] = 'B'
	} else {
		broken[10] = 'A'
	}
	if _, err := ParseRecoveryKey(string(broken)); err == nil {
		t.Fatal("typo accepted")
	}
	rootID, rootKey, _ := ring.RootKey(keys)
	ring.RecoveryCheck, err = RecoveryCheck(seed, record.ID, rootID, rootKey)
	if err != nil {
		t.Fatal(err)
	}
	pinned, err := RecoveredRoot(seed, ring)
	if err != nil || pinned != record.RootHash {
		t.Fatalf("recovered root = %q, %v", pinned, err)
	}
	other, _ := NewRecoveryKey()
	if _, err := RecoveredRoot(other, ring); !errors.Is(err, ErrWrongRecovery) {
		t.Fatalf("wrong recovery key authenticated root: %v", err)
	}
}

func TestJoinCodeDetectsSubstitution(t *testing.T) {
	seed := NewMemberSeed()
	public, _ := PublicKey(seed)
	code := JoinCode("vlt_a", "root", "vm_a", public)
	if !SameCode(code, strings.ToLower(strings.ReplaceAll(code, "-", " "))) {
		t.Fatal("formatting changed code")
	}
	other, _ := PublicKey(NewMemberSeed())
	if SameCode(code, JoinCode("vlt_a", "root", "vm_a", other)) || SameCode(code, JoinCode("vlt_a", "other", "vm_a", public)) {
		t.Fatal("substitution kept code")
	}
}

// RFC 6238 appendix B vectors (8 digits).
func TestTOTPRFC6238Vectors(t *testing.T) {
	secrets := map[string]string{
		"SHA1":   base32.StdEncoding.EncodeToString([]byte("12345678901234567890")),
		"SHA256": base32.StdEncoding.EncodeToString([]byte("12345678901234567890123456789012")),
		"SHA512": base32.StdEncoding.EncodeToString([]byte("1234567890123456789012345678901234567890123456789012345678901234")),
	}
	cases := []struct {
		at                   int64
		sha1, sha256, sha512 string
	}{
		{59, "94287082", "46119246", "90693936"},
		{1111111109, "07081804", "68084774", "25091201"},
		{2000000000, "69279037", "90698825", "38618901"},
	}
	for _, test := range cases {
		for algorithm, want := range map[string]string{"SHA1": test.sha1, "SHA256": test.sha256, "SHA512": test.sha512} {
			config, err := ParseTOTP("otpauth://totp/Example:alice?secret=" + secrets[algorithm] + "&algorithm=" + algorithm + "&digits=8&period=30")
			if err != nil {
				t.Fatal(err)
			}
			if got, _ := config.Code(time.Unix(test.at, 0)); got != want {
				t.Fatalf("%s at %d = %s, want %s", algorithm, test.at, got, want)
			}
		}
	}
	bare, err := ParseTOTP("gezd gnbv gy3t qojq gezd gnbv gy3t qojq")
	if err != nil || bare.Digits != 6 || bare.Period != 30 {
		t.Fatalf("bare secret = %+v, %v", bare, err)
	}
	roundTrip, err := ParseTOTP(bare.URI())
	if err != nil || string(roundTrip.Secret) != string(bare.Secret) {
		t.Fatalf("URI round trip = %v", err)
	}
	if _, remaining := bare.Code(time.Unix(59, 0)); remaining != time.Second {
		t.Fatalf("remaining = %v", remaining)
	}
}

func TestGeneratedPasswordsMeetPolicy(t *testing.T) {
	for range 50 {
		value, err := GeneratePassword(12, true)
		if err != nil || len(value) != 12 || !strings.ContainsAny(value, passwordSymbols) || !strings.ContainsAny(value, passwordDigits) {
			t.Fatalf("password %q, %v", value, err)
		}
	}
	if _, err := GeneratePassword(4, true); err == nil {
		t.Fatal("short password accepted")
	}
}

func TestItemValidation(t *testing.T) {
	for _, item := range []Item{{Name: ""}, {Name: " padded"}, {Name: "vi_lookalike"}, {Name: "ok", URLs: []string{"example.com"}}, {Name: "ok", TOTP: "not base32!"}} {
		if item.Validate() == nil {
			t.Fatalf("accepted %+v", item)
		}
	}
	if err := (Item{Name: "ok", URLs: []string{"https://example.com"}}).Validate(); err != nil {
		t.Fatal(err)
	}
}
