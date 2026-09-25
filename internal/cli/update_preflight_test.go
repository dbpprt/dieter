package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestUpdatePreflightIsReadOnly(t *testing.T) {
	for _, schema := range []string{`{"version":2}`, `{"version":1}`, `not json`, ``} {
		t.Run(schema, func(t *testing.T) {
			root := t.TempDir()
			if schema != "" {
				if err := os.WriteFile(filepath.Join(root, "storage-schema.json"), []byte(schema), 0400); err != nil {
					t.Fatal(err)
				}
			}
			sentinel := filepath.Join(root, "conversation.txt")
			if err := os.WriteFile(sentinel, []byte("keep my chat"), 0400); err != nil {
				t.Fatal(err)
			}
			before, _ := os.ReadDir(root)
			var out bytes.Buffer
			err := updatePreflight([]string{"--root", root}, &out)
			if (err == nil) != (schema == `{"version":2}`) {
				t.Fatalf("unexpected result: %v", err)
			}
			if err == nil {
				var result map[string]any
				if json.Unmarshal(out.Bytes(), &result) != nil || result["protocol"] != float64(1) {
					t.Fatal(out.String())
				}
			}
			after, _ := os.ReadDir(root)
			contents, _ := os.ReadFile(sentinel)
			if len(before) != len(after) || string(contents) != "keep my chat" {
				t.Fatal("probe changed store")
			}
			if schema != "" {
				raw, _ := os.ReadFile(filepath.Join(root, "storage-schema.json"))
				if string(raw) != schema {
					t.Fatal("schema changed")
				}
			}
		})
	}
}
