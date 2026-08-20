package server

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDirectoryBrowserListsFoldersAndRepositories(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	repo := filepath.Join(home, "Development", "repo")
	regular := filepath.Join(home, "Development", "notes")
	hidden := filepath.Join(home, "Development", ".hidden")
	for _, path := range []string{filepath.Join(repo, ".git"), regular, hidden} {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(home, "Development", "README.md"), []byte("not a directory"), 0o644); err != nil {
		t.Fatal(err)
	}

	listing, err := listProjectDirectories(filepath.Join(home, "Development"))
	if err != nil {
		t.Fatal(err)
	}
	if listing.Path != filepath.Join(home, "Development") || listing.Parent != home || listing.GitRepository || len(listing.Entries) != 3 {
		t.Fatalf("unexpected listing: %#v", listing)
	}
	if listing.Entries[0].Name != ".hidden" || !listing.Entries[0].Hidden || listing.Entries[1].Name != "notes" || listing.Entries[2].Name != "repo" || !listing.Entries[2].GitRepository {
		t.Fatalf("unexpected entries: %#v", listing.Entries)
	}
	if len(listing.Locations) < 2 || listing.Locations[0].Path != home || listing.Locations[1].Name != "Development" {
		t.Fatalf("unexpected locations: %#v", listing.Locations)
	}
}

func TestDirectoryBrowserRejectsMissingDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if _, err := listProjectDirectories(filepath.Join(home, "missing")); err == nil {
		t.Fatal("expected missing directory error")
	}
}
