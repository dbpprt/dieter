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

func TestCanonicalWorkspaceModeHasOnlyProjectAndWorktreeSemantics(t *testing.T) {
	for input, want := range map[string]string{
		"project":  WorkspaceModeProject,
		"PROJECT":  WorkspaceModeProject,
		"main":     WorkspaceModeProject,
		"branch":   WorkspaceModeProject,
		"worktree": WorkspaceModeWorktree,
	} {
		got, ok := CanonicalWorkspaceMode(input)
		if !ok || got != want {
			t.Fatalf("CanonicalWorkspaceMode(%q) = %q, %v; want %q, true", input, got, ok, want)
		}
	}
	if _, ok := CanonicalWorkspaceMode("shared"); ok {
		t.Fatal("unsupported workspace mode was accepted")
	}
}
