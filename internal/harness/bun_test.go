//go:build unix

package harness

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnsureManagedBunPublishesAndReusesExactVersion(t *testing.T) {
	commands := t.TempDir()
	trace := filepath.Join(t.TempDir(), "npm.log")
	npm := `#!/bin/sh
set -eu
printf 'install\n' >>"$DIETER_TEST_BUN_TRACE"
mkdir -p node_modules/bun/bin node_modules/.bin
printf '#!/bin/sh\nprintf "1.3.14\\n"\n' >node_modules/bun/bin/bun.exe
chmod 700 node_modules/bun/bin/bun.exe
ln -s ../bun/bin/bun.exe node_modules/.bin/bun
: >node_modules/bun/install.js
`
	if err := os.WriteFile(filepath.Join(commands, "npm"), []byte(npm), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(commands, "node"), []byte("#!/bin/sh\nexit 0\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", commands+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("DIETER_TEST_BUN_TRACE", trace)
	home := t.TempDir()
	first, err := ensureManagedBun(context.Background(), home)
	if err != nil {
		t.Fatal(err)
	}
	second, err := ensureManagedBun(context.Background(), home)
	if err != nil {
		t.Fatal(err)
	}
	if first != second || filepath.Base(first) != ".bin" {
		t.Fatalf("managed Bun paths first=%q second=%q", first, second)
	}
	raw, err := os.ReadFile(trace)
	if err != nil {
		t.Fatal(err)
	}
	if count := len(strings.Fields(string(raw))); count != 1 {
		t.Fatalf("managed Bun installs=%d want 1", count)
	}
}
