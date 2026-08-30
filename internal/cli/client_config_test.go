package cli

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestClientConfigRoundTripUsesPrivatePermissions(t *testing.T) {
	root := t.TempDir()
	origin := "https://gateway.example"
	configuration := clientConfig{
		DefaultGateway: origin,
		Sessions: map[string]clientSession{
			origin: {AccessToken: "secret-token", ExpiresAt: time.Now().UTC().Add(time.Hour).Format(time.RFC3339Nano), Login: "tester"},
		},
	}
	if err := saveClientConfig(root, configuration); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(clientConfigPath(root))
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("credential mode=%#o want 0600", got)
	}
	directory, err := os.Stat(filepath.Dir(clientConfigPath(root)))
	if err != nil {
		t.Fatal(err)
	}
	if got := directory.Mode().Perm(); got != 0o700 {
		t.Fatalf("credential directory mode=%#o want 0700", got)
	}
	loaded, err := loadClientConfig(root)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.DefaultGateway != origin || loaded.Sessions[origin].AccessToken != "secret-token" {
		t.Fatalf("unexpected round trip: %#v", loaded)
	}
}

func TestClientSessionValidityHonorsExpiryMargin(t *testing.T) {
	now := time.Now().UTC()
	if (clientSession{AccessToken: "token", ExpiresAt: now.Add(29 * time.Second).Format(time.RFC3339Nano)}).valid(now) {
		t.Fatal("near-expired session should require a new login")
	}
	if !(clientSession{AccessToken: "token", ExpiresAt: now.Add(time.Minute).Format(time.RFC3339Nano)}).valid(now) {
		t.Fatal("unexpired session should be valid")
	}
	if (clientSession{ExpiresAt: now.Add(time.Hour).Format(time.RFC3339Nano)}).valid(now) {
		t.Fatal("session without an access token should be invalid")
	}
}
