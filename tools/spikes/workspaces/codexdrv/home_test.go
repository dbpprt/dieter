package codexdrv

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fakeJWT(exp time.Time) string {
	enc := base64.RawURLEncoding.EncodeToString
	return enc([]byte(`{"alg":"none"}`)) + "." + enc([]byte(fmt.Sprintf(`{"exp":%d,"sub":"user-x"}`, exp.Unix()))) + "." + enc([]byte("signature-bytes"))
}

func writeAuth(t *testing.T, access string) (string, []byte) {
	t.Helper()
	src := filepath.Join(t.TempDir(), "auth.json")
	raw := []byte(`{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"idtok-fixture-value","access_token":"` + access + `","refresh_token":"rt-fixture","account_id":"acct-1"},"last_refresh":"2026-10-18T05:45:08.482152Z","extra":{"big":12345678901234567890}}`)
	if err := os.WriteFile(src, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	return src, raw
}

func TestPrepareHomeFromFile(t *testing.T) {
	access := fakeJWT(time.Now().Add(5 * time.Hour))
	src, raw := writeAuth(t, access)
	dst := filepath.Join(t.TempDir(), "home")
	if err := PrepareHomeFromFile(dst, src); err != nil {
		t.Fatal(err)
	}
	if after, _ := os.ReadFile(src); !bytes.Equal(after, raw) {
		t.Fatal("source auth.json was modified")
	}
	st, err := os.Stat(dst)
	if err != nil || st.Mode().Perm() != 0o700 {
		t.Fatalf("home mode %v %v", st.Mode().Perm(), err)
	}
	st, err = os.Stat(filepath.Join(dst, "auth.json"))
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("auth mode %v %v", st.Mode().Perm(), err)
	}
	out, _ := os.ReadFile(filepath.Join(dst, "auth.json"))
	if bytes.Contains(out, []byte("rt-fixture")) {
		t.Fatal("real refresh token copied")
	}
	var got, want map[string]any
	dec := json.NewDecoder(bytes.NewReader(out))
	dec.UseNumber()
	if err := dec.Decode(&got); err != nil {
		t.Fatal(err)
	}
	dec = json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	_ = dec.Decode(&want)
	want["tokens"].(map[string]any)["refresh_token"] = NeuteredRefreshToken
	gb, _ := json.Marshal(got)
	wb, _ := json.Marshal(want)
	if !bytes.Equal(gb, wb) {
		t.Fatalf("copy differs beyond the refresh token:\n got %s\nwant %s", gb, wb)
	}
	cfg, _ := os.ReadFile(filepath.Join(dst, "config.toml"))
	for _, line := range []string{`model_reasoning_effort = "low"`, `cli_auth_credentials_store = "file"`} {
		if !strings.Contains(string(cfg), line) {
			t.Fatalf("config.toml lacks %s:\n%s", line, cfg)
		}
	}
	if secrets := homeSecrets(dst); len(secrets) != 3 {
		t.Fatalf("expected access, id and neutered refresh secrets, got %d", len(secrets))
	}
}

func TestPrepareHomeRefusesShortLivedToken(t *testing.T) {
	access := fakeJWT(time.Now().Add(90 * time.Minute))
	src, _ := writeAuth(t, access)
	dst := filepath.Join(t.TempDir(), "home")
	err := PrepareHomeFromFile(dst, src)
	if err == nil || !strings.Contains(err.Error(), "expires in") {
		t.Fatalf("want expiry refusal, got %v", err)
	}
	if strings.Contains(err.Error(), access) || strings.Contains(err.Error(), "rt-fixture") {
		t.Fatal("error leaks token material")
	}
	if _, err := os.Stat(filepath.Join(dst, "auth.json")); !os.IsNotExist(err) {
		t.Fatal("auth.json written despite refusal")
	}
}

func TestPrepareHomeRejectsBadSources(t *testing.T) {
	for name, raw := range map[string]string{
		"not json":  "nope",
		"no tokens": `{"auth_mode":"apikey","OPENAI_API_KEY":"sk-x"}`,
		"not a jwt": `{"tokens":{"access_token":"opaque","refresh_token":"r"}}`,
		"no exp":    `{"tokens":{"access_token":"` + base64.RawURLEncoding.EncodeToString([]byte("{}")) + "." + base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"x"}`)) + `.sig","refresh_token":"r"}}`,
	} {
		src := filepath.Join(t.TempDir(), "auth.json")
		_ = os.WriteFile(src, []byte(raw), 0o600)
		if err := PrepareHomeFromFile(filepath.Join(t.TempDir(), "h"), src); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestWriteConfigRejectsOddValues(t *testing.T) {
	if err := writeConfig(t.TempDir(), "gpt\"\nx = 1", "low"); err == nil {
		t.Fatal("accepted a TOML-injecting model name")
	}
}
