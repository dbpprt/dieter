package serviceruntime

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func fixtureRuntime(t *testing.T) Runtime {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return Runtime{Root: filepath.Join(root, "service"), Verify: func(_ context.Context, dir string) error {
		for _, name := range executables {
			raw, err := os.ReadFile(filepath.Join(dir, name))
			if err != nil {
				return err
			}
			if strings.HasPrefix(string(raw), "INVALID") {
				return errors.New("invalid signature fixture")
			}
		}
		return nil
	}}
}

func fixturePair(t *testing.T, version string) string {
	t.Helper()
	dir := t.TempDir()
	for _, name := range executables {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(version+":"+name), 0755); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestDaemonBundleStagesAtomicallyAndRollsBack(t *testing.T) {
	r := fixtureRuntime(t)
	r.SourceExecutablePrefix = "DieterDaemon.app/Contents/MacOS"
	r.Bundles = []string{"DieterDaemon.app"}
	source := t.TempDir()
	path := filepath.Join(source, r.SourceExecutablePrefix)
	if err := os.MkdirAll(path, 0755); err != nil {
		t.Fatal(err)
	}
	for _, name := range executables {
		if err := os.WriteFile(filepath.Join(path, name), []byte("A:"+name), 0755); err != nil {
			t.Fatal(err)
		}
	}
	metadata := filepath.Join(source, "DieterDaemon.app/Contents/Info.plist")
	if err := os.WriteFile(metadata, []byte("metadata-A"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(t.Context(), source); err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(t.Context(), source); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(r.path("pending")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("identical bundle staged another activation")
	}
	resolved, err := r.SourceDirectory(filepath.Join(path, "dieter"))
	if err != nil || resolved != source {
		t.Fatalf("release root: %q %v", resolved, err)
	}
	if _, err := r.SourceDirectory(filepath.Join(source, "dieter")); err == nil {
		t.Fatal("accepted executable outside daemon bundle")
	}
	if err := os.WriteFile(metadata, []byte("metadata-B"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(t.Context(), source); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(r.path("bin/DieterDaemon.app/Contents/Info.plist"))
	if err != nil || string(raw) != "metadata-A" {
		t.Fatalf("running bundle overwritten: %q %v", raw, err)
	}
	if _, err := os.Stat(r.DaemonExecutable()); err != nil {
		t.Fatal(err)
	}
	if inner, err := os.ReadFile(r.path("bin/DieterDaemon.app/Contents/MacOS/dieter")); err != nil || string(inner) != "A:dieter" {
		t.Fatal("bundle is missing the canonical daemon executable")
	}
	service, reexec, err := r.Start(t.Context())
	if err != nil || !reexec {
		t.Fatalf("activation: %v %v", reexec, err)
	}
	service.Close()
	service, reexec, err = r.Start(t.Context()) // Crash before readiness rolls the whole bundle back.
	if err != nil || !reexec {
		t.Fatalf("rollback: %v %v", reexec, err)
	}
	service.Close()
	raw, err = os.ReadFile(r.path("bin/DieterDaemon.app/Contents/Info.plist"))
	if err != nil || string(raw) != "metadata-A" {
		t.Fatalf("bundle did not roll back: %q %v", raw, err)
	}
	if err := os.Symlink(filepath.Join(path, "dieter-capture"), filepath.Join(path, "link")); err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(t.Context(), source); err == nil {
		t.Fatal("accepted a link in daemon bundle")
	}
}

func TestBundledRuntimeAdoptsPreBundleActivation(t *testing.T) {
	for _, acknowledge := range []bool{true, false} {
		t.Run(fmt.Sprint("acknowledge-", acknowledge), func(t *testing.T) {
			legacy := fixtureRuntime(t)
			if err := legacy.Stage(t.Context(), fixturePair(t, "A")); err != nil {
				t.Fatal(err)
			}
			current := legacy
			current.SourceExecutablePrefix = "DieterDaemon.app/Contents/MacOS"
			current.Bundles = []string{"DieterDaemon.app"}
			source := t.TempDir()
			pair := filepath.Join(source, current.SourceExecutablePrefix)
			if err := os.MkdirAll(pair, 0755); err != nil {
				t.Fatal(err)
			}
			for _, name := range executables {
				if err := os.WriteFile(filepath.Join(pair, name), []byte("B:"+name), 0755); err != nil {
					t.Fatal(err)
				}
			}
			if err := current.Stage(t.Context(), source); err != nil {
				t.Fatal(err)
			}
			assertPair(t, legacy, "A")
			// The existing service activates the new release using its old pair-only journal.
			service, reexec, err := legacy.Start(t.Context())
			if err != nil || !reexec {
				t.Fatalf("legacy activation: %v %v", reexec, err)
			}
			token := service.token
			service.Close()
			raw, err := os.ReadFile(current.path("activation.json"))
			if err != nil {
				t.Fatal(err)
			}
			var journal activation
			if err := json.Unmarshal(raw, &journal); err != nil {
				t.Fatal(err)
			}
			journal.Format = 0
			if err := writeJSON(current.path("activation.json"), journal); err != nil {
				t.Fatal(err)
			}
			if acknowledge {
				t.Setenv(activationEnv, token)
			} else {
				t.Setenv(activationEnv, "")
			}
			service, reexec, err = current.Start(t.Context())
			if err != nil || reexec == acknowledge {
				t.Fatalf("bundled takeover: %v %v", reexec, err)
			}
			defer service.Close()
			if acknowledge {
				assertPair(t, current, "B")
				if err := service.Ready(); err != nil {
					t.Fatal(err)
				}
				if err := current.verify(t.Context(), current.path("bin")); err != nil {
					t.Fatal(err)
				}
				// Copies at the stable service path must match the signed bundle exactly.
				if err := os.WriteFile(filepath.Join(current.path("bin"), current.SourceExecutablePrefix, "dieter"), []byte("other"), 0755); err != nil {
					t.Fatal(err)
				}
				if err := current.verify(t.Context(), current.path("bin")); err == nil {
					t.Fatal("accepted different daemon bytes in the bundle")
				}
			} else {
				assertPair(t, current, "A")
				if _, err := os.Stat(current.path("bin/DieterDaemon.app")); !errors.Is(err, os.ErrNotExist) {
					t.Fatal("failed upgrade did not restore unbundled installation")
				}
			}
		})
	}
}

func TestRuntimeHardensExistingRoot(t *testing.T) {
	parent, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(parent, "service")
	if err := os.Mkdir(root, 0o755); err != nil {
		t.Fatal(err)
	}
	r := Runtime{Root: root}
	if err := r.prepare(); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(root)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o700 {
		t.Fatalf("runtime root mode = %04o, want 0700", got)
	}
}

func assertPair(t *testing.T, r Runtime, version string) {
	t.Helper()
	for _, name := range executables {
		path := r.path("bin/" + name)
		raw, err := os.ReadFile(path)
		if err != nil || string(raw) != version+":"+name {
			t.Fatalf("%s = %q, %v; want %s", path, raw, err, version)
		}
		info, _ := os.Lstat(path)
		if !info.Mode().IsRegular() {
			t.Fatal("runtime executable is not a real file")
		}
	}
}

func TestStageDoesNotChangeRunningPairAndRestartCommits(t *testing.T) {
	ctx := context.Background()
	r := fixtureRuntime(t)
	if err := r.Stage(ctx, fixturePair(t, "A")); err != nil {
		t.Fatal(err)
	}
	service, reexec, err := r.Start(ctx)
	if err != nil || reexec {
		t.Fatalf("first start: %v %v", reexec, err)
	}
	if err := r.Stage(ctx, fixturePair(t, "B")); err != nil {
		t.Fatal(err)
	}
	assertPair(t, r, "A")
	if other, _, err := r.Start(ctx); err == nil {
		other.Close()
		t.Fatal("second service acquired runtime")
	}
	service.Close()
	service, reexec, err = r.Start(ctx)
	if err != nil || !reexec {
		t.Fatalf("activation: %v %v", reexec, err)
	}
	assertPair(t, r, "B")
	t.Setenv(activationEnv, service.token)
	service.Close()
	service, reexec, err = r.Start(ctx)
	if err != nil || reexec {
		t.Fatalf("reexecuted start: %v %v", reexec, err)
	}
	if err := service.Ready(); err != nil {
		t.Fatal(err)
	}
	service.Close()
	t.Setenv(activationEnv, "")
	service, reexec, err = r.Start(ctx)
	if err != nil || reexec {
		t.Fatalf("committed restart: %v %v", reexec, err)
	}
	defer service.Close()
	assertPair(t, r, "B")
}

func TestUnacknowledgedActivationRollsBack(t *testing.T) {
	r := fixtureRuntime(t)
	ctx := context.Background()
	for _, v := range []string{"A", "B"} {
		if err := r.Stage(ctx, fixturePair(t, v)); err != nil {
			t.Fatal(err)
		}
	}
	service, _, err := r.Start(ctx)
	if err != nil {
		t.Fatal(err)
	}
	assertPair(t, r, "B")
	service.Close() // Simulate crash before listener readiness, losing the token.
	service, reexec, err := r.Start(ctx)
	if err != nil || !reexec {
		t.Fatalf("rollback: %v %v", reexec, err)
	}
	service.Close()
	assertPair(t, r, "A")
	service, reexec, err = r.Start(ctx)
	if err != nil || reexec {
		t.Fatalf("rollback restart: %v %v", reexec, err)
	}
	service.Close()
}

func TestRejectedAndRepeatedStagesPreserveActiveRuntime(t *testing.T) {
	r := fixtureRuntime(t)
	ctx := context.Background()
	a := fixturePair(t, "A")
	if err := r.Stage(ctx, a); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(r.path(".stage-interrupted"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(ctx, a); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(r.path(".stage-interrupted")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("interrupted staging was not collected")
	}
	if err := r.Stage(ctx, fixturePair(t, "INVALID")); err == nil {
		t.Fatal("accepted invalid signature")
	}
	if err := r.Stage(ctx, fixturePair(t, "B")); err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(ctx, a); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(r.path("pending")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("same installed release left stale pending update")
	}
	assertPair(t, r, "A")
	// A partial package cannot replace either installed executable.
	if err := os.Remove(filepath.Join(a, "dieter-capture")); err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(ctx, a); err == nil {
		t.Fatal("accepted incomplete pair")
	}
	assertPair(t, r, "A")
}

func TestStageRejectsSymlinkRuntimeAndExecutable(t *testing.T) {
	r := fixtureRuntime(t)
	source := fixturePair(t, "A")
	if err := os.Symlink(source, r.Root); err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(context.Background(), source); err == nil {
		t.Fatal("accepted symlink runtime")
	}
	r = fixtureRuntime(t)
	if err := os.Remove(filepath.Join(source, "dieter")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(source, "dieter-capture"), filepath.Join(source, "dieter")); err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(context.Background(), source); err == nil {
		t.Fatal("accepted symlink binary")
	}
}

func TestTamperedPendingReleaseCannotActivate(t *testing.T) {
	r := fixtureRuntime(t)
	for _, v := range []string{"A", "B"} {
		if err := r.Stage(context.Background(), fixturePair(t, v)); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(r.path("pending/dieter"), []byte("INVALID"), 0755); err != nil {
		t.Fatal(err)
	}
	if service, _, err := r.Start(context.Background()); err == nil {
		service.Close()
		t.Fatal("activated tampered release")
	}
	assertPair(t, r, "A")
}

func TestInterruptedJournalBeforeExchangeKeepsOldPair(t *testing.T) {
	r := fixtureRuntime(t)
	for _, v := range []string{"A", "B"} {
		if err := r.Stage(context.Background(), fixturePair(t, v)); err != nil {
			t.Fatal(err)
		}
	}
	before, _ := pairHash(r.path("bin"))
	after, _ := pairHash(r.path("pending"))
	if err := os.Rename(r.path("pending"), r.path("candidate")); err != nil {
		t.Fatal(err)
	}
	if err := writeJSON(r.path("activation.json"), activation{Token: "interrupted", Before: before, After: after}); err != nil {
		t.Fatal(err)
	}
	service, reexec, err := r.Start(context.Background())
	if err != nil || reexec {
		t.Fatalf("recovery: %v %v", reexec, err)
	}
	service.Close()
	assertPair(t, r, "A")
}

func TestRuntimeExecInheritsLockAndAcknowledgesSamePath(t *testing.T) {
	r := fixtureRuntime(t)
	source := fixturePair(t, "A")
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(source, "dieter")); err != nil {
		t.Fatal(err)
	}
	if err := copyExecutable(self, filepath.Join(source, "dieter")); err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(context.Background(), source); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "dieter-capture"), []byte("B:helper"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(context.Background(), source); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(r.path("bin/dieter"), "-test.run=^TestRuntimeSubprocess$")
	cmd.Env = append(os.Environ(), "DIETER_RUNTIME_TEST_ROOT="+r.Root)
	if raw, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("runtime exec: %s: %v", raw, err)
	}
	if _, err := os.Stat(r.path("activation.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("subprocess did not acknowledge activation")
	}
	if raw, err := os.ReadFile(r.path("bin/dieter-capture")); err != nil || string(raw) != "B:helper" {
		t.Fatal("subprocess did not use new pair")
	}
}

func TestRuntimeSubprocess(t *testing.T) {
	root := os.Getenv("DIETER_RUNTIME_TEST_ROOT")
	if root == "" {
		return
	}
	r := Runtime{Root: root, Verify: func(context.Context, string) error { return nil }}
	service, reexec, err := r.Start(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()
	if reexec {
		t.Fatal(service.Exec(os.Args))
	}
	if other, _, err := r.Start(context.Background()); err == nil {
		other.Close()
		t.Fatal("lifetime lock was lost across exec")
	}
	if err := service.Ready(); err != nil {
		t.Fatal(err)
	}
}
