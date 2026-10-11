package crdt

import (
	"crypto/ed25519"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"time"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// OwnerProof travels with a causal version, including through third-party peers.
// The certificate binds its key to the enrolled daemon; the signed envelope binds
// the account, field, causal clock and exact value. It never authorizes a turn.
type OwnerProof struct {
	Owner       string `json:"owner"`
	Certificate []byte `json:"certificate"`
	Signature   []byte `json:"signature"`
}

func ownerEnvelope(account string, r Record, v Version, owner string) []byte {
	raw, _ := json.Marshal(struct {
		Domain, Account, Kind, ID, Owner string
		Clock                            Clock
		Value                            json.RawMessage
		Deleted                          bool
	}{"dieter-shared-owner-v1", account, r.Kind, r.ID, owner, v.Clock, v.Value, v.Deleted})
	return raw
}
func SignOwnerVersion(account string, r Record, v Version, owner string, certificate []byte, private ed25519.PrivateKey) Version {
	proof := OwnerProof{Owner: owner, Certificate: certificate, Signature: ed25519.Sign(private, ownerEnvelope(account, r, v, owner))}
	v.Provenance, _ = json.Marshal(proof)
	return v
}
func VerifyOwnerVersion(account string, r Record, v Version, roots *x509.CertPool) (string, error) {
	var proof OwnerProof
	if len(v.Provenance) > 4096 || json.Unmarshal(v.Provenance, &proof) != nil || !ValidID(proof.Owner) {
		return "", fault.New(fault.Invalid, "missing or invalid owner provenance")
	}
	block, _ := pem.Decode(proof.Certificate)
	if block == nil {
		return "", fault.New(fault.Invalid, "invalid owner certificate")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return "", err
	}
	// Historical edits remain valid after certificate expiry. Current enrollment
	// and revocation are enforced on the authenticated sync connection separately.
	if _, err = cert.Verify(x509.VerifyOptions{Roots: roots, CurrentTime: cert.NotBefore.Add(time.Second), KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth}}); err != nil {
		return "", err
	}
	key, ok := cert.PublicKey.(ed25519.PublicKey)
	if !ok || cert.Subject.CommonName != proof.Owner || !ed25519.Verify(key, ownerEnvelope(account, r, v, proof.Owner), proof.Signature) {
		return "", fault.New(fault.Invalid, "invalid owner signature")
	}
	return proof.Owner, nil
}
