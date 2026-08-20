package model

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestUIMessageMigratesLegacyCreatedAtIntoMetadata(t *testing.T) {
	var message UIMessage
	if err := json.Unmarshal([]byte(`{"id":"m1","role":"user","parts":[{"type":"text","text":"hello"}],"createdAt":"2026-08-11T12:00:00Z"}`), &message); err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(encoded, []byte(`"metadata":{"createdAt":"2026-08-11T12:00:00Z"}`)) || bytes.Contains(encoded, []byte(`],"createdAt"`)) {
		t.Fatalf("legacy timestamp was not migrated to AI SDK metadata: %s", encoded)
	}
}
