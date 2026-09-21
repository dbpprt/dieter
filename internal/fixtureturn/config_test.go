package fixtureturn

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestFixtureTURNExplicitProtectedConfiguration(t *testing.T) {
	t.Setenv("DIETER_TEST_TURN_CONFIG", "")
	value, err := Load()
	if err != nil || value != nil {
		t.Fatal("TURN fixture must remain opt-in")
	}
	path := filepath.Join(t.TempDir(), "turn.json")
	config := Config{URLs: []string{"turn:127.0.0.1:23478?transport=tcp"}, SharedSecret: strings.Repeat("fixture-only-", 4)}
	data, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIETER_TEST_TURN_CONFIG", path)
	if _, err = Load(); err == nil || strings.Contains(err.Error(), config.SharedSecret) {
		t.Fatal("public fixture secrets must be rejected without disclosure")
	}
	if err = os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	value, err = Load()
	if err != nil || value.SharedSecret != config.SharedSecret {
		t.Fatal("private configuration must retain exact secret bytes")
	}
	if err = os.WriteFile(path, append(data, []byte(` {"unexpected":true}`)...), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err = Load(); err == nil {
		t.Fatal("trailing configuration must be rejected")
	}
}
