package store

import (
	"bytes"
	"crypto/ed25519"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"

	"github.com/dbpprt/dieter/internal/peerstore"
)

type peerCredential struct {
	ID          string `json:"id"`
	Certificate []byte `json:"certificatePem"`
	CA          []byte `json:"daemonCaPem"`
}

func (s *Store) peerCredential() (peerCredential, error) {
	var credential peerCredential
	raw, err := os.ReadFile(filepath.Join(s.Root, "daemon", "identity.json"))
	if errors.Is(err, os.ErrNotExist) {
		return credential, nil
	}
	if err != nil {
		return credential, err
	}
	err = json.Unmarshal(raw, &credential)
	return credential, err
}
func recordOwner(data PeerData, r peerstore.Record, v peerstore.Version) string {
	raw := v.Value
	field := "ownerDaemonId"
	if r.Kind == "checkout" {
		field = "daemonId"
	}
	entity, suffix := peerstore.SplitField(r.ID)
	if r.Kind == "item" && suffix == "summary" {
		raw, _ = peerstore.Selected(data.Records[peerstore.Key("item", entity+".identity")])
	}
	var fields map[string]json.RawMessage
	_ = json.Unmarshal(raw, &fields)
	var owner string
	_ = json.Unmarshal(fields[field], &owner)
	return owner
}
func (s *Store) signOwnerRecord(account string, data PeerData, r peerstore.Record) (peerstore.Record, error) {
	if !peerstore.OwnerField(r.Kind, r.ID) {
		return r, nil
	}
	credential, err := s.peerCredential()
	if err != nil || credential.ID == "" {
		return r, err
	}
	var private ed25519.PrivateKey
	versions := append([]peerstore.Version(nil), r.Versions...)
	for i, v := range versions {
		if len(v.Provenance) > 0 || recordOwner(data, r, v) != credential.ID {
			continue
		}
		if private == nil {
			raw, e := os.ReadFile(filepath.Join(s.Root, "daemon", "identity-key.pem"))
			if e != nil {
				return r, e
			}
			block, _ := pem.Decode(raw)
			if block == nil {
				return r, errors.New("invalid daemon signing key")
			}
			key, e := x509.ParsePKCS8PrivateKey(block.Bytes)
			if e != nil {
				return r, e
			}
			var ok bool
			private, ok = key.(ed25519.PrivateKey)
			if !ok {
				return r, errors.New("invalid daemon signing key type")
			}
		}
		versions[i] = peerstore.SignOwnerVersion(account, r, v, credential.ID, credential.Certificate, private)
	}
	r.Versions = versions
	return r, nil
}
func (s *Store) validatePeerDomainMerge(data PeerData, old, incoming peerstore.Record) error {
	if !peerstore.DomainKind(incoming.Kind) {
		return nil
	}
	_, field := peerstore.SplitField(incoming.ID)
	// An enrolled owner's immutable routing identity can never be replaced by a
	// causally newer claim, including when forwarded through a third machine.
	for _, a := range old.Versions {
		for _, b := range incoming.Versions {
			if field == "identity" && !bytes.Equal(a.Value, b.Value) {
				return errors.New("shared identity is immutable")
			}
			if incoming.Kind == "checkout" || incoming.Kind == "schedule" {
				var x, y map[string]json.RawMessage
				_ = json.Unmarshal(a.Value, &x)
				_ = json.Unmarshal(b.Value, &y)
				for _, key := range []string{"id", "projectId", "daemonId", "ownerDaemonId", "checkoutId"} {
					if !bytes.Equal(x[key], y[key]) {
						return errors.New("shared owner identity is immutable")
					}
				}
			}
		}
	}
	if !peerstore.OwnerField(incoming.Kind, incoming.ID) {
		return nil
	}
	credential, err := s.peerCredential()
	if err != nil || credential.ID == "" {
		return err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(credential.CA) {
		return errors.New("missing enrolled trust root")
	}
	identity, err := s.PeerIdentity()
	if err != nil {
		return err
	}
	entity, field := peerstore.SplitField(incoming.ID)
	for _, v := range incoming.Versions {
		owner, e := peerstore.VerifyOwnerVersion(identity.Account, incoming, v, roots)
		if e != nil {
			return e
		}
		if expected := recordOwner(data, incoming, v); expected != "" && expected != owner {
			return errors.New("owner provenance does not match directory identity")
		}
		if incoming.Kind == "item" && field == "identity" {
			for _, summary := range data.Records[peerstore.Key("item", entity+".summary")].Versions {
				proofOwner, err := peerstore.VerifyOwnerVersion(identity.Account, data.Records[peerstore.Key("item", entity+".summary")], summary, roots)
				if err != nil || proofOwner != owner {
					return errors.New("pending summary does not belong to item owner")
				}
			}
		}
	}
	return nil
}
