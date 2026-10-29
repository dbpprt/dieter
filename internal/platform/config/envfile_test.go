package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// unsetForTest removes keys from the process environment and restores their
// previous values when the test ends.
func unsetForTest(t *testing.T, keys ...string) {
	t.Helper()
	for _, key := range keys {
		t.Setenv(key, "")
		if err := os.Unsetenv(key); err != nil {
			t.Fatal(err)
		}
	}
}

func writeEnvFile(t *testing.T, mode os.FileMode, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), ".env")
	if err := os.WriteFile(path, []byte(body), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadEnvFileParsesPrivateFileWithoutReplacingExplicitValues(t *testing.T) {
	unsetForTest(t, "DIETER_TEST_PLAIN", "DIETER_TEST_EXPORTED", "DIETER_TEST_SINGLE", "DIETER_TEST_DOUBLE", "DIETER_TEST_EMPTY", "DIETER_TEST_EXPLICIT")
	t.Setenv("DIETER_TEST_EXPLICIT", "from process")
	path := writeEnvFile(t, 0o600, strings.Join([]string{
		"# provider credentials",
		"",
		"DIETER_TEST_PLAIN = plain value ",
		"export DIETER_TEST_EXPORTED=exported",
		`DIETER_TEST_SINGLE='literal \n $HOME'`,
		`DIETER_TEST_DOUBLE="line\nnext \"quoted\""`,
		"DIETER_TEST_EMPTY=",
		"DIETER_TEST_EXPLICIT=from file",
	}, "\n"))
	if err := LoadEnvFile(t.TempDir(), path); err != nil {
		t.Fatal(err)
	}
	for key, want := range map[string]string{
		"DIETER_TEST_PLAIN":    "plain value",
		"DIETER_TEST_EXPORTED": "exported",
		"DIETER_TEST_SINGLE":   `literal \n $HOME`,
		"DIETER_TEST_DOUBLE":   "line\nnext \"quoted\"",
		"DIETER_TEST_EXPLICIT": "from process",
	} {
		if got := os.Getenv(key); got != want {
			t.Errorf("%s=%q, want %q", key, got, want)
		}
	}
	if value, ok := os.LookupEnv("DIETER_TEST_EMPTY"); !ok || value != "" {
		t.Errorf("empty value=%q set=%v", value, ok)
	}
}

func TestLoadEnvFileRequiresMode0600(t *testing.T) {
	unsetForTest(t, "DIETER_TEST_SHARED")
	for _, mode := range []os.FileMode{0o644, 0o640, 0o604, 0o660} {
		path := writeEnvFile(t, mode, "DIETER_TEST_SHARED=secret\n")
		err := LoadEnvFile(t.TempDir(), path)
		if err == nil || !strings.Contains(err.Error(), "must have mode 0600") {
			t.Fatalf("mode %o: %v", mode, err)
		}
		if _, set := os.LookupEnv("DIETER_TEST_SHARED"); set {
			t.Fatalf("mode %o leaked a value into the environment", mode)
		}
	}
	if err := LoadEnvFile(t.TempDir(), writeEnvFile(t, 0o400, "DIETER_TEST_SHARED=secret\n")); err != nil {
		t.Fatalf("owner read-only file: %v", err)
	}
}

func TestLoadEnvFileDefaultsToTheOptionalHomeFile(t *testing.T) {
	unsetForTest(t, "DIETER_TEST_HOME_FILE")
	root := t.TempDir()
	if err := LoadEnvFile(root, ""); err != nil {
		t.Fatalf("missing optional home file: %v", err)
	}
	if err := LoadEnvFile(root, filepath.Join(root, "missing.env")); err == nil {
		t.Fatal("missing explicit file was ignored")
	}
	if err := os.WriteFile(filepath.Join(root, ".env"), []byte("DIETER_TEST_HOME_FILE=1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := LoadEnvFile(root, "  "); err != nil || os.Getenv("DIETER_TEST_HOME_FILE") != "1" {
		t.Fatalf("home file value=%q err=%v", os.Getenv("DIETER_TEST_HOME_FILE"), err)
	}
}

func TestLoadEnvFileReportsTheMalformedLine(t *testing.T) {
	unsetForTest(t, "DIETER_TEST_BEFORE")
	for body, line := range map[string]string{
		"DIETER_TEST_BEFORE=1\nnot an assignment\n": "line 2",
		"# comment\n=missing key\n":                 "line 2",
		"DIETER_TEST_QUOTE=\"bad \\q escape\"\n":    "line 1",
	} {
		err := LoadEnvFile(t.TempDir(), writeEnvFile(t, 0o600, body))
		if err == nil || !strings.Contains(err.Error(), line) {
			t.Errorf("%q: %v", body, err)
		}
	}
}
