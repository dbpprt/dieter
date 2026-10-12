//go:build unix

package harness

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dbpprt/dieter/internal/platform/buildinfo"
)

// archiveFixtureCommands puts a fake node on a PATH without npm. It reports a
// supported version and emulates Bun's postinstall by moving the platform
// executable over the placeholder, recording each postinstall in the trace.
func archiveFixtureCommands(t *testing.T) string {
	t.Helper()
	bin := t.TempDir()
	trace := filepath.Join(t.TempDir(), "postinstall.log")
	node := `#!/bin/sh
set -eu
if [ "$1" = "--version" ]; then printf 'v22.19.0\n'; exit 0; fi
if [ "$1" = "node_modules/bun/install.js" ]; then
  printf 'postinstall\n' >>"$DIETER_TEST_POSTINSTALL_TRACE"
  /bin/mv -f node_modules/@oven/bun-test/bin/bun node_modules/bun/bin/bun.exe
  exit 0
fi
exit 2
`
	if err := os.WriteFile(filepath.Join(bin, "node"), []byte(node), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	t.Setenv("DIETER_TEST_POSTINSTALL_TRACE", trace)
	return trace
}

func traceCount(t *testing.T, path string) int {
	t.Helper()
	raw, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return 0
	}
	if err != nil {
		t.Fatal(err)
	}
	return len(strings.Fields(string(raw)))
}

func writeFixtureFile(t *testing.T, path, contents string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), mode); err != nil {
		t.Fatal(err)
	}
}

// fixtureArchiveSources lays out what a release builder installs: the
// runtime's node_modules and the managed Bun package before its postinstall.
func fixtureArchiveSources(t *testing.T) map[string]string {
	t.Helper()
	work := t.TempDir()
	harnessDir, bunDir := filepath.Join(work, "harness"), filepath.Join(work, "bun")
	writeFixtureArchiveTrees(t, harnessDir, bunDir)
	return map[string]string{archiveHarnessTree: harnessDir, archiveBunTree: bunDir}
}

func writeFixtureArchiveTrees(t *testing.T, harnessDir, bunDir string) {
	t.Helper()
	for _, name := range requiredRuntimeFiles {
		if strings.HasPrefix(name, "node_modules/") {
			writeFixtureFile(t, filepath.Join(harnessDir, filepath.FromSlash(name)), "export {};\n", 0o644)
		}
	}
	writeFixtureFile(t, filepath.Join(harnessDir, "node_modules", "tool", "cli.js"), "#!/usr/bin/env node\n", 0o755)
	if err := os.MkdirAll(filepath.Join(harnessDir, "node_modules", ".bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../tool/cli.js", filepath.Join(harnessDir, "node_modules", ".bin", "tool")); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(harnessDir, "node_modules", "empty"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeFixtureFile(t, filepath.Join(bunDir, "package.json"), "{}\n", 0o600)
	writeFixtureFile(t, filepath.Join(bunDir, "node_modules", "bun", "install.js"), "// postinstall\n", 0o644)
	writeFixtureFile(t, filepath.Join(bunDir, "node_modules", "bun", "bin", "bun.exe"), "#!/bin/sh\nexit 1\n", 0o755)
	writeFixtureFile(t, filepath.Join(bunDir, "node_modules", "@oven", "bun-test", "bin", "bun"), "#!/bin/sh\nprintf '"+managedBunVersion+"\\n'\n", 0o755)
	if err := os.MkdirAll(filepath.Join(bunDir, "node_modules", ".bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../bun/bin/bun.exe", filepath.Join(bunDir, "node_modules", ".bin", "bun")); err != nil {
		t.Fatal(err)
	}
}

func fixtureArchive(t *testing.T, mutate func(*runtimeArchiveManifest)) []byte {
	t.Helper()
	manifest := currentRuntimeArchiveManifest()
	if mutate != nil {
		mutate(&manifest)
	}
	var archive bytes.Buffer
	if err := writeRuntimeArchive(&archive, manifest, fixtureArchiveSources(t)); err != nil {
		t.Fatal(err)
	}
	return archive.Bytes()
}

type archiveEntry struct {
	header   tar.Header
	contents string
}

// rawArchive writes entries verbatim after a valid manifest, for archives no
// builder would produce.
func rawArchive(t *testing.T, entries ...archiveEntry) []byte {
	t.Helper()
	var buffer bytes.Buffer
	compressed := gzip.NewWriter(&buffer)
	archive := tar.NewWriter(compressed)
	manifest, err := json.Marshal(currentRuntimeArchiveManifest())
	if err != nil {
		t.Fatal(err)
	}
	all := append([]archiveEntry{{header: tar.Header{Name: runtimeArchiveManifestName, Typeflag: tar.TypeReg, Mode: 0o644}, contents: string(manifest)}}, entries...)
	for _, entry := range all {
		header := entry.header
		if header.Typeflag == tar.TypeReg {
			header.Size = int64(len(entry.contents))
		}
		if err := archive.WriteHeader(&header); err != nil {
			t.Fatal(err)
		}
		if _, err := archive.Write([]byte(entry.contents)); err != nil {
			t.Fatal(err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	if err := compressed.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

type archiveServer struct {
	archive   RuntimeArchive
	downloads atomic.Int32
}

// serveArchive publishes body as this platform's archive on a TLS test server
// and pins its SHA-256. handler, when set, replaces the default response.
func serveArchive(t *testing.T, body []byte, handler func(http.ResponseWriter, *http.Request)) *archiveServer {
	t.Helper()
	server := &archiveServer{}
	sum := sha256.Sum256(body)
	asset := "/releases/download/v1.2.3/" + RuntimeArchiveName(runtime.GOOS, runtime.GOARCH)
	tls := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path != asset {
			http.NotFound(writer, request)
			return
		}
		server.downloads.Add(1)
		if handler != nil {
			handler(writer, request)
			return
		}
		_, _ = writer.Write(body)
	}))
	t.Cleanup(tls.Close)
	server.archive = RuntimeArchive{BaseURL: tls.URL + "/releases/download/v1.2.3/", SHA256: hex.EncodeToString(sum[:]), Client: tls.Client()}
	return server
}

func assertNoStagingLeftovers(t *testing.T, dirs ...string) {
	t.Helper()
	for _, dir := range dirs {
		entries, err := os.ReadDir(dir)
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		for _, entry := range entries {
			if name := entry.Name(); strings.HasPrefix(name, ".stage-") || strings.HasPrefix(name, ".download-") || strings.HasPrefix(name, ".corrupt-") {
				t.Fatalf("installer left %s in %s", name, dir)
			}
		}
	}
}

func TestPrepareRuntimeInstallsPinnedArchiveWithoutNPM(t *testing.T) {
	postinstalls := archiveFixtureCommands(t)
	server := serveArchive(t, fixtureArchive(t, nil), nil)
	home := t.TempDir()
	reference, err := NewSubprocessRunner(home, Environment{RuntimeArchive: server.archive}).PrepareRuntime(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	if reference.Digest != embeddedRuntimeDigest() || reference.Directory != filepath.Join(home, "runtime", "harness", reference.Digest) {
		t.Fatalf("reference=%#v", reference)
	}
	if err := validateRuntimeDirectory(reference.Directory, reference.Digest); err != nil {
		t.Fatal(err)
	}
	if target, err := os.Readlink(filepath.Join(reference.Directory, "node_modules", ".bin", "tool")); err != nil || target != "../tool/cli.js" {
		t.Fatalf("runtime bin link=%q err=%v", target, err)
	}
	if info, err := os.Stat(filepath.Join(reference.Directory, "node_modules", "tool", "cli.js")); err != nil || info.Mode()&0o100 == 0 {
		t.Fatalf("executable bit lost: info=%v err=%v", info, err)
	}
	bunBin, err := validateManagedBun(context.Background(), filepath.Join(home, "runtime", "tools", "bun", managedBunVersion))
	if err != nil {
		t.Fatalf("managed Bun from the archive: %v", err)
	}
	if got, err := ensureManagedBun(context.Background(), home, server.archive); err != nil || got != bunBin {
		t.Fatalf("ensureManagedBun=%q err=%v want %q", got, err, bunBin)
	}
	if downloads, count := server.downloads.Load(), traceCount(t, postinstalls); downloads != 1 || count != 1 {
		t.Fatalf("downloads=%d postinstalls=%d want 1 each", downloads, count)
	}
	// A prepared runtime is reused without another download.
	if again, err := NewSubprocessRunner(home, Environment{RuntimeArchive: server.archive}).PrepareRuntime(context.Background(), ""); err != nil || again != reference {
		t.Fatalf("again=%#v err=%v", again, err)
	}
	if downloads := server.downloads.Load(); downloads != 1 {
		t.Fatalf("downloads=%d want 1", downloads)
	}
	assertNoStagingLeftovers(t, filepath.Join(home, "runtime", "harness"), filepath.Join(home, "runtime", "tools", "bun"))
}

func TestPrepareRuntimeInstallsPinnedArchiveOnceAcrossConcurrentRunners(t *testing.T) {
	postinstalls := archiveFixtureCommands(t)
	server := serveArchive(t, fixtureArchive(t, nil), nil)
	home := t.TempDir()
	references := make([]RuntimeReference, 4)
	errs := make([]error, len(references))
	var group sync.WaitGroup
	for index := range references {
		group.Add(1)
		go func() {
			defer group.Done()
			references[index], errs[index] = NewSubprocessRunner(home, Environment{RuntimeArchive: server.archive}).PrepareRuntime(context.Background(), "")
		}()
	}
	group.Wait()
	for index, err := range errs {
		if err != nil {
			t.Fatal(err)
		}
		if references[index] != references[0] {
			t.Fatalf("references=%#v", references)
		}
	}
	if downloads, count := server.downloads.Load(), traceCount(t, postinstalls); downloads != 1 || count != 1 {
		t.Fatalf("downloads=%d postinstalls=%d want 1 each", downloads, count)
	}
	assertNoStagingLeftovers(t, filepath.Join(home, "runtime", "harness"), filepath.Join(home, "runtime", "tools", "bun"))
}

func TestEnsureManagedBunRestoresFromPinnedArchive(t *testing.T) {
	postinstalls := archiveFixtureCommands(t)
	server := serveArchive(t, fixtureArchive(t, nil), nil)
	home := t.TempDir()
	bin, err := ensureManagedBun(context.Background(), home, server.archive)
	if err != nil {
		t.Fatal(err)
	}
	if bin != filepath.Join(home, "runtime", "tools", "bun", managedBunVersion, "node_modules", ".bin") {
		t.Fatalf("bin=%q", bin)
	}
	if _, err := os.Lstat(filepath.Join(home, "runtime", "harness")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("restoring Bun installed a harness runtime: %v", err)
	}
	if downloads, count := server.downloads.Load(), traceCount(t, postinstalls); downloads != 1 || count != 1 {
		t.Fatalf("downloads=%d postinstalls=%d", downloads, count)
	}
	assertNoStagingLeftovers(t, filepath.Join(home, "runtime", "tools", "bun"))
}

func TestPrepareRuntimeRejectsUnverifiedArchives(t *testing.T) {
	valid := fixtureArchive(t, nil)
	cases := []struct {
		name    string
		body    []byte
		sha256  string
		handler func(http.ResponseWriter, *http.Request)
		want    string
	}{
		{name: "wrong SHA-256", body: valid, sha256: strings.Repeat("0", 64), want: "SHA-256 of the"},
		{name: "invalid pin", body: valid, sha256: "abc", want: "is invalid"},
		{name: "missing asset", body: valid, handler: func(writer http.ResponseWriter, request *http.Request) {
			http.Error(writer, "gone", http.StatusNotFound)
		}, want: "HTTP 404"},
		{name: "truncated", body: valid, handler: func(writer http.ResponseWriter, request *http.Request) {
			writer.Header().Set("Content-Length", strconv.Itoa(len(valid)))
			_, _ = writer.Write(valid[:len(valid)/2])
		}, want: "unexpected EOF"},
		{name: "declared oversized", body: valid, handler: func(writer http.ResponseWriter, request *http.Request) {
			writer.Header().Set("Content-Length", strconv.Itoa(len(valid)+4096))
			_, _ = writer.Write(valid)
			_, _ = writer.Write(make([]byte, 4096))
		}, want: "the limit is"},
		{name: "streamed oversized", body: valid, handler: func(writer http.ResponseWriter, request *http.Request) {
			for range 4 {
				_, _ = writer.Write(valid)
				writer.(http.Flusher).Flush()
			}
		}, want: "exceeds"},
		{name: "runtime digest mismatch", body: fixtureArchive(t, func(manifest *runtimeArchiveManifest) {
			manifest.RuntimeDigest = strings.Repeat("a", 64)
		}), want: "built from harness runtime"},
		{name: "lockfile mismatch", body: fixtureArchive(t, func(manifest *runtimeArchiveManifest) {
			manifest.PackageLockSHA256 = strings.Repeat("b", 64)
		}), want: "built from package-lock.json"},
		{name: "other platform", body: fixtureArchive(t, func(manifest *runtimeArchiveManifest) {
			manifest.Platform = "plan9-mips"
		}), want: "archive is for plan9-mips"},
		{name: "other Bun", body: fixtureArchive(t, func(manifest *runtimeArchiveManifest) {
			manifest.BunVersion = "0.0.1"
		}), want: "carries Bun 0.0.1"},
	}
	limit := maxRuntimeArchiveBytes
	maxRuntimeArchiveBytes = int64(len(valid) + 1024)
	t.Cleanup(func() { maxRuntimeArchiveBytes = limit })
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			archiveFixtureCommands(t)
			server := serveArchive(t, test.body, test.handler)
			if test.sha256 != "" {
				server.archive.SHA256 = test.sha256
			}
			home := t.TempDir()
			_, err := NewSubprocessRunner(home, Environment{RuntimeArchive: server.archive}).PrepareRuntime(context.Background(), "")
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error=%v want %q", err, test.want)
			}
			t.Log(err)
			if _, statErr := os.Lstat(filepath.Join(home, "runtime", "harness", embeddedRuntimeDigest())); !errors.Is(statErr, fs.ErrNotExist) {
				t.Fatalf("a rejected archive published a runtime: %v", statErr)
			}
			assertNoStagingLeftovers(t, filepath.Join(home, "runtime", "harness"), filepath.Join(home, "runtime", "tools", "bun"))
		})
	}
}

func TestRuntimeArchiveURLRules(t *testing.T) {
	for raw, allowed := range map[string]bool{
		"https://github.com/dbpprt/dieter/releases/download/v1/x": true,
		"http://127.0.0.1:8080/x":                                 true,
		"http://[::1]:8080/x":                                     true,
		"http://example.com/x":                                    false,
		"http://localhost/x":                                      false,
		"ftp://127.0.0.1/x":                                       false,
		"https://user:secret@github.com/x":                        false,
		"/relative":                                               false,
	} {
		if err := checkRuntimeArchiveURL(raw); (err == nil) != allowed {
			t.Errorf("checkRuntimeArchiveURL(%q) = %v, allowed %v", raw, err, allowed)
		}
	}
	// Redirects are held to the same rules.
	insecure := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		http.Redirect(writer, request, "http://example.invalid/archive.tar.gz", http.StatusFound)
	}))
	defer insecure.Close()
	_, err := downloadRuntimeArchive(context.Background(), RuntimeArchive{BaseURL: insecure.URL, SHA256: strings.Repeat("0", 64)}, t.TempDir())
	if err == nil || !strings.Contains(err.Error(), "must use HTTPS") {
		t.Fatalf("redirect to plain HTTP error=%v", err)
	}
}

func TestReleaseRuntimeArchiveComesFromBuildInfo(t *testing.T) {
	if pinned := ReleaseRuntimeArchive(); pinned.pinned() {
		t.Fatalf("source builds must not pin a runtime archive: %#v", pinned)
	}
	if (Environment{}).runtimeArchive().pinned() {
		t.Fatal("a zero environment pins an archive in a source build")
	}
	version, sum, base := buildinfo.ReleaseVersion, buildinfo.HarnessRuntimeSHA256, buildinfo.HarnessRuntimeBaseURL
	t.Cleanup(func() {
		buildinfo.ReleaseVersion, buildinfo.HarnessRuntimeSHA256, buildinfo.HarnessRuntimeBaseURL = version, sum, base
	})
	buildinfo.ReleaseVersion, buildinfo.HarnessRuntimeSHA256 = "0.5.999", strings.Repeat("c", 64)
	want := RuntimeArchive{BaseURL: buildinfo.ReleasesURL + "/download/v0.5.999", SHA256: strings.Repeat("c", 64)}
	if got := (Environment{}).runtimeArchive(); got != want {
		t.Fatalf("release archive=%#v want %#v", got, want)
	}
	buildinfo.HarnessRuntimeBaseURL = "http://127.0.0.1:9/e2e"
	if got := ReleaseRuntimeArchive(); got.BaseURL != "http://127.0.0.1:9/e2e" {
		t.Fatalf("base URL override=%#v", got)
	}
	explicit := RuntimeArchive{BaseURL: "https://mirror.test/x", SHA256: strings.Repeat("d", 64)}
	if got := (Environment{RuntimeArchive: explicit}).runtimeArchive(); got != explicit {
		t.Fatalf("explicit archive=%#v", got)
	}
}

func TestPrepareRuntimeWithoutPinnedArchiveUsesNPM(t *testing.T) {
	trace := installFixtureCommands(t)
	server := serveArchive(t, fixtureArchive(t, nil), nil)
	unpinned := server.archive
	unpinned.SHA256 = ""
	reference, err := NewSubprocessRunner(t.TempDir(), Environment{RuntimeArchive: unpinned}).PrepareRuntime(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	if err := validateRuntimeDirectory(reference.Directory, reference.Digest); err != nil {
		t.Fatal(err)
	}
	if installs, downloads := installCount(t, trace), server.downloads.Load(); installs != 1 || downloads != 0 {
		t.Fatalf("npm installs=%d downloads=%d", installs, downloads)
	}
}

func TestPrepareRuntimeOverrideIgnoresPinnedArchive(t *testing.T) {
	archiveFixtureCommands(t)
	server := serveArchive(t, fixtureArchive(t, nil), nil)
	override := t.TempDir()
	writeFixtureFile(t, filepath.Join(override, "runner.mjs"), "", 0o644)
	reference, err := NewSubprocessRunner(t.TempDir(), Environment{RuntimeDir: override, RuntimeArchive: server.archive}).PrepareRuntime(context.Background(), "")
	if err != nil || reference.Digest != "override" {
		t.Fatalf("reference=%#v err=%v", reference, err)
	}
	if downloads := server.downloads.Load(); downloads != 0 {
		t.Fatalf("downloads=%d", downloads)
	}
}

func extractRawArchive(t *testing.T, body []byte, tree string) (string, error) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "archive.tar.gz")
	if err := os.WriteFile(path, body, 0o600); err != nil {
		t.Fatal(err)
	}
	dest := filepath.Join(t.TempDir(), "dest")
	if err := os.Mkdir(dest, 0o700); err != nil {
		t.Fatal(err)
	}
	return dest, extractRuntimeArchive(path, tree, dest)
}

func TestExtractRuntimeArchiveRejectsUnsafeEntries(t *testing.T) {
	file := func(name string) archiveEntry {
		return archiveEntry{header: tar.Header{Name: name, Typeflag: tar.TypeReg, Mode: 0o644}, contents: "x"}
	}
	link := func(name, target string) archiveEntry {
		return archiveEntry{header: tar.Header{Name: name, Typeflag: tar.TypeSymlink, Linkname: target, Mode: 0o777}}
	}
	dir := func(name string) archiveEntry {
		return archiveEntry{header: tar.Header{Name: name, Typeflag: tar.TypeDir, Mode: 0o755}}
	}
	cases := map[string][]archiveEntry{
		"parent traversal":          {file("harness/node_modules/../../evil")},
		"leading traversal":         {file("../evil")},
		"absolute path":             {file("/tmp/evil")},
		"unclean path":              {file("harness/node_modules//evil")},
		"unknown tree":              {file("other/node_modules/x")},
		"runtime source":            {file("harness/runner.mjs")},
		"tree root file":            {file("harness")},
		"escaping link":             {link("harness/node_modules/x", "../../../outside")},
		"absolute link":             {link("harness/node_modules/x", "/etc/passwd")},
		"unclean link":              {link("harness/node_modules/.bin/x", "../a/../../../outside")},
		"write through link":        {link("harness/node_modules/x", "."), file("harness/node_modules/x/evil")},
		"directory over link":       {link("harness/node_modules/x", "y"), dir("harness/node_modules/x/")},
		"hard link":                 {{header: tar.Header{Name: "harness/node_modules/x", Typeflag: tar.TypeLink, Linkname: "harness/node_modules/y"}}},
		"character device":          {{header: tar.Header{Name: "harness/node_modules/x", Typeflag: tar.TypeChar, Mode: 0o644}}},
		"fifo":                      {{header: tar.Header{Name: "harness/node_modules/x", Typeflag: tar.TypeFifo, Mode: 0o644}}},
		"duplicate file":            {file("harness/node_modules/x"), file("harness/node_modules/x")},
		"escaping link, other tree": {link("bun/node_modules/x", "../../x")},
	}
	for name, entries := range cases {
		t.Run(name, func(t *testing.T) {
			dest, err := extractRawArchive(t, rawArchive(t, entries...), archiveHarnessTree)
			if err == nil {
				t.Fatal("unsafe archive extracted")
			}
			t.Log(err)
			if _, statErr := os.Lstat(filepath.Join(filepath.Dir(dest), "evil")); !errors.Is(statErr, fs.ErrNotExist) {
				t.Fatalf("archive wrote outside its destination: %v", statErr)
			}
		})
	}
	t.Run("manifest first", func(t *testing.T) {
		var buffer bytes.Buffer
		compressed := gzip.NewWriter(&buffer)
		archive := tar.NewWriter(compressed)
		if err := archive.WriteHeader(&tar.Header{Name: "harness/node_modules/x", Typeflag: tar.TypeReg, Mode: 0o644}); err != nil {
			t.Fatal(err)
		}
		_ = archive.Close()
		_ = compressed.Close()
		if _, err := extractRawArchive(t, buffer.Bytes(), archiveHarnessTree); err == nil || !strings.Contains(err.Error(), "manifest") {
			t.Fatalf("error=%v", err)
		}
	})
	t.Run("expanded size bound", func(t *testing.T) {
		limit := maxRuntimeArchiveExpanded
		maxRuntimeArchiveExpanded = 8
		t.Cleanup(func() { maxRuntimeArchiveExpanded = limit })
		big := archiveEntry{header: tar.Header{Name: "harness/node_modules/big", Typeflag: tar.TypeReg, Mode: 0o644}, contents: strings.Repeat("z", 9)}
		if _, err := extractRawArchive(t, rawArchive(t, big), archiveHarnessTree); err == nil || !strings.Contains(err.Error(), "expands beyond") {
			t.Fatalf("error=%v", err)
		}
	})
	t.Run("links inside the tree", func(t *testing.T) {
		dest, err := extractRawArchive(t, rawArchive(t,
			file("harness/node_modules/pkg/cli.js"),
			link("harness/node_modules/.bin/pkg", "../pkg/cli.js"),
			link("harness/node_modules/self", "."),
		), archiveHarnessTree)
		if err != nil {
			t.Fatal(err)
		}
		if raw, err := os.ReadFile(filepath.Join(dest, "node_modules", ".bin", "pkg")); err != nil || string(raw) != "x" {
			t.Fatalf("link contents=%q err=%v", raw, err)
		}
	})
}

// treeSnapshot describes every entry under dir: type, executable bit, link
// target and contents.
func treeSnapshot(t *testing.T, dir string) map[string]string {
	t.Helper()
	snapshot := map[string]string{}
	err := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		relative, _ := filepath.Rel(dir, path)
		info, err := entry.Info()
		if err != nil {
			return err
		}
		switch {
		case info.IsDir():
			snapshot[relative] = "dir"
		case info.Mode()&fs.ModeSymlink != 0:
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			snapshot[relative] = "link " + target
		default:
			raw, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			snapshot[relative] = "file exec=" + map[bool]string{true: "yes", false: "no"}[info.Mode()&0o111 != 0] + " " + string(raw)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func TestRuntimeArchiveRoundTripIsDeterministic(t *testing.T) {
	sources := fixtureArchiveSources(t)
	manifest := currentRuntimeArchiveManifest()
	var first bytes.Buffer
	if err := writeRuntimeArchive(&first, manifest, sources); err != nil {
		t.Fatal(err)
	}
	// Identical trees with other timestamps and permissions archive to the
	// same bytes.
	stamp := time.Date(2031, time.March, 4, 5, 6, 7, 0, time.UTC)
	for _, dir := range sources {
		if err := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
			if err != nil || entry.Type()&fs.ModeSymlink != 0 {
				return err
			}
			if !entry.IsDir() {
				info, _ := entry.Info()
				mode := os.FileMode(0o600)
				if info.Mode()&0o111 != 0 {
					mode = 0o700
				}
				if err := os.Chmod(path, mode); err != nil {
					return err
				}
			}
			return os.Chtimes(path, stamp, stamp)
		}); err != nil {
			t.Fatal(err)
		}
	}
	var second bytes.Buffer
	if err := writeRuntimeArchive(&second, manifest, sources); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first.Bytes(), second.Bytes()) {
		t.Fatal("identical runtime trees produced different archives")
	}

	reader := tar.NewReader(mustGunzip(t, first.Bytes()))
	var names []string
	for {
		header, err := reader.Next()
		if err != nil {
			break
		}
		if header.Uid != 0 || header.Gid != 0 || header.Uname != "" || header.Gname != "" || !header.ModTime.Equal(runtimeArchiveEpoch) {
			t.Fatalf("entry %s is not normalized: %#v", header.Name, header)
		}
		names = append(names, header.Name)
	}
	if len(names) == 0 || names[0] != runtimeArchiveManifestName || !strings.HasPrefix(names[1], "bun/") || !strings.HasPrefix(names[len(names)-1], "harness/") {
		t.Fatalf("archive order=%q", names)
	}

	for tree, source := range sources {
		dest, err := extractRawArchive(t, first.Bytes(), tree)
		if err != nil {
			t.Fatal(err)
		}
		want := treeSnapshot(t, source)
		for name := range want {
			top, _, _ := strings.Cut(name, string(filepath.Separator))
			if name == "." || !slices.Contains(runtimeArchiveRoots[tree], top) {
				delete(want, name)
			}
		}
		got := treeSnapshot(t, dest)
		delete(got, ".")
		if len(got) != len(want) {
			t.Fatalf("%s round trip has %d entries, want %d:\n%v\n%v", tree, len(got), len(want), got, want)
		}
		for name, value := range want {
			if got[name] != value {
				t.Fatalf("%s round trip %s=%q want %q", tree, name, got[name], value)
			}
		}
	}
}

func TestWriteRuntimeArchiveRejectsEscapingLinks(t *testing.T) {
	sources := fixtureArchiveSources(t)
	if err := os.Symlink("../../../outside", filepath.Join(sources[archiveHarnessTree], "node_modules", "escape")); err != nil {
		t.Fatal(err)
	}
	if err := writeRuntimeArchive(&bytes.Buffer{}, currentRuntimeArchiveManifest(), sources); err == nil || !strings.Contains(err.Error(), "escapes") {
		t.Fatalf("error=%v", err)
	}
}

func mustGunzip(t *testing.T, body []byte) *gzip.Reader {
	t.Helper()
	reader, err := gzip.NewReader(bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	return reader
}

// nodeHost names this platform as Node does in its native package names.
func nodeHost() string {
	arch := runtime.GOARCH
	if arch == "amd64" {
		arch = "x64"
	}
	return runtime.GOOS + "-" + arch
}

// writeFixtureAgents installs stand-ins for the agent CLIs and this host's
// native packages: each executable reports its version like the real one.
func writeFixtureAgents(t *testing.T, harnessDir string) {
	t.Helper()
	modules := filepath.Join(harnessDir, "node_modules")
	write := func(name, contents string, mode os.FileMode) {
		path := filepath.Join(modules, filepath.FromSlash(name))
		_ = os.Remove(path)
		writeFixtureFile(t, path, contents, mode)
	}
	write("@anthropic-ai/claude-agent-sdk/package.json", `{"name":"@anthropic-ai/claude-agent-sdk","version":"0.9.9","claudeCodeVersion":"9.9.9"}`, 0o644)
	claudeNatives := []string{"@anthropic-ai/claude-agent-sdk-" + nodeHost()}
	if runtime.GOOS == "linux" {
		// npm installs both libc variants on Linux; the check picks the host's.
		claudeNatives = append(claudeNatives, claudeNatives[0]+"-musl")
	}
	for _, native := range claudeNatives {
		write(native+"/package.json", `{"version":"0.9.9"}`, 0o644)
		write(native+"/claude", "#!/bin/sh\nprintf '9.9.9 (Claude Code)\\n'\n", 0o755)
	}
	write("@openai/codex/package.json", `{"name":"@openai/codex","version":"1.2.3"}`, 0o644)
	write("@openai/codex/bin/codex.js", "console.log('codex-cli 1.2.3');\n", 0o644)
	write("@openai/codex-"+nodeHost()+"/package.json", `{"version":"1.2.3"}`, 0o644)
	write("@oh-my-pi/pi-coding-agent/package.json", `{"name":"@oh-my-pi/pi-coding-agent","version":"7.8.9","bin":{"omp":"dist/cli.js"}}`, 0o644)
	write("@oh-my-pi/pi-coding-agent/dist/cli.js", "#!/bin/sh\nprintf 'omp/7.8.9\\n'\n", 0o755)
	write("@oh-my-pi/pi-natives/package.json", `{"version":"7.8.9"}`, 0o644)
	write("@oh-my-pi/pi-natives-"+nodeHost()+"/package.json", `{"version":"7.8.9"}`, 0o644)
	if err := os.Symlink("../@oh-my-pi/pi-coding-agent/dist/cli.js", filepath.Join(modules, ".bin", "omp")); err != nil {
		t.Fatal(err)
	}
}

// archiveBuildFixtureCommands is archiveFixtureCommands with a node that runs
// every other script with the real Node.js, for the runtime's agent check.
func archiveBuildFixtureCommands(t *testing.T) {
	t.Helper()
	realNode, err := exec.LookPath("node")
	if err != nil {
		t.Skip("Node.js is not installed")
	}
	archiveFixtureCommands(t)
	bin := filepath.SplitList(os.Getenv("PATH"))[0]
	node := `#!/bin/sh
set -eu
if [ "$1" = "--version" ]; then printf 'v22.19.0\n'; exit 0; fi
if [ "$1" = "node_modules/bun/install.js" ]; then
  /bin/mv -f node_modules/@oven/bun-test/bin/bun node_modules/bun/bin/bun.exe
  exit 0
fi
exec ` + realNode + ` "$@"
`
	if err := os.WriteFile(filepath.Join(bin, "node"), []byte(node), 0o700); err != nil {
		t.Fatal(err)
	}
}

func TestBuildRuntimeArchiveVerifiesEveryAgentCLI(t *testing.T) {
	archiveBuildFixtureCommands(t)
	output := filepath.Join(t.TempDir(), RuntimeArchiveName(runtime.GOOS, runtime.GOARCH))
	info, err := buildRuntimeArchive(context.Background(), output, func(_ context.Context, sources map[string]string) error {
		writeFixtureArchiveTrees(t, sources[archiveHarnessTree], sources[archiveBunTree])
		writeFixtureAgents(t, sources[archiveHarnessTree])
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]RuntimeAgent{
		"claude": {Package: "@anthropic-ai/claude-agent-sdk", PackageVersion: "0.9.9", Version: "9.9.9", Native: "@anthropic-ai/claude-agent-sdk-" + nodeHost()},
		"codex":  {Package: "@openai/codex", PackageVersion: "1.2.3", Version: "1.2.3", Native: "@openai/codex-" + nodeHost()},
		"omp":    {Package: "@oh-my-pi/pi-coding-agent", PackageVersion: "7.8.9", Version: "7.8.9", Native: "@oh-my-pi/pi-natives-" + nodeHost()},
	}
	if len(info.Agents) != len(want) {
		t.Fatalf("agents=%#v", info.Agents)
	}
	for name, agent := range want {
		if info.Agents[name] != agent {
			t.Fatalf("%s=%#v want %#v", name, info.Agents[name], agent)
		}
	}
	if stat, err := os.Stat(output); err != nil || stat.Size() != info.Size {
		t.Fatalf("archive stat=%v err=%v info=%#v", stat, err, info)
	}
}

func TestBuildRuntimeArchiveRejectsAMissingNativeAgentPackage(t *testing.T) {
	archiveBuildFixtureCommands(t)
	output := filepath.Join(t.TempDir(), RuntimeArchiveName(runtime.GOOS, runtime.GOARCH))
	_, err := buildRuntimeArchive(context.Background(), output, func(_ context.Context, sources map[string]string) error {
		writeFixtureArchiveTrees(t, sources[archiveHarnessTree], sources[archiveBunTree])
		writeFixtureAgents(t, sources[archiveHarnessTree])
		matches, _ := filepath.Glob(filepath.Join(sources[archiveHarnessTree], "node_modules", "@anthropic-ai", "claude-agent-sdk-*"))
		for _, match := range matches {
			if err := os.RemoveAll(match); err != nil {
				return err
			}
		}
		return nil
	})
	if err == nil || !strings.Contains(err.Error(), "verify the archive's agent CLIs: Claude Code needs @anthropic-ai/claude-agent-sdk-"+nodeHost()) {
		t.Fatalf("error=%v", err)
	}
	if _, statErr := os.Stat(output); !errors.Is(statErr, fs.ErrNotExist) {
		t.Fatalf("a failed build published %s: %v", output, statErr)
	}
}

func TestBuildRuntimeArchiveRefusesAnArchiveDaemonsWouldReject(t *testing.T) {
	archiveBuildFixtureCommands(t)
	limit := maxRuntimeArchiveBytes
	maxRuntimeArchiveBytes = 1024
	t.Cleanup(func() { maxRuntimeArchiveBytes = limit })
	output := filepath.Join(t.TempDir(), RuntimeArchiveName(runtime.GOOS, runtime.GOARCH))
	_, err := buildRuntimeArchive(context.Background(), output, func(_ context.Context, sources map[string]string) error {
		writeFixtureArchiveTrees(t, sources[archiveHarnessTree], sources[archiveBunTree])
		writeFixtureAgents(t, sources[archiveHarnessTree])
		return nil
	})
	if err == nil || !strings.Contains(err.Error(), "release daemons download at most 1024") {
		t.Fatalf("error=%v", err)
	}
	if _, statErr := os.Stat(output); !errors.Is(statErr, fs.ErrNotExist) {
		t.Fatalf("an oversized build published %s: %v", output, statErr)
	}
}
