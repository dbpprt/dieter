//go:build darwin || linux

package tree

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"dieter.spike/workspaces/core"
)

func gitOut(t *testing.T, dir string, args ...string) string {
	t.Helper()
	return gitOutEnv(t, dir, nil, args...)
}

func gitOutEnv(t *testing.T, dir string, env []string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = gitEnv(env...)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("git %v: %v", args, err)
	}
	return strings.TrimSpace(string(out))
}

func TestBuildFixtureSmall(t *testing.T) {
	tmp := t.TempDir()
	a, err := BuildFixture(filepath.Join(tmp, "a"), "small", filepath.Join(tmp, "assets-a"))
	must(t, err)
	b, err := BuildFixture(filepath.Join(tmp, "b"), "small", filepath.Join(tmp, "assets-b"))
	must(t, err)
	t.Logf("small fixture a: %s %v, b: %s %v", a.Duration, a.Phases, b.Duration, b.Phases)
	t0 := time.Now()
	defer func() { t.Logf("checks took %s", time.Since(t0)) }()

	if a.HeadTree != b.HeadTree || a.Head != b.Head {
		t.Fatalf("HEAD differs: %s/%s vs %s/%s", a.Head, a.HeadTree, b.Head, b.HeadTree)
	}
	if got := gitOut(t, a.Dir, "rev-parse", "HEAD^{tree}"); got != a.HeadTree {
		t.Fatalf("HEAD^{tree} = %s, info says %s", got, a.HeadTree)
	}
	// The fast-import commit has exactly the tree git add would produce.
	idx := []string{"GIT_INDEX_FILE=" + filepath.Join(tmp, "fresh-index")}
	gitOutEnv(t, a.Dir, idx, "add", "-A", ".gitignore", "Readme.md", "api", "assets", "docs", "link-to-readme", "Makefile", "pkg", "scripts", "src")
	if got := gitOutEnv(t, a.Dir, idx, "write-tree"); got != a.HeadTree {
		t.Fatalf("git add tree = %s, fixture HEAD tree = %s", got, a.HeadTree)
	}
	ta, tb := mustScan(t, a.Dir), mustScan(t, b.Dir)
	if !reflect.DeepEqual(ta, tb) {
		t.Fatalf("scan trees differ: %v", core.DiffTrees(ta, tb).Paths())
	}
	ha, err := HashFile(a.AssetsTgz)
	must(t, err)
	hb, err := HashFile(b.AssetsTgz)
	must(t, err)
	if ha != hb {
		t.Fatal("dep.tgz differs between builds")
	}
	// dep.tgz is only created when missing.
	fi, err := os.Stat(a.AssetsTgz)
	must(t, err)
	must(t, ensureDepTgz(a.AssetsTgz))
	fi2, err := os.Stat(a.AssetsTgz)
	must(t, err)
	if !os.SameFile(fi, fi2) || !fi.ModTime().Equal(fi2.ModTime()) {
		t.Fatal("dep.tgz was rewritten")
	}
	for k, v := range map[string]string{"user.name": "Spike", "user.email": "spike@example.invalid", "commit.gpgsign": "false", "core.hooksPath": "/dev/null"} {
		if got := gitOut(t, a.Dir, "config", "--local", k); got != v {
			t.Errorf("config %s = %q, want %q", k, got, v)
		}
	}
	if got := gitOut(t, a.Dir, "branch", "--show-current"); got != "main" {
		t.Errorf("branch = %q", got)
	}
	if n := strings.Count(tarList(t, a.AssetsTgz), ".js\n"); n != DepTgzFiles {
		t.Fatalf("dep.tgz has %d files, want %d", n, DepTgzFiles)
	}

	// Counts.
	if a.Tracked != 1000 || a.Ignored != 2000 {
		t.Fatalf("counts = %d tracked, %d ignored", a.Tracked, a.Ignored)
	}
	if n := len(strings.Split(gitOut(t, a.Dir, "ls-files"), "\n")); n != a.Tracked {
		t.Fatalf("git ls-files = %d, want %d", n, a.Tracked)
	}
	nonDir := 0
	for _, e := range ta {
		if e.Type != core.Dir {
			nonDir++
		}
	}
	if nonDir != a.Tracked+a.Ignored {
		t.Fatalf("scan has %d non-dir entries, want %d", nonDir, a.Tracked+a.Ignored)
	}
	if st := gitOut(t, a.Dir, "status", "--porcelain"); st != "" {
		t.Fatalf("fixture is not clean:\n%s", st)
	}

	// Content contract.
	read := func(rel string) string {
		data, err := os.ReadFile(filepath.Join(a.Dir, rel))
		must(t, err)
		return string(data)
	}
	for rel, want := range map[string]string{
		"Readme.md":                     "\nProject readme\n",
		"docs/guide.md":                 "\nGuide version: 1\n",
		"src/app/main.go":               "const Greeting = \"hello\"",
		".env":                          "API_KEY=spike-not-a-secret",
		".gitignore":                    "node_modules/\nbuild/\ngen/\n.env\n*.log\ndist/\n",
		"node_modules/tool/bin.js":      "console.log('tool')",
		"node_modules/.bin/tool":        "console.log('tool')",
		"src/lib/lib_199.go":            "OLD_TOKEN",
		"node_modules/pkg-0000/LICENSE": "",
	} {
		if !strings.Contains(read(rel), want) {
			t.Errorf("%s does not contain %q", rel, want)
		}
	}
	libs, _ := filepath.Glob(filepath.Join(a.Dir, "src/lib/*.go"))
	if len(libs) != LibFiles {
		t.Errorf("src/lib has %d files", len(libs))
	}
	for _, l := range libs {
		data, err := os.ReadFile(l)
		must(t, err)
		if !bytes.Contains(data, []byte("OLD_TOKEN")) {
			t.Errorf("%s lacks OLD_TOKEN", l)
		}
	}
	if e := ta["scripts/gen.sh"]; e.Mode != 0o755 {
		t.Errorf("gen.sh mode = %o", e.Mode)
	}
	if e := ta["link-to-readme"]; e.Type != core.Symlink || e.Target != "Readme.md" {
		t.Errorf("link-to-readme = %+v", e)
	}
	if e := ta["node_modules/.bin/tool2"]; e.Type != core.Symlink || e.Target != "../tool/bin.js" {
		t.Errorf("tool2 = %+v", e)
	}
	if ta["assets/logo.bin"].Size != 64<<10 || ta["build/out.bin"].Size != 256<<10 {
		t.Errorf("binary sizes: logo %d, out %d", ta["assets/logo.bin"].Size, ta["build/out.bin"].Size)
	}
	m, _ := mustBuild(t, a.Dir, nil)
	if m.Entries["node_modules/.bin/tool"].Ino != m.Entries["node_modules/tool/bin.js"].Ino {
		t.Error("node_modules/.bin/tool is not a hard link of tool/bin.js")
	}

	t.Run("ignored", func(t *testing.T) {
		paths := []string{
			"node_modules/x/y.js", ".env", "gen/a.go", "src/app/main.go", "build/obj/obj_01.o",
			"app.log", "deep/nested/x.log", "Readme.md", "node_modules", "dist/new/file.txt", "src/new.go",
		}
		want := map[string]bool{
			"node_modules/x/y.js": true, ".env": true, "gen/a.go": true, "src/app/main.go": false,
			"build/obj/obj_01.o": true, "app.log": true, "deep/nested/x.log": true, "Readme.md": false,
			"node_modules": true, "dist/new/file.txt": true, "src/new.go": false,
		}
		got, err := Ignored(a.Dir, "", paths)
		must(t, err)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("Ignored = %v, want %v", got, want)
		}
		got, err = Ignored(a.Dir, filepath.Join(a.Dir, ".git"), paths)
		must(t, err)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("Ignored with explicit git dir = %v, want %v", got, want)
		}
		none, err := Ignored(a.Dir, "", []string{"src/app/main.go"})
		must(t, err)
		if none["src/app/main.go"] {
			t.Fatal("tracked file ignored")
		}
	})

	t.Run("ignored beyond symlinked dir", func(t *testing.T) {
		must(t, os.Symlink("src", filepath.Join(b.Dir, "srclink")))
		got, err := Ignored(b.Dir, "", []string{"srclink/x.log", "srclink/app/main.go", "srclink", "x.log"})
		must(t, err)
		want := map[string]bool{"srclink/x.log": false, "srclink/app/main.go": false, "srclink": false, "x.log": true}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("Ignored = %v, want %v", got, want)
		}
		must(t, os.Remove(filepath.Join(b.Dir, "srclink")))
	})

	t.Run("gen script", func(t *testing.T) {
		before := mustScan(t, b.Dir)
		cmd := exec.Command("sh", "scripts/gen.sh")
		cmd.Dir = b.Dir
		cmd.Env = gitEnv()
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("gen.sh: %v: %s", err, out)
		}
		after := mustScan(t, b.Dir)
		cs := core.DiffTrees(before, after)
		ig, err := Ignored(b.Dir, "", cs.Paths())
		must(t, err)
		MarkIgnored(cs, ig)
		if len(cs) != 21 {
			t.Fatalf("gen.sh changed %d paths, want 21: %v", len(cs), cs.Paths())
		}
		for p, c := range cs {
			switch {
			case p == "api/generated.json":
				if c.Kind != core.Modified || c.Ignored {
					t.Errorf("%s: %+v", p, c)
				}
			case strings.HasPrefix(p, "gen/gen_"):
				if c.Kind != core.Added || !c.Ignored {
					t.Errorf("%s: %+v", p, c)
				}
			default:
				t.Errorf("unexpected change %+v", c)
			}
		}
		data, err := os.ReadFile(filepath.Join(b.Dir, "api/generated.json"))
		must(t, err)
		if string(data) != GeneratedJSONAfterGen {
			t.Errorf("generated.json = %q", data)
		}
		// Running it again is an identical rewrite.
		again := exec.Command("sh", filepath.Join(b.Dir, "scripts/gen.sh")) // from another cwd
		again.Env = gitEnv()
		if out, err := again.CombinedOutput(); err != nil {
			t.Fatalf("gen.sh again: %v: %s", err, out)
		}
		checkChanges(t, core.DiffTrees(after, mustScan(t, b.Dir)), nil)
	})
}

func tarList(t *testing.T, tgz string) string {
	t.Helper()
	cmd := exec.Command("tar", "-tzf", tgz)
	cmd.Env = gitEnv()
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("tar -tzf: %v", err)
	}
	return string(out)
}

func TestBuildFixtureRejectsNonEmptyDir(t *testing.T) {
	dir := t.TempDir()
	mkfile(t, dir, "x", "x")
	if _, err := BuildFixture(dir, "small", ""); err == nil {
		t.Fatal("BuildFixture accepted a non-empty dir")
	}
	if _, err := BuildFixture(t.TempDir(), "nope", ""); err == nil {
		t.Fatal("BuildFixture accepted an unknown profile")
	}
}

func TestMarkIgnored(t *testing.T) {
	cs := core.ChangeSet{}
	cs.Add("a", core.Added, false)
	cs.Add("b", core.Modified, false)
	MarkIgnored(cs, map[string]bool{"a": true, "b": false, "c": true})
	if !cs["a"].Ignored || cs["b"].Ignored || len(cs) != 2 {
		t.Fatalf("MarkIgnored = %+v", cs)
	}
}
