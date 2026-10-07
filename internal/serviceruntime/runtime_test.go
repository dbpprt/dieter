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

func fixturePrivacyRelease(t *testing.T, version string) string {
	t.Helper()
	source := fixturePair(t, version)
	path := filepath.Join(source, "DieterPrivacyHelper.app/Contents/MacOS")
	if err := os.MkdirAll(path, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(path, "dieter-privacy"), []byte(version+":privacy"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "DieterPrivacyHelper.app/Contents/Info.plist"), []byte("metadata-"+version), 0644); err != nil {
		t.Fatal(err)
	}
	return source
}

func fixturePrivacyRuntime(t *testing.T) Runtime {
	t.Helper()
	r := fixtureRuntime(t)
	pairVerify := r.Verify
	r.Bundles = []string{"DieterPrivacyHelper.app"}
	r.Verify = func(ctx context.Context, dir string) error {
		if err := pairVerify(ctx, dir); err != nil {
			return err
		}
		helper := filepath.Join(dir, "DieterPrivacyHelper.app/Contents/MacOS/dieter-privacy")
		if _, err := os.Stat(filepath.Dir(helper)); errors.Is(err, os.ErrNotExist) {
			return nil
		} // pre-helper rollback
		raw, err := os.ReadFile(helper)
		if err != nil {
			return err
		}
		if strings.HasPrefix(string(raw), "INVALID") {
			return errors.New("invalid helper signature fixture")
		}
		return nil
	}
	return r
}

func TestPrivacyHelperStagesWithStandaloneDaemonAndRollsBack(t *testing.T) {
	r := fixturePrivacyRuntime(t)
	source := fixturePrivacyRelease(t, "A")
	if err := r.Stage(t.Context(), source); err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(t.Context(), source); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(r.path("pending")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("identical helper staged another activation")
	}
	assertPair(t, r, "A")
	for _, name := range executables {
		if _, err := os.Stat(filepath.Join(r.path("bin/DieterPrivacyHelper.app/Contents/MacOS"), name)); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("Go daemon or capture executable was bundled")
		}
	}
	metadata := filepath.Join(source, "DieterPrivacyHelper.app/Contents/Info.plist")
	if err := os.WriteFile(metadata, []byte("metadata-B"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(t.Context(), source); err != nil {
		t.Fatal(err)
	}
	assertMetadata := func(expected string) {
		t.Helper()
		raw, err := os.ReadFile(r.path("bin/DieterPrivacyHelper.app/Contents/Info.plist"))
		if err != nil || string(raw) != expected {
			t.Fatalf("helper metadata: %q %v", raw, err)
		}
	}
	assertMetadata("metadata-A")
	service, reexec, err := r.Start(t.Context())
	if err != nil || !reexec {
		t.Fatalf("activation: %v %v", reexec, err)
	}
	service.Close()
	assertMetadata("metadata-B")
	service, reexec, err = r.Start(t.Context()) // Crash before readiness restores the entire release.
	if err != nil || !reexec {
		t.Fatalf("rollback: %v %v", reexec, err)
	}
	service.Close()
	assertMetadata("metadata-A")
	path := filepath.Join(source, "DieterPrivacyHelper.app/Contents/MacOS")
	if err := os.Symlink(filepath.Join(path, "dieter-privacy"), filepath.Join(path, "link")); err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(t.Context(), source); err == nil {
		t.Fatal("accepted a link in privacy helper bundle")
	}
}

func TestPrivacyRuntimeAdoptsPreHelperActivation(t *testing.T) {
	for _, acknowledge := range []bool{true, false} {
		t.Run(fmt.Sprint("acknowledge-", acknowledge), func(t *testing.T) {
			legacy := fixtureRuntime(t)
			if err := legacy.Stage(t.Context(), fixturePair(t, "A")); err != nil {
				t.Fatal(err)
			}
			current := fixturePrivacyRuntime(t)
			current.Root = legacy.Root
			source := fixturePrivacyRelease(t, "B")
			if err := current.Stage(t.Context(), source); err != nil {
				t.Fatal(err)
			}
			assertPair(t, legacy, "A")
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
				t.Fatalf("helper takeover: %v %v", reexec, err)
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
				if err := os.WriteFile(current.path("bin/DieterPrivacyHelper.app/Contents/MacOS/dieter-privacy"), []byte("INVALID"), 0755); err != nil {
					t.Fatal(err)
				}
				if err := current.verify(t.Context(), current.path("bin")); err == nil {
					t.Fatal("accepted corrupted privacy helper")
				}
			} else {
				assertPair(t, current, "A")
				if _, err := os.Stat(current.path("bin/DieterPrivacyHelper.app")); !errors.Is(err, os.ErrNotExist) {
					t.Fatal("failed upgrade did not restore original standalone installation")
				}
			}
		})
	}
}

func TestPrivacyRuntimeRejectsMissingOrInvalidHelperBeforeActivation(t *testing.T) {
	r := fixturePrivacyRuntime(t)
	if err := r.Stage(t.Context(), fixturePair(t, "A")); err == nil {
		t.Fatal("accepted incomplete release")
	}
	source := fixturePrivacyRelease(t, "A")
	if err := r.Stage(t.Context(), source); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "DieterPrivacyHelper.app/Contents/MacOS/dieter-privacy"), []byte("INVALID"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := r.Stage(t.Context(), source); err == nil {
		t.Fatal("accepted invalid helper")
	}
	assertPair(t, r, "A")
	if _, err := os.Stat(r.path("pending")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("failed staging left a pending release")
	}
}

func TestHomebrewPrivacyResourceStagesBesideStandaloneBinaries(t *testing.T) {
	source := fixturePrivacyRelease(t, "A")
	prefix := t.TempDir()
	bin := filepath.Join(prefix, "bin")
	libexec := filepath.Join(prefix, "libexec")
	for _, path := range []string{bin, libexec} {
		if err := os.Mkdir(path, 0755); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range executables {
		if err := copyExecutable(filepath.Join(source, name), filepath.Join(bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	if err := copyBundle(filepath.Join(source, "DieterPrivacyHelper.app"), filepath.Join(libexec, "DieterPrivacyHelper.app")); err != nil {
		t.Fatal(err)
	}
	r := fixturePrivacyRuntime(t)
	r.SourceBundlePrefix = "../libexec"
	if err := r.Stage(t.Context(), bin); err != nil {
		t.Fatal(err)
	}
	assertPair(t, r, "A")
	if raw, err := os.ReadFile(r.path("bin/DieterPrivacyHelper.app/Contents/MacOS/dieter-privacy")); err != nil || string(raw) != "A:privacy" {
		t.Fatalf("Homebrew privacy resource: %q %v", raw, err)
	}
	if err := r.Stage(t.Context(), bin); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(r.path("pending")); !os.IsNotExist(err) {
		t.Fatal("Homebrew reinstall staged a new activation")
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
