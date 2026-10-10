package peerstore

import "testing"

func vaultRecord(kind, id, value string, deleted bool) Record {
	version := Version{Clock: Clock{"actor_a": 1}, Deleted: deleted}
	if !deleted {
		version.Value = []byte(value)
	}
	return Record{Kind: kind, ID: id, Versions: []Version{version}}
}

func TestVaultRecordsAcceptOnlyCiphertextShapes(t *testing.T) {
	valid := []Record{
		vaultRecord("vault", "vault", `{"id":"vlt_a","root":"k_a","rootHash":"AAAA","current":"k_a","createdAt":"2026-10-10T00:00:00Z"}`, false),
		vaultRecord("vault-member", "vm_a", `{"publicKey":"AAAA","keyring":"AAAA","name":"mbp","daemonId":"d_a"}`, false),
		vaultRecord("vault-member", "recovery", `{"publicKey":"AAAA","recovery":true}`, false),
		vaultRecord("vault-item", "vi_a", `{"key":"k_a","nonce":"AAAA","data":"AAAA"}`, false),
		vaultRecord("vault-item", "vi_a", "", true),
	}
	for _, record := range valid {
		if err := ValidateSettings(record); err != nil {
			t.Fatalf("%s/%s rejected: %v", record.Kind, record.ID, err)
		}
	}
	invalid := []Record{
		vaultRecord("vault", "other", `{"id":"vlt_a","root":"k_a","rootHash":"AAAA","current":"k_a"}`, false),
		vaultRecord("vault", "vault", "", true),
		vaultRecord("vault-item", "vi_a", `{"key":"k_a","nonce":"AAAA","data":"AAAA","password":"hunter2"}`, false),
		vaultRecord("vault-item", "vi_a", `{"key":"k_a","nonce":"AAAA","data":"not base64!"}`, false),
		vaultRecord("vault-item", "item", `{"key":"k_a","nonce":"AAAA","data":"AAAA"}`, false),
		vaultRecord("vault-member", "vm_a", `{"keyring":"AAAA"}`, false),
	}
	for _, record := range invalid {
		if err := ValidateSettings(record); err == nil {
			t.Fatalf("%s/%s accepted %s", record.Kind, record.ID, record.Versions[0].Value)
		}
	}
}
