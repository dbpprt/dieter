package gateway

import (
	"database/sql"
	"os"
	"path/filepath"
	"testing"
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

func TestOpenStoreMigratesDaemonPresenceColumns(t *testing.T) {
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
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	rows, err := store.DB.Query(`PRAGMA table_info(daemons)`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	foundRemoteDesktop := false
	foundAPIVersion := false
	for rows.Next() {
		var index int
		var name, columnType string
		var notNull, primaryKey int
		var defaultValue sql.NullString
		if err := rows.Scan(&index, &name, &columnType, &notNull, &defaultValue, &primaryKey); err != nil {
			t.Fatal(err)
		}
		foundRemoteDesktop = foundRemoteDesktop || name == "remote_desktop_json"
		foundAPIVersion = foundAPIVersion || name == "api_version"
	}
	if !foundRemoteDesktop {
		t.Fatal("remote_desktop_json column was not added")
	}
	if !foundAPIVersion {
		t.Fatal("api_version column was not added")
	}
}
