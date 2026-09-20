package gateway

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestDefaultRootUsesDieterGatewayHome(t *testing.T) {
	want := filepath.Join(t.TempDir(), "gateway-state")
	t.Setenv("DIETER_GATEWAY_HOME", want)
	if got := DefaultRoot(); got != want {
		t.Fatalf("DefaultRoot() = %q, want %q", got, want)
	}
}

func TestDefaultRootUsesHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("DIETER_GATEWAY_HOME", "")
	if got, want := DefaultRoot(), filepath.Join(home, ".dieter-gateway"); got != want {
		t.Fatalf("DefaultRoot() = %q, want %q", got, want)
	}
}

func TestOpenStoreRejectsUnversionedDatabase(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "gateway.db")
	database, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	_, err = database.Exec(`CREATE TABLE daemons (
		id TEXT PRIMARY KEY, name TEXT NOT NULL, github_id INTEGER NOT NULL,
		login TEXT NOT NULL, public_key BLOB NOT NULL, certificate BLOB NOT NULL,
		generation INTEGER NOT NULL DEFAULT 1, revoked INTEGER NOT NULL DEFAULT 0,
		created_at TEXT NOT NULL, last_seen_at TEXT NOT NULL DEFAULT '',
		version TEXT NOT NULL DEFAULT '', routes_json BLOB NOT NULL DEFAULT '[]'
	)`)
	if err != nil {
		database.Close()
		t.Fatal(err)
	}
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := OpenStore(root)
	if err == nil {
		store.Close()
		t.Fatal("unversioned existing gateway store was accepted")
	}

}

func TestAuthUpdatesAcrossStoresCannotResurrectRevokedSession(t *testing.T) {
	root := t.TempDir()
	first, err := OpenStore(root)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	second, err := OpenStore(root)
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	if err := first.UpdateAuthState(func(state *AuthState) error {
		state.Sessions = []Session{{TokenHash: "revoked-token", ExpiresAt: time.Now().Add(time.Hour)}}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	read := make(chan struct{})
	release := make(chan struct{})
	updated := make(chan error, 1)
	go func() {
		updated <- first.UpdateAuthState(func(state *AuthState) error {
			close(read)
			<-release
			state.Pending = append(state.Pending, OAuthPending{StateHash: "new-login"})
			return nil
		})
	}()
	<-read
	revoked := make(chan error, 1)
	go func() {
		revoked <- second.UpdateAuthState(func(state *AuthState) error {
			state.Sessions = nil
			return nil
		})
	}()
	var overlapped bool
	select {
	case err := <-revoked:
		overlapped = true
		if err != nil {
			t.Errorf("revocation failed: %v", err)
		}
	case <-time.After(100 * time.Millisecond):
	}
	close(release)
	if err := <-updated; err != nil {
		t.Fatal(err)
	}
	if !overlapped {
		if err := <-revoked; err != nil {
			t.Fatal(err)
		}
	}
	state, err := first.AuthState()
	if err != nil {
		t.Fatal(err)
	}
	if overlapped || len(state.Sessions) != 0 || len(state.Pending) != 1 {
		t.Fatalf("concurrent auth updates were not serialized: overlap=%v sessions=%d pending=%d", overlapped, len(state.Sessions), len(state.Pending))
	}
}
