package config

import (
	"path/filepath"
	"testing"
)

func TestDefaultHomeUsesDieterHome(t *testing.T) {
	want := filepath.Join(t.TempDir(), "state")
	t.Setenv("DIETER_HOME", want)
	if got := DefaultHome(); got != want {
		t.Fatalf("DefaultHome() = %q, want %q", got, want)
	}
}

func TestDefaultHomeUsesHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("DIETER_HOME", "")
	if got, want := DefaultHome(), filepath.Join(home, ".dieter"); got != want {
		t.Fatalf("DefaultHome() = %q, want %q", got, want)
	}
}

func TestParseGlobalsResolvesHomeAndStopsAtCommand(t *testing.T) {
	root := t.TempDir()
	globals, rest, err := ParseGlobals([]string{"-s", root, "--machine", "m1", "--timeout", "3s", "card", "list", "--store", "ignored"})
	if err != nil {
		t.Fatal(err)
	}
	if globals.Home != root || globals.Machine != "m1" || globals.Timeout.String() != "3s" {
		t.Fatalf("globals=%#v", globals)
	}
	if len(rest) != 4 || rest[0] != "card" || rest[3] != "ignored" {
		t.Fatalf("rest=%q", rest)
	}
	t.Setenv("DIETER_HOME", filepath.Join(root, "env"))
	globals, _, err = ParseGlobals(nil)
	if err != nil || globals.Home != filepath.Join(root, "env") {
		t.Fatalf("globals=%#v err=%v", globals, err)
	}
}
