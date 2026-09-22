package store

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/dbpprt/dieter/internal/trust"
)

// RelocateDaemonGateway commits a verified endpoint change under the central
// writer lock. Keys, enrollment generation, certificates, peer identity and its
// database remain byte-for-byte unchanged. Call only after pinned-key discovery.
func (s *Store) RelocateDaemonGateway(id, previous, issuer, endpoint string, signingKey []byte) error {
	for _, origin := range []string{previous, issuer, endpoint} {
		value, err := trust.GatewayOrigin(origin)
		if err != nil || value != origin {
			return errors.New("invalid gateway origin")
		}
	}
	release, err := s.beginWriteLock()
	if err != nil {
		return err
	}
	defer release()
	path := filepath.Join(s.Root, "daemon", "identity.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var identity map[string]json.RawMessage
	if err = json.Unmarshal(raw, &identity); err != nil {
		return err
	}
	var current struct {
		ID     string `json:"id"`
		URL    string `json:"gatewayUrl"`
		Issuer string `json:"gatewayIssuer"`
		Key    []byte `json:"gatewaySigningPublicKey"`
	}
	if err = json.Unmarshal(raw, &current); err != nil {
		return err
	}
	if current.Issuer == "" {
		current.Issuer = current.URL
	}
	if current.ID != id || current.URL != previous || current.Issuer != issuer || !bytes.Equal(current.Key, signingKey) {
		return errors.New("daemon enrollment changed during gateway relocation")
	}
	identity["gatewayUrl"], _ = json.Marshal(endpoint)
	identity["gatewayIssuer"], _ = json.Marshal(issuer)
	raw, err = json.MarshalIndent(identity, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(path, append(raw, '\n'))
}
