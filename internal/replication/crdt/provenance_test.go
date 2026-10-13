package crdt

import (
	"crypto/ed25519"
	"crypto/rand"
	"testing"
)

func TestOwnerProvenanceBindsAccountRecordValueAndCausalClock(t *testing.T) {
	t.Parallel()
	pub, key, _ := ed25519.GenerateKey(rand.Reader)
	other, _, _ := ed25519.GenerateKey(rand.Reader)
	keys := func(owner string) []ed25519.PublicKey {
		if owner == "machine_a" {
			return []ed25519.PublicKey{other, pub}
		}
		return nil
	}
	record := Record{Kind: "item", ID: "card.identity"}
	version := Version{Clock: Clock{"actor_a": 1}, Value: []byte(`{"ownerDaemonId":"machine_a"}`)}
	signed := SignOwnerVersion("account", record, version, "machine_a", key)
	if owner, err := VerifyOwnerVersion("account", record, signed, keys); err != nil || owner != "machine_a" {
		t.Fatal(owner, err)
	}
	for _, change := range []func(*Record, *Version){
		func(r *Record, v *Version) { r.ID = "other.identity" },
		func(r *Record, v *Version) { v.Value = []byte(`{"ownerDaemonId":"machine_b"}`) },
		func(r *Record, v *Version) { v.Clock = Clock{"actor_a": 2} },
		func(r *Record, v *Version) { v.Deleted = true },
	} {
		r, v := record, signed
		change(&r, &v)
		if _, err := VerifyOwnerVersion("account", r, v, keys); err == nil {
			t.Fatal("forged owner record accepted")
		}
	}
	if _, err := VerifyOwnerVersion("another-account", record, signed, keys); err == nil {
		t.Fatal("cross-account proof accepted")
	}
	if _, err := VerifyOwnerVersion("account", record, signed, func(string) []ed25519.PublicKey { return []ed25519.PublicKey{other} }); err == nil {
		t.Fatal("a key outside the roster verified")
	}
	forged := SignOwnerVersion("account", record, version, "machine_b", key)
	if _, err := VerifyOwnerVersion("account", record, forged, keys); err == nil {
		t.Fatal("a daemon signed for another owner")
	}
}

func TestEqualEditProofMergeIsCommutative(t *testing.T) {
	t.Parallel()
	a := Record{Kind: "item", ID: "item.identity", Versions: []Version{{Clock: Clock{"a": 1}, Value: []byte(`"value"`), Provenance: []byte(`{"proof":"a"}`)}}}
	b := a
	b.Versions = append([]Version(nil), a.Versions...)
	b.Versions[0].Provenance = []byte(`{"proof":"b"}`)
	ab, err := Merge(a, b)
	if err != nil {
		t.Fatal(err)
	}
	ba, err := Merge(b, a)
	if err != nil {
		t.Fatal(err)
	}
	if ab.Revision() != ba.Revision() {
		t.Fatal("proof choice depends on delivery order")
	}
}
