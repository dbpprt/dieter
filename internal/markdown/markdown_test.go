package markdown

import (
	"strings"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	type metadata struct {
		ID     string   `yaml:"id"`
		Labels []string `yaml:"labels"`
	}
	want := metadata{ID: "c_123", Labels: []string{"api", "urgent"}}
	data, err := Marshal(want, "# Outcome\n\nKeep this readable.")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(data), "---\nid: c_123") {
		t.Fatalf("unexpected Markdown:\n%s", data)
	}
	var got metadata
	body, err := Unmarshal(data, &got)
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != want.ID || len(got.Labels) != 2 {
		t.Fatalf("metadata mismatch: %#v", got)
	}
	if body != "# Outcome\n\nKeep this readable." {
		t.Fatalf("body mismatch: %q", body)
	}
}

func TestRejectsPlainMarkdown(t *testing.T) {
	var metadata map[string]any
	if _, err := Unmarshal([]byte("# no frontmatter"), &metadata); err == nil {
		t.Fatal("expected error")
	}
}
