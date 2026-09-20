package store

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestUnsupportedDevelopmentStoreIsNotConverted(t *testing.T) {
	root := t.TempDir()
	projects := filepath.Join(root, "projects")
	if err := os.Mkdir(projects, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(projects, "old.md")
	content := []byte("old development project\n")
	if err := os.WriteFile(path, content, 0600); err != nil {
		t.Fatal(err)
	}
	if err := New(root).Ensure(); !errors.Is(err, ErrUnsupportedStore) {
		t.Fatalf("error=%v", err)
	}
	got, err := os.ReadFile(path)
	if err != nil || string(got) != string(content) {
		t.Fatalf("existing data changed: %q %v", got, err)
	}
	if _, err := os.Stat(filepath.Join(root, "storage-schema.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("schema created for unsupported store: %v", err)
	}
}
