package testkit

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/dbpprt/dieter/internal/harness"
)

// MockCatalog is the static release catalog with the deterministic mock
// harness enabled. It never discovers providers or installs runtimes.
func MockCatalog() *harness.Catalog { return harness.StaticCatalog(true) }

// RuntimeSource returns the harness runtime source directory of this checkout,
// skipping the test when Node or the runtime's dependencies are unavailable
// (install them with `npm --prefix internal/harness/runtime ci`).
func RuntimeSource(tb testing.TB) string {
	tb.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		tb.Fatal("cannot locate the testkit source")
	}
	directory := filepath.Join(filepath.Dir(file), "..", "harness", "runtime")
	if _, err := exec.LookPath("node"); err != nil {
		tb.Skip("node is not installed")
	}
	if _, err := os.Stat(filepath.Join(directory, "node_modules")); err != nil {
		tb.Skip("local harness dependencies are not installed")
	}
	return directory
}

// MockHarness returns the real subprocess runner for the Dieter home root,
// running the checkout's harness runtime, and the mock catalog. Turns with
// the "mock" harness complete deterministically without provider credentials.
func MockHarness(tb testing.TB, root string) (*harness.SubprocessRunner, *harness.Catalog) {
	tb.Helper()
	return harness.NewSubprocessRunner(root, harness.Environment{RuntimeDir: RuntimeSource(tb)}), MockCatalog()
}
