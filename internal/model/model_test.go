package model

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestUIMessagePreservesMetadata(t *testing.T) {
	var message UIMessage
	if err := json.Unmarshal([]byte(`{"id":"m1","role":"user","parts":[{"type":"text","text":"hello"}],"metadata":{"createdAt":"2026-08-11T12:00:00Z"}}`), &message); err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(encoded, []byte(`"metadata":{"createdAt":"2026-08-11T12:00:00Z"}`)) || bytes.Contains(encoded, []byte(`],"createdAt"`)) {
		t.Fatalf("message metadata was not preserved: %s", encoded)
	}
}

func TestCanonicalWorkspaceModeHasOnlyProjectAndWorktreeSemantics(t *testing.T) {
	for input, want := range map[string]string{
		"project":  WorkspaceModeProject,
		"PROJECT":  WorkspaceModeProject,
		"worktree": WorkspaceModeWorktree,
	} {
		got, ok := CanonicalWorkspaceMode(input)
		if !ok || got != want {
			t.Fatalf("CanonicalWorkspaceMode(%q) = %q, %v; want %q, true", input, got, ok, want)
		}
	}
	for _, mode := range []string{"shared", "main", "branch"} {
		if _, ok := CanonicalWorkspaceMode(mode); ok {
			t.Fatalf("unsupported workspace mode %q was accepted", mode)
		}
	}
}
