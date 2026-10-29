package daemon

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dbpprt/dieter/internal/link"
	"github.com/dbpprt/dieter/internal/platform/config"
)

func TestMainDispatchesTheDetachedDaemonUpdateWorkerBeforeOpeningStorage(t *testing.T) {
	directory := t.TempDir()
	brew := filepath.Join(directory, "brew")
	trace := filepath.Join(directory, "trace")
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >>\"$DIETER_UPDATE_TEST_TRACE\"\n"
	if err := os.WriteFile(brew, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIETER_UPDATE_TEST_TRACE", trace)
	args := []string{"__daemon-update-worker", "--brew", brew}
	if !Handles(args) {
		t.Fatal("daemon does not handle the update worker")
	}
	if code := Main(args); code != 0 {
		t.Fatalf("worker exit code=%d", code)
	}
	raw, err := os.ReadFile(trace)
	if err != nil {
		t.Fatal(err)
	}
	want := "update\nupgrade dbpprt/tap/dieter\nservices restart dbpprt/tap/dieter\n"
	if string(raw) != want {
		t.Fatalf("worker commands=%q want=%q", raw, want)
	}
}

func TestHarnessCatalogPrecedence(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	path := filepath.Join(root, "harnesses.yaml")
	data := []byte("version: 1\nharnesses:\n  - id: local\n    name: Local\n    adapter: pi\n    defaultModel: one\n    models:\n      - id: one\n        name: One\n")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	catalog, err := newCatalog(root, "", config.Daemon{})
	if err != nil {
		t.Fatal(err)
	}
	if source := catalog.Source(); source != path {
		t.Fatalf("store override source=%q want %q", source, path)
	}
	explicit := filepath.Join(t.TempDir(), "explicit.yaml")
	if err := os.WriteFile(explicit, data, 0o600); err != nil {
		t.Fatal(err)
	}
	catalog, err = newCatalog(root, "", config.Daemon{HarnessConfig: explicit, MockHarness: true})
	if err != nil {
		t.Fatal(err)
	}
	if catalog.Source() != explicit || !catalog.Valid("mock") || !catalog.Valid("local") {
		t.Fatalf("environment catalog source=%q mock=%v", catalog.Source(), catalog.Valid("mock"))
	}
	if _, err := newCatalog(root, filepath.Join(root, "missing.yaml"), config.Daemon{HarnessConfig: explicit}); err == nil {
		t.Fatal("a missing --harness-config was accepted")
	}
}

func TestServiceLoggerWritesCentralBoundedLog(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	logger, path, closeLog, err := daemonLogger(root, true, false, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	logger.Info("service ready", "store", root)
	closeLog()
	if path != link.LogPath(root) {
		t.Fatalf("path=%q", path)
	}
	raw, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(raw), "service ready") {
		t.Fatalf("log=%q err=%v", raw, err)
	}
}

func TestHandlesOnlyDaemonEntryPoints(t *testing.T) {
	t.Parallel()
	for _, args := range [][]string{
		{"serve"}, {"daemon", "start"}, {"--store", "/tmp/x", "serve", "--verbose"}, {"-s", "/tmp/x", "daemon", "start", "--help"},
		{"__service-stage"}, {"__harness-prepare"}, {"__daemon-update-worker"}, {"__linux-update-worker"},
	} {
		if !Handles(args) {
			t.Errorf("Handles(%q) = false", args)
		}
	}
	for _, args := range [][]string{
		nil, {"daemon"}, {"daemon", "status"}, {"--help", "serve"}, {"--version"}, {"card", "list"}, {"--machine", "m", "status"},
	} {
		if Handles(args) {
			t.Errorf("Handles(%q) = true", args)
		}
	}
}

func TestParseStartHelpAndValidation(t *testing.T) {
	t.Parallel()
	globals := config.Globals{Home: t.TempDir()}
	var out bytes.Buffer
	if _, help, err := ParseStart(globals, []string{"--help"}, &out); !help || err != nil || out.String() != StartUsage {
		t.Fatalf("help=%v err=%v out=%q", help, err, out.String())
	}
	if _, _, err := ParseStart(globals, []string{"--runtime", "/opt/dieter"}, io.Discard); err == nil || !strings.Contains(err.Error(), "--runtime requires --service") {
		t.Fatalf("runtime without service err=%v", err)
	}
	if _, _, err := ParseStart(globals, []string{"--addr", "0.0.0.0:4242"}, io.Discard); err == nil || !strings.Contains(err.Error(), "loopback") {
		t.Fatalf("public listen err=%v", err)
	}
	cfg, help, err := ParseStart(globals, []string{"--verbose", "--addr", "127.0.0.1:0"}, io.Discard)
	if help || err != nil || !cfg.Verbose || cfg.Addr != "127.0.0.1:0" || cfg.Home != globals.Home {
		t.Fatalf("cfg=%#v help=%v err=%v", cfg, help, err)
	}
}
