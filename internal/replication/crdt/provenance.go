package crdt

import (
	"crypto/ed25519"
	"encoding/json"

	"github.com/dbpprt/dieter/internal/platform/fault"
)

// OwnerProof travels with a causal version, including through third-party peers.
// The signed envelope binds the account, field, causal clock and exact value to
// the owner daemon's key in the account's device roster. It never authorizes a
// turn.
type OwnerProof struct {
	Owner     string `json:"owner"`
	Signature []byte `json:"signature"`
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

func SignOwnerVersion(account string, r Record, v Version, owner string, private ed25519.PrivateKey) Version {
	proof := OwnerProof{Owner: owner, Signature: ed25519.Sign(private, ownerEnvelope(account, r, v, owner))}
	v.Provenance, _ = json.Marshal(proof)
	return v
}

// VerifyOwnerVersion checks the owner's signature with keys(owner): the
// roster keys of that daemon, including revoked ones, so historical edits stay
// valid. Current membership is enforced on the authenticated sync connection.
func VerifyOwnerVersion(account string, r Record, v Version, keys func(owner string) []ed25519.PublicKey) (string, error) {
	var proof OwnerProof
	if len(v.Provenance) > 4096 || json.Unmarshal(v.Provenance, &proof) != nil || !ValidID(proof.Owner) {
		return "", fault.New(fault.Invalid, "missing or invalid owner provenance")
	}
	envelope := ownerEnvelope(account, r, v, proof.Owner)
	for _, key := range keys(proof.Owner) {
		if len(key) == ed25519.PublicKeySize && ed25519.Verify(key, envelope, proof.Signature) {
			return proof.Owner, nil
		}
	}
	return "", fault.New(fault.Invalid, "invalid owner signature")
}
