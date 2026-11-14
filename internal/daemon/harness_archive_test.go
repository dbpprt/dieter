package daemon

import (
	"io"
	"path/filepath"
	"strings"
	"testing"
)

func TestHarnessRuntimeArchiveWorkerValidatesItsOutput(t *testing.T) {
	t.Parallel()
	if !Handles([]string{"__harness-runtime-archive", "--output", "x"}) {
		t.Fatal("the release builder entry point is not a daemon worker")
	}
	for args, want := range map[string]string{
		"":                        "requires --output PATH",
		"--output":                "flag needs an argument",
		"--output a.tar.gz extra": "requires --output PATH",
		"--output " + filepath.Join(t.TempDir(), "dieter-harness-runtime-plan9-mips.tar.gz"): "harness runtime archive is named dieter-harness-runtime-",
	} {
		err := buildHarnessRuntimeArchive(strings.Fields(args), io.Discard)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("args %q: error=%v want %q", args, err, want)
		}
	}
}
