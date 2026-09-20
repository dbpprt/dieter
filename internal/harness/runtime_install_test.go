//go:build unix

package harness

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

func installFixtureCommands(t *testing.T) string {
	t.Helper()
	bin := t.TempDir()
	trace := filepath.Join(t.TempDir(), "npm.log")
	if err := os.WriteFile(filepath.Join(bin, "node"), []byte("#!/bin/sh\nprintf 'v22.19.0\\n'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	var npm strings.Builder
	npm.WriteString("#!/bin/sh\nprintf 'install\\n' >>\"$DIETER_TEST_NPM_TRACE\"\n")
	for _, name := range requiredRuntimeFiles {
		if !strings.HasPrefix(name, "node_modules/") {
			continue
		}
		npm.WriteString("mkdir -p \"")
		npm.WriteString(filepath.Dir(name))
		npm.WriteString("\"\nprintf installed >\"")
		npm.WriteString(name)
		npm.WriteString("\"\n")
	}
	if err := os.WriteFile(filepath.Join(bin, "npm"), []byte(npm.String()), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("DIETER_TEST_NPM_TRACE", trace)
	return trace
}

func installCount(t *testing.T, path string) int {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return len(strings.Fields(string(raw)))
}

func TestRuntimeDigestCoversEveryEmbeddedSource(t *testing.T) {
	names := embeddedRuntimeSourceFiles()
	baseline, err := runtimeSourceDigest(names, func(name string) ([]byte, error) {
		return runtimeAssets.ReadFile("runtime/" + name)
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, changed := range names {
		changed := changed
		digest, digestErr := runtimeSourceDigest(names, func(name string) ([]byte, error) {
			contents, readErr := runtimeAssets.ReadFile("runtime/" + name)
			if name == changed {
				contents = append(contents, '\n')
			}
			return contents, readErr
		})
		if digestErr != nil {
			t.Fatal(digestErr)
		}
		if digest == baseline {
			t.Fatalf("changing embedded runtime source %q did not change its digest", changed)
		}
	}
}

func TestPrepareRuntimePublishesOneCompleteImmutableInstall(t *testing.T) {
	trace := installFixtureCommands(t)
	root := t.TempDir()
	runners := []*SubprocessRunner{NewSubprocessRunner(root), NewSubprocessRunner(root)}
	references := make([]RuntimeReference, len(runners))
	errorsByRunner := make([]error, len(runners))
	var group sync.WaitGroup
	for index, runner := range runners {
		group.Add(1)
		go func() {
			defer group.Done()
			references[index], errorsByRunner[index] = runner.PrepareRuntime(context.Background(), "")
		}()
	}
	group.Wait()
	for _, err := range errorsByRunner {
		if err != nil {
			t.Fatal(err)
		}
	}
	if references[0].Digest == "" || references[0] != references[1] {
		t.Fatalf("runtime references=%#v", references)
	}
	if count := installCount(t, trace); count != 1 {
		t.Fatalf("npm installs=%d want 1", count)
	}
	if err := validateRuntimeDirectory(references[0].Directory, references[0].Digest); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Dir(references[0].Directory))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".stage-") || strings.HasPrefix(entry.Name(), ".corrupt-") {
			t.Fatalf("installer left temporary runtime %q", entry.Name())
		}
	}
}

func TestPrepareRuntimeRepairsPoisonedCurrentAndReopensHistorical(t *testing.T) {
	trace := installFixtureCommands(t)
	root := t.TempDir()
	reference, err := NewSubprocessRunner(root).PrepareRuntime(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(reference.Directory, filepath.FromSlash(requiredRuntimeFiles[len(requiredRuntimeFiles)-1]))); err != nil {
		t.Fatal(err)
	}
	repaired, err := NewSubprocessRunner(root).PrepareRuntime(context.Background(), "")
	if err != nil {
		t.Fatal(err)
	}
	if repaired != reference {
		t.Fatalf("repaired reference=%#v want %#v", repaired, reference)
	}
	if count := installCount(t, trace); count != 2 {
		t.Fatalf("npm installs=%d want 2", count)
	}

	runnerPath := filepath.Join(repaired.Directory, "runner.mjs")
	rawRunner, err := os.ReadFile(runnerPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(runnerPath, append(rawRunner, []byte("\n// historical fixture\n")...), 0o600); err != nil {
		t.Fatal(err)
	}
	sourceFiles := embeddedRuntimeSourceFiles()
	historicalDigest, err := runtimeSourceDigest(sourceFiles, func(name string) ([]byte, error) {
		return os.ReadFile(filepath.Join(repaired.Directory, name))
	})
	if err != nil {
		t.Fatal(err)
	}
	manifest, err := json.Marshal(runtimeManifest{Digest: historicalDigest, ProtocolVersion: RuntimeProtocolVersion, SourceFiles: sourceFiles})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repaired.Directory, ".installed"), append(manifest, '\n'), 0o600); err != nil {
		t.Fatal(err)
	}
	historicalDirectory := filepath.Join(filepath.Dir(repaired.Directory), historicalDigest)
	if err := os.Rename(repaired.Directory, historicalDirectory); err != nil {
		t.Fatal(err)
	}
	historical, err := NewSubprocessRunner(root).PrepareRuntime(context.Background(), historicalDigest)
	if err != nil {
		t.Fatal(err)
	}
	if historical.Digest != historicalDigest || historical.Directory != historicalDirectory {
		t.Fatalf("historical reference=%#v", historical)
	}
	if count := installCount(t, trace); count != 2 {
		t.Fatalf("historical reopen unexpectedly installed npm dependencies: %d", count)
	}
}
