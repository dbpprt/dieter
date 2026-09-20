package peerstore

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"testing"
	"time"
)

func TestOwnerProvenanceBindsAccountRecordValueAndCausalClock(t *testing.T) {
	pub, key, _ := ed25519.GenerateKey(rand.Reader)
	now := time.Now()
	ca := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "test root"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	caDER, err := x509.CreateCertificate(rand.Reader, ca, ca, pub, key)
	if err != nil {
		t.Fatal(err)
	}
	ca, _ = x509.ParseCertificate(caDER)
	leaf := &x509.Certificate{SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "machine_a"}, NotBefore: now.Add(-time.Minute), NotAfter: now.Add(time.Minute), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}
	der, err := x509.CreateCertificate(rand.Reader, leaf, ca, pub, key)
	if err != nil {
		t.Fatal(err)
	}
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	record := Record{Kind: "item", ID: "card.identity"}
	version := Version{Clock: Clock{"actor_a": 1}, Value: []byte(`{"ownerDaemonId":"machine_a"}`)}
	signed := SignOwnerVersion("account", record, version, "machine_a", pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), key)
	if owner, err := VerifyOwnerVersion("account", record, signed, roots); err != nil || owner != "machine_a" {
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
		if _, err := VerifyOwnerVersion("account", r, v, roots); err == nil {
			t.Fatal("forged owner record accepted")
		}
	}
	if _, err := VerifyOwnerVersion("another-account", record, signed, roots); err == nil {
		t.Fatal("cross-account proof accepted")
	}
	if _, err := VerifyOwnerVersion("account", record, signed, x509.NewCertPool()); err == nil {
		t.Fatal("untrusted certificate accepted")
	}
}

func TestEqualEditProofMergeIsCommutative(t *testing.T) {
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
