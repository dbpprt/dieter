//go:build darwin

package machine

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

type homebrewFixture struct {
	prefix, keg, brew, executable string
}

func newHomebrewFixture(t *testing.T) homebrewFixture {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	f := homebrewFixture{prefix: filepath.Join(root, "homebrew")}
	f.keg = filepath.Join(f.prefix, "Cellar", "dieter", "0.4.135")
	f.brew = filepath.Join(f.prefix, "bin", "brew")
	f.executable = filepath.Join(f.prefix, "var", "dieter", "service", "bin", "dieter")
	writeFixtureFile(t, filepath.Join(f.keg, "bin", "dieter"), "#!/bin/sh\nexit 0\n")
	writeFixtureFile(t, f.executable, "#!/bin/sh\nexit 0\n")
	writeFixtureFile(t, filepath.Join(f.keg, "INSTALL_RECEIPT.json"), `{"source":{"tap":"dbpprt/tap"}}`)
	if err := os.MkdirAll(filepath.Join(f.prefix, "opt"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(f.keg, filepath.Join(f.prefix, "opt", "dieter")); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIETER_TEST_BREW_PREFIX", f.prefix)
	// A cold formula lookup can exceed the production five-second probe budget.
	// The prefix-only query must succeed without entering that slow path.
	writeFixtureFile(t, f.brew, `#!/bin/sh
if [ "$#" != 1 ] || [ "$1" != --prefix ]; then exec sleep 60; fi
[ "$HOMEBREW_NO_AUTO_UPDATE" = 1 ] || exit 10
[ "$HOMEBREW_NO_ASK" = 1 ] || exit 11
[ "$NONINTERACTIVE" = 1 ] || exit 12
if IFS= read -r ignored; then exit 13; fi
printf '%s\n' "$DIETER_TEST_BREW_PREFIX"
`)
	return f
}

func writeFixtureFile(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0700); err != nil {
		t.Fatal(err)
	}
}

func TestHomebrewUpdateInstallation(t *testing.T) {
	for _, test := range []struct {
		name   string
		change func(*testing.T, *homebrewFixture)
		reason string
	}{
		{name: "fixed runtime"},
		{name: "legacy Cellar runtime", change: func(t *testing.T, f *homebrewFixture) { f.executable = filepath.Join(f.keg, "bin", "dieter") }},
		{name: "symlinked prefix", change: func(t *testing.T, f *homebrewFixture) {
			alias := filepath.Join(t.TempDir(), "brew-prefix")
			if err := os.Symlink(f.prefix, alias); err != nil {
				t.Fatal(err)
			}
			t.Setenv("DIETER_TEST_BREW_PREFIX", alias)
		}},
		{name: "missing formula with leftover runtime", change: func(t *testing.T, f *homebrewFixture) {
			if err := os.Remove(filepath.Join(f.prefix, "opt", "dieter")); err != nil {
				t.Fatal(err)
			}
		}, reason: "formula is not installed"},
		{name: "dangling opt link", change: func(t *testing.T, f *homebrewFixture) {
			if err := os.Rename(f.keg, f.keg+"-old"); err != nil {
				t.Fatal(err)
			}
		}, reason: "formula is not installed"},
		{name: "wrong tap", change: func(t *testing.T, f *homebrewFixture) {
			writeFixtureFile(t, filepath.Join(f.keg, "INSTALL_RECEIPT.json"), `{"source":{"tap":"someone/else"}}`)
		}, reason: "not from dbpprt/tap"},
		{name: "invalid receipt", change: func(t *testing.T, f *homebrewFixture) {
			writeFixtureFile(t, filepath.Join(f.keg, "INSTALL_RECEIPT.json"), "broken")
		}, reason: "receipt could not be verified"},
		{name: "missing receipt", change: func(t *testing.T, f *homebrewFixture) {
			if err := os.Remove(filepath.Join(f.keg, "INSTALL_RECEIPT.json")); err != nil {
				t.Fatal(err)
			}
		}, reason: "receipt could not be verified"},
		{name: "missing installed executable", change: func(t *testing.T, f *homebrewFixture) {
			if err := os.Remove(filepath.Join(f.keg, "bin", "dieter")); err != nil {
				t.Fatal(err)
			}
		}, reason: "binary is unavailable"},
		{name: "non-executable installed binary", change: func(t *testing.T, f *homebrewFixture) {
			if err := os.Chmod(filepath.Join(f.keg, "bin", "dieter"), 0600); err != nil {
				t.Fatal(err)
			}
		}, reason: "binary is unavailable"},
		{name: "unrelated executable", change: func(t *testing.T, f *homebrewFixture) {
			f.executable += "-dev"
			writeFixtureFile(t, f.executable, "dev")
		}, reason: "not the Homebrew-installed Dieter binary"},
		{name: "other executable inside keg", change: func(t *testing.T, f *homebrewFixture) {
			f.executable = filepath.Join(f.keg, "bin", "other")
			writeFixtureFile(t, f.executable, "other")
		}, reason: "not the Homebrew-installed Dieter binary"},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := newHomebrewFixture(t)
			if test.change != nil {
				test.change(t, &f)
			}
			result := homebrewInstallationCapability(context.Background(), f.brew, f.executable)
			if test.reason == "" {
				if !result.Supported || !result.Authorized || result.UnavailableReason != "" || result.retryable {
					t.Fatalf("update unavailable: %+v", result)
				}
			} else if result.Supported || result.Authorized || !strings.Contains(result.UnavailableReason, test.reason) {
				t.Fatalf("got %+v; want unavailable reason containing %q", result, test.reason)
			}
		})
	}
}

func TestHomebrewUpdateProbeFailuresAreRetryable(t *testing.T) {
	for _, test := range []struct {
		name, script, reason string
		canceled, deadline   bool
	}{
		{name: "command failure", script: "exit 1", reason: "could not be checked"},
		{name: "invalid output", script: "printf 'relative/path\\n'", reason: "invalid installation path"},
		{name: "empty output", script: "exit 0", reason: "invalid installation path"},
		{name: "multiple paths", script: "printf '/one\\n/two\\n'", reason: "invalid installation path"},
		{name: "canceled", reason: "was canceled", canceled: true},
		{name: "deadline", script: "exec sleep 60", reason: "timed out", deadline: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := newHomebrewFixture(t)
			if test.script != "" {
				writeFixtureFile(t, f.brew, "#!/bin/sh\n"+test.script+"\n")
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			if test.canceled {
				cancel()
			}
			if test.deadline {
				var deadlineCancel context.CancelFunc
				ctx, deadlineCancel = context.WithTimeout(ctx, 50*time.Millisecond)
				defer deadlineCancel()
			}
			started := time.Now()
			result := homebrewInstallationCapability(ctx, f.brew, f.executable)
			if result.Supported || result.Authorized || !result.retryable || !strings.Contains(result.UnavailableReason, test.reason) {
				t.Fatalf("got %+v; want retryable %q", result, test.reason)
			}
			if time.Since(started) > 2*time.Second {
				t.Fatal("probe ignored cancellation")
			}
		})
	}
}

func TestHomebrewUpdateRequiresManagedService(t *testing.T) {
	for _, state := range []string{"", "invalid json", `{"serviceManaged":false}`} {
		root := t.TempDir()
		if state != "" {
			writeFixtureFile(t, filepath.Join(root, "runtime", "daemon.json"), state)
		}
		result := homebrewUpdateCapability(context.Background(), root)
		if result.Supported || result.Authorized || !strings.Contains(result.UnavailableReason, "Homebrew-managed") {
			t.Fatalf("unmanaged service accepted: %+v", result)
		}
	}
}

func TestHomebrewUpdateRetriesAfterProbeTimeout(t *testing.T) {
	f := newHomebrewFixture(t)
	workingBrew, err := os.ReadFile(f.brew)
	if err != nil {
		t.Fatal(err)
	}
	writeFixtureFile(t, f.brew, "#!/bin/sh\nexec sleep 60\n")
	root := t.TempDir()
	collect := func(ctx context.Context, _ string) []OperationCapability {
		return []OperationCapability{homebrewInstallationCapability(ctx, f.brew, f.executable)}
	}
	first := cachedOperationCapabilitiesAtRoot(context.Background(), root, collect)
	if first[0].Supported || !strings.Contains(first[0].UnavailableReason, "timed out") {
		t.Fatalf("timeout was misreported: %+v", first)
	}
	writeFixtureFile(t, f.brew, string(workingBrew))
	next := cachedOperationCapabilitiesAtRoot(context.Background(), root, collect)
	if !next[0].Supported || !next[0].Authorized {
		t.Fatalf("recovered installation is still disabled: %+v", next)
	}
}
