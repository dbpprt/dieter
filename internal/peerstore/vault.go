package peerstore

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// Vault records carry only ciphertext and key-distribution metadata. The strict
// field allowlist keeps a replica from replicating a decrypted value by adding
// a field; item contents exist only inside the authenticated envelope.
var vaultFields = map[string]map[string]string{
	"vault":        {"id": "id", "root": "id", "rootHash": "b64", "current": "id", "createdAt": "text"},
	"vault-member": {"publicKey": "b64", "keyring": "b64", "name": "text", "daemonId": "text", "recovery": "bool", "requestedAt": "text", "approvedAt": "text", "approvedBy": "text"},
	"vault-item":   {"key": "id", "nonce": "b64", "data": "b64"},
}

func VaultKind(kind string) bool { _, ok := vaultFields[kind]; return ok }

func ValidateVault(r Record) error {
	fields, ok := vaultFields[r.Kind]
	if !ok {
		return errors.New("unknown vault record kind")
	}
	if !ValidID(r.ID) || r.Kind == "vault" && r.ID != "vault" || r.Kind == "vault-item" && !strings.HasPrefix(r.ID, "vi_") {
		return errors.New("invalid vault record ID")
	}
	for _, version := range r.Versions {
		if version.Deleted {
			if r.Kind == "vault" {
				return errors.New("the vault record cannot be deleted")
			}
			continue
		}
		var value map[string]json.RawMessage
		if err := json.Unmarshal(version.Value, &value); err != nil || len(value) == 0 {
			return errors.New("vault record must be a JSON object")
		}
		for name, raw := range value {
			shape, ok := fields[name]
			if !ok {
				return errors.New("unknown vault field: " + name)
			}
			if bytes.Equal(raw, []byte("null")) {
				return errors.New("null vault field: " + name)
			}
			if shape == "bool" {
				var v bool
				if json.Unmarshal(raw, &v) != nil {
					return fmt.Errorf("%s must be boolean", name)
				}
				continue
			}
			var v string
			if json.Unmarshal(raw, &v) != nil {
				return fmt.Errorf("%s must be a string", name)
			}
			switch shape {
			case "id":
				if !ValidID(v) {
					return fmt.Errorf("invalid %s", name)
				}
			case "b64":
				if _, err := base64.RawStdEncoding.DecodeString(v); err != nil {
					return fmt.Errorf("%s must be unpadded base64", name)
				}
			case "text":
				if len(v) > 512 || strings.ContainsAny(v, "\r\n") {
					return fmt.Errorf("invalid %s", name)
				}
			}
		}
		required := map[string][]string{"vault": {"id", "root", "rootHash", "current"}, "vault-member": {"publicKey"}, "vault-item": {"key", "nonce", "data"}}
		for _, name := range required[r.Kind] {
			if _, ok := value[name]; !ok {
				return errors.New("missing vault field: " + name)
			}
		}
	}
	return nil
}
