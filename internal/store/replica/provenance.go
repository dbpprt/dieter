package replica

import (
	"bytes"
	"crypto/ed25519"
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"os"
	"path/filepath"
	"sync"

	gatewayv1 "github.com/dbpprt/dieter/internal/gen/dieter/gateway/v1"
	"github.com/dbpprt/dieter/internal/platform/fault"
	"github.com/dbpprt/dieter/internal/replication/crdt"
	"github.com/dbpprt/dieter/internal/replication/schema"
	"github.com/dbpprt/dieter/internal/security/roster"
	"google.golang.org/protobuf/proto"
)

type peerCredential struct {
	ID string `json:"id"`
}

// ownerKeyCache holds the daemon keys of the pinned device roster
// (daemon/roster.pb, written only by internal/link), keyed by its content.
type ownerKeyCache struct {
	mu     sync.Mutex
	digest [sha256.Size]byte
	keys   map[string][]ed25519.PublicKey
}

// ownerKeys returns, per daemon ID, every key the verified roster ever bound
// to it, revoked ones included, so historical owner edits stay valid.
func (s *Store) ownerKeys() (func(string) []ed25519.PublicKey, error) {
	raw, err := os.ReadFile(filepath.Join(s.home.Root, "daemon", "roster.pb"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, fault.New(fault.FailedPrecondition, "this machine has no trusted device roster yet")
	}
	if err != nil {
		return nil, err
	}
	digest := sha256.Sum256(raw)
	cache := &s.ownerKeyCache
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if cache.keys == nil || cache.digest != digest {
		var value gatewayv1.DeviceRoster
		if err := proto.Unmarshal(raw, &value); err != nil {
			return nil, err
		}
		state, err := roster.Verify(value.GetEntries())
		if err != nil {
			return nil, fault.Wrap(fault.FailedPrecondition, err)
		}
		keys := map[string][]ed25519.PublicKey{}
		for _, member := range state.Members() {
			if member.Descriptor.GetKind() != gatewayv1.DeviceKind_DEVICE_KIND_DAEMON {
				continue
			}
			if key, ok := member.PublicKey().(ed25519.PublicKey); ok {
				keys[member.Descriptor.GetDaemonId()] = append(keys[member.Descriptor.GetDaemonId()], key)
			}
		}
		cache.digest, cache.keys = digest, keys
	}
	keys := cache.keys
	return func(owner string) []ed25519.PublicKey { return keys[owner] }, nil
}

func (s *Store) peerCredential() (peerCredential, error) {
	var credential peerCredential
	raw, err := os.ReadFile(filepath.Join(s.home.Root, "daemon", "identity.json"))
	if errors.Is(err, os.ErrNotExist) {
		return credential, nil
	}
	if err != nil {
		return credential, err
	}
	err = json.Unmarshal(raw, &credential)
	return credential, err
}
func recordOwner(data PeerData, r crdt.Record, v crdt.Version) string {
	raw := v.Value
	field := "ownerDaemonId"
	if r.Kind == "checkout" {
		field = "daemonId"
	}
	entity, suffix := crdt.SplitField(r.ID)
	if r.Kind == "item" && suffix == "summary" {
		raw, _ = crdt.Selected(data.Record(crdt.Key("item", entity+".identity")))
	}
	var fields map[string]json.RawMessage
	_ = json.Unmarshal(raw, &fields)
	var owner string
	_ = json.Unmarshal(fields[field], &owner)
	return owner
}
func (s *Store) signOwnerRecord(account string, data PeerData, r crdt.Record) (crdt.Record, error) {
	if !schema.OwnerField(r.Kind, r.ID) {
		return r, nil
	}
	credential, err := s.peerCredential()
	if err != nil || credential.ID == "" {
		return r, err
	}
	var private ed25519.PrivateKey
	versions := append([]crdt.Version(nil), r.Versions...)
	for i, v := range versions {
		if len(v.Provenance) > 0 || recordOwner(data, r, v) != credential.ID {
			continue
		}
		if private == nil {
			raw, e := os.ReadFile(filepath.Join(s.home.Root, "daemon", "identity-key.pem"))
			if e != nil {
				return r, e
			}
			block, _ := pem.Decode(raw)
			if block == nil {
				return r, fault.New(fault.Invalid, "invalid daemon signing key")
			}
			key, e := x509.ParsePKCS8PrivateKey(block.Bytes)
			if e != nil {
				return r, e
			}
			var ok bool
			private, ok = key.(ed25519.PrivateKey)
			if !ok {
				return r, fault.New(fault.Invalid, "invalid daemon signing key type")
			}
		}
		versions[i] = crdt.SignOwnerVersion(account, r, v, credential.ID, private)
	}
	r.Versions = versions
	return r, nil
}
func (s *Store) validatePeerDomainMerge(data PeerData, old, incoming crdt.Record) error {
	if !schema.DomainKind(incoming.Kind) {
		return nil
	}
	_, field := crdt.SplitField(incoming.ID)
	// An enrolled owner's immutable routing identity can never be replaced by a
	// causally newer claim, including when forwarded through a third machine.
	for _, a := range old.Versions {
		for _, b := range incoming.Versions {
			if field == "identity" && !bytes.Equal(a.Value, b.Value) {
				return fault.New(fault.Invalid, "shared identity is immutable")
			}
			if incoming.Kind == "checkout" || incoming.Kind == "schedule" {
				var x, y map[string]json.RawMessage
				_ = json.Unmarshal(a.Value, &x)
				_ = json.Unmarshal(b.Value, &y)
				for _, key := range []string{"id", "projectId", "daemonId", "ownerDaemonId", "checkoutId"} {
					if !bytes.Equal(x[key], y[key]) {
						return fault.New(fault.Invalid, "shared owner identity is immutable")
					}
				}
			}
		}
	}
	if !schema.OwnerField(incoming.Kind, incoming.ID) {
		return nil
	}
	credential, err := s.peerCredential()
	if err != nil || credential.ID == "" {
		return err
	}
	roots, err := s.ownerKeys()
	if err != nil {
		return err
	}
	identity, err := s.PeerIdentity()
	if err != nil {
		return err
	}
	entity, field := crdt.SplitField(incoming.ID)
	for _, v := range incoming.Versions {
		owner, e := crdt.VerifyOwnerVersion(identity.Account, incoming, v, roots)
		if e != nil {
			return e
		}
		if expected := recordOwner(data, incoming, v); expected != "" && expected != owner {
			return fault.New(fault.Invalid, "owner provenance does not match directory identity")
		}
		if incoming.Kind == "item" && field == "identity" {
			for _, summary := range data.Record(crdt.Key("item", entity+".summary")).Versions {
				proofOwner, err := crdt.VerifyOwnerVersion(identity.Account, data.Record(crdt.Key("item", entity+".summary")), summary, roots)
				if err != nil || proofOwner != owner {
					return fault.New(fault.Invalid, "pending summary does not belong to item owner")
				}
			}
		}
	}
	return nil
}
