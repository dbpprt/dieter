package machine

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDaemonUpdateWorkerRunsOnlyTheFixedNonInteractiveHomebrewSteps(t *testing.T) {
	directory := t.TempDir()
	brew := filepath.Join(directory, "brew")
	trace := filepath.Join(directory, "trace")
	script := `#!/bin/sh
if IFS= read -r ignored; then stdin=data; else stdin=eof; fi
printf '%s|ask=%s|noauto=%s|noninteractive=%s|stdin=%s\n' "$*" "${HOMEBREW_NO_ASK:-}" "${HOMEBREW_NO_AUTO_UPDATE:-}" "${NONINTERACTIVE:-}" "$stdin" >>"$DIETER_UPDATE_TEST_TRACE"
`
	if err := os.WriteFile(brew, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIETER_UPDATE_TEST_TRACE", trace)
	t.Setenv("HOMEBREW_ASK", "1")
	t.Setenv("HOMEBREW_NO_ASK", "0")
	t.Setenv("HOMEBREW_NO_AUTO_UPDATE", "inherited")
	var output bytes.Buffer
	if err := RunDaemonUpdateWorker([]string{"--brew", brew}, &output); err != nil {
		t.Fatalf("worker output=%q err=%v", output.String(), err)
	}
	raw, err := os.ReadFile(trace)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	want := []string{
		"update|ask=1|noauto=|noninteractive=1|stdin=eof",
		"upgrade dbpprt/tap/dieter|ask=1|noauto=1|noninteractive=1|stdin=eof",
		"services restart dbpprt/tap/dieter|ask=1|noauto=1|noninteractive=1|stdin=eof",
	}
	if strings.Join(lines, "\n") != strings.Join(want, "\n") {
		t.Fatalf("steps:\n%s\nwant:\n%s", strings.Join(lines, "\n"), strings.Join(want, "\n"))
	}
	if !strings.Contains(output.String(), "refresh Homebrew metadata") || !strings.Contains(output.String(), "update command completed") {
		t.Fatalf("worker output=%q", output.String())
	}
}

func TestDaemonUpdateWorkerRejectsAnArbitraryExecutable(t *testing.T) {
	var output bytes.Buffer
	if err := RunDaemonUpdateWorker([]string{"--brew", "/bin/sh"}, &output); err == nil {
		t.Fatal("arbitrary executable was accepted")
	}
}

func TestDaemonUpdateWorkerStopsBeforeRestartWhenUpgradeFails(t *testing.T) {
	directory := t.TempDir()
	brew := filepath.Join(directory, "brew")
	trace := filepath.Join(directory, "trace")
	script := `#!/bin/sh
printf '%s\n' "$*" >>"$DIETER_UPDATE_TEST_TRACE"
test "$1" != upgrade
`
	if err := os.WriteFile(brew, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIETER_UPDATE_TEST_TRACE", trace)
	var output bytes.Buffer
	err := RunDaemonUpdateWorker([]string{"--brew", brew}, &output)
	if err == nil || !strings.Contains(err.Error(), "upgrade Dieter") {
		t.Fatalf("worker output=%q err=%v", output.String(), err)
	}
	raw, readErr := os.ReadFile(trace)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if string(raw) != "update\nupgrade dbpprt/tap/dieter\n" {
		t.Fatalf("unexpected commands after failure: %q", raw)
	}
}
