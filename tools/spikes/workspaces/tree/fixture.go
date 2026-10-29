//go:build darwin || linux

package tree

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"hash/fnv"
	"io"
	"math/rand/v2"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Profile sizes a fixture: committed paths and ignored paths created after
// the commit.
type Profile struct {
	Tracked int `json:"tracked"`
	Ignored int `json:"ignored"`
}

// Profiles are the fixture sizes BuildFixture knows.
var Profiles = map[string]Profile{
	"small": {Tracked: 1_000, Ignored: 2_000},
	"js":    {Tracked: 5_000, Ignored: 40_000},
	"huge":  {Tracked: 50_000, Ignored: 100_000},
}

// FixtureInfo describes a built fixture.
type FixtureInfo struct {
	Dir       string        `json:"dir"`
	Profile   string        `json:"profile"`
	Tracked   int           `json:"tracked"` // committed paths (files and one symlink)
	Ignored   int           `json:"ignored"` // ignored paths (files, a hard-link pair, a symlink)
	Bytes     int64         `json:"bytes"`   // content bytes written
	Head      string        `json:"head"`    // HEAD commit (deterministic: fixed author, committer and dates)
	HeadTree  string        `json:"headTree"`
	AssetsTgz string        `json:"assetsTgz,omitempty"` // assetsDir/dep.tgz
	Duration  time.Duration `json:"duration"`
	// Phases times the build steps: init, tracked (write), commit
	// (fast-import), index (reset and refresh), ignored (write), assets.
	Phases map[string]time.Duration `json:"phases"`
}

// Fixture constants scenarios rely on.
const (
	LibFiles      = 200 // src/lib/lib_NNN.go, each containing OLD_TOKEN
	DepTgzFiles   = 10_000
	fixtureDate   = "2026-01-01T00:00:00+0000"
	fixtureEpoch  = 1767225600 // fixtureDate
	fixtureSeed   = 0x5eed_d1e7e5
	nodePkgFiles  = 8
	buildDirFiles = 50
)

// fileSpec is one file to write. Content depends only on the path, so
// generation can run in any order and stays byte-identical.
type fileSpec struct {
	path string
	mode os.FileMode
	gen  func(r *rand.Rand) []byte
}

func rngFor(p string) *rand.Rand {
	h := fnv.New64a()
	h.Write([]byte(p))
	return rand.New(rand.NewPCG(h.Sum64(), fixtureSeed))
}

// BuildFixture creates a deterministic git repository in dir (which must
// not exist or be empty) for profile ("small", "js" or "huge"): tracked
// sources committed on main, then ignored content (.env, build/,
// node_modules/, app.log) left uncommitted. When assetsDir is not empty it
// also makes sure assetsDir/dep.tgz exists (a gzip tar of dep-pkg/ with
// 10,000 small files, created only if missing). Same profile, same bytes,
// same HEAD tree and commit.
func BuildFixture(dir, profile, assetsDir string) (FixtureInfo, error) {
	start := time.Now()
	prof, ok := Profiles[profile]
	if !ok {
		return FixtureInfo{}, fmt.Errorf("tree: unknown fixture profile %q", profile)
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return FixtureInfo{}, err
	}
	if err := os.MkdirAll(abs, 0o755); err != nil {
		return FixtureInfo{}, err
	}
	if names, err := readNames(abs, false); err != nil {
		return FixtureInfo{}, err
	} else if len(names) > 0 {
		return FixtureInfo{}, fmt.Errorf("tree: fixture dir %s is not empty", abs)
	}
	info := FixtureInfo{Dir: abs, Profile: profile, Phases: map[string]time.Duration{}}
	mark := time.Now()
	phase := func(name string) {
		now := time.Now()
		info.Phases[name] = now.Sub(mark)
		mark = now
	}

	git := func(args ...string) (string, error) { return fixtureGit(abs, nil, args...) }
	if _, err := git("init", "-q", "-b", "main"); err != nil {
		return info, err
	}
	// Local config, appended in one write instead of four git config runs.
	cfg, err := os.OpenFile(filepath.Join(abs, ".git", "config"), os.O_WRONLY|os.O_APPEND, 0)
	if err != nil {
		return info, err
	}
	_, err = cfg.WriteString(fixtureConfig)
	if cerr := cfg.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return info, err
	}

	phase("init")
	tracked, links := trackedSpecs(prof.Tracked)
	contents, n, err := writeSpecs(abs, tracked, true)
	if err != nil {
		return info, err
	}
	info.Bytes += n
	for _, l := range links {
		if err := os.Symlink(l[1], filepath.Join(abs, filepath.FromSlash(l[0]))); err != nil {
			return info, err
		}
	}
	info.Tracked = len(tracked) + len(links)
	phase("tracked")
	if err := commitFixture(abs, tracked, contents, links); err != nil {
		return info, err
	}
	phase("commit")
	// Index = HEAD with fresh stat data: clean, as after a normal commit.
	if _, err := git("reset", "-q"); err != nil {
		return info, err
	}
	if _, err := git("update-index", "-q", "--refresh"); err != nil {
		return info, err
	}

	phase("index")
	ignored := ignoredSpecs(prof.Ignored)
	if _, n, err = writeSpecs(abs, ignored, false); err != nil {
		return info, err
	}
	info.Bytes += n
	nm := filepath.Join(abs, "node_modules")
	if err := os.Mkdir(filepath.Join(nm, ".bin"), 0o755); err != nil {
		return info, err
	}
	if err := os.Chmod(filepath.Join(nm, ".bin"), 0o755); err != nil {
		return info, err
	}
	if err := os.Link(filepath.Join(nm, "tool", "bin.js"), filepath.Join(nm, ".bin", "tool")); err != nil {
		return info, err
	}
	if err := os.Symlink("../tool/bin.js", filepath.Join(nm, ".bin", "tool2")); err != nil {
		return info, err
	}
	info.Ignored = len(ignored) + 2

	if info.Head, err = git("rev-parse", "HEAD"); err != nil {
		return info, err
	}
	if info.HeadTree, err = git("rev-parse", "HEAD^{tree}"); err != nil {
		return info, err
	}
	phase("ignored")
	if assetsDir != "" {
		info.AssetsTgz = filepath.Join(assetsDir, "dep.tgz")
		if err := ensureDepTgz(info.AssetsTgz); err != nil {
			return info, err
		}
	}
	phase("assets")
	info.Duration = time.Since(start)
	return info, nil
}

// fixtureGit runs git in dir with the isolated environment and fixed
// identity and dates. The fixture is disposable, so git's per-object fsync
// (F_FULLFSYNC on macOS) is off.
func fixtureGit(dir string, stdin io.Reader, args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-c", "core.fsync=none"}, args...)...)
	cmd.Dir = dir
	cmd.Stdin = stdin
	cmd.Env = gitEnv(
		"GIT_AUTHOR_DATE="+fixtureDate, "GIT_COMMITTER_DATE="+fixtureDate,
		"GIT_AUTHOR_NAME=Spike", "GIT_AUTHOR_EMAIL=spike@example.invalid",
		"GIT_COMMITTER_NAME=Spike", "GIT_COMMITTER_EMAIL=spike@example.invalid",
	)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return strings.TrimSpace(string(out)), nil
}

// commitFixture commits the tracked files as the first commit on main. It
// streams them through git fast-import (one pack) instead of git add, which
// writes one loose object per file and costs ~2 ms each here; the tree is
// the same either way. The caller then resets the index to HEAD.
func commitFixture(dir string, files []fileSpec, contents [][]byte, links [][2]string) error {
	var in bytes.Buffer
	const msg = "fixture\n"
	fmt.Fprintf(&in, "commit refs/heads/main\nauthor Spike <spike@example.invalid> %d +0000\ncommitter Spike <spike@example.invalid> %d +0000\ndata %d\n%s",
		fixtureEpoch, fixtureEpoch, len(msg), msg)
	blob := func(mode, p string, data []byte) {
		fmt.Fprintf(&in, "M %s inline %s\ndata %d\n", mode, p, len(data))
		in.Write(data)
		in.WriteByte('\n')
	}
	for i, f := range files {
		mode := "100644"
		if f.mode&0o111 != 0 {
			mode = "100755"
		}
		blob(mode, f.path, contents[i])
	}
	for _, l := range links {
		blob("120000", l[0], []byte(l[1]))
	}
	in.WriteString("done\n")
	_, err := fixtureGit(dir, &in, "fast-import", "--quiet", "--done")
	return err
}

// writeSpecs creates the parent directories (0755) and writes the files in
// parallel with explicit modes (independent of umask). It returns the bytes
// written and, with keep, each file's content in spec order.
func writeSpecs(root string, specs []fileSpec, keep bool) ([][]byte, int64, error) {
	dirs := map[string]bool{}
	for _, s := range specs {
		for d := path.Dir(s.path); d != "." && !dirs[d]; d = path.Dir(d) {
			dirs[d] = true
		}
	}
	sorted := make([]string, 0, len(dirs))
	for d := range dirs {
		sorted = append(sorted, d)
	}
	sort.Strings(sorted) // parents before children
	for _, d := range sorted {
		p := filepath.Join(root, filepath.FromSlash(d))
		if err := os.Mkdir(p, 0o755); err != nil && !errors.Is(err, os.ErrExist) {
			return nil, 0, err
		}
		if err := os.Chmod(p, 0o755); err != nil {
			return nil, 0, err
		}
	}
	var contents [][]byte
	if keep {
		contents = make([][]byte, len(specs))
	}
	var total atomic.Int64
	var firstErr error
	var once sync.Once
	jobs := make(chan int, 256)
	var wg sync.WaitGroup
	for range 2 * runtime.GOMAXPROCS(0) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := range jobs {
				s := specs[i]
				data := s.gen(rngFor(s.path))
				if keep {
					contents[i] = data
				}
				if err := writeFile(filepath.Join(root, filepath.FromSlash(s.path)), data, s.mode); err != nil {
					once.Do(func() { firstErr = err })
					continue
				}
				total.Add(int64(len(data)))
			}
		}()
	}
	for i := range specs {
		jobs <- i
	}
	close(jobs)
	wg.Wait()
	return contents, total.Load(), firstErr
}

func writeFile(p string, data []byte, mode os.FileMode) error {
	f, err := os.OpenFile(p, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Chmod(mode); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func fixed(s string) func(*rand.Rand) []byte { return func(*rand.Rand) []byte { return []byte(s) } }

var words = strings.Fields(`alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi
omicron pi rho sigma tau upsilon phi chi psi omega workspace clone overlay agent turn change file tree
manifest snapshot journal kernel volume branch commit index stage review lane card board project
module package vendor build cache token value result error retry queue worker buffer stream`)

// prose returns exactly n bytes (n >= 1) of wrapped words ending in a newline.
func prose(r *rand.Rand, n int) []byte {
	b := make([]byte, 0, n+16)
	col := 0
	for len(b) < n {
		w := words[r.IntN(len(words))]
		if col > 0 {
			if col+1+len(w) > 72 {
				b = append(b, '\n')
				col = 0
			} else {
				b = append(b, ' ')
				col++
			}
		}
		b = append(b, w...)
		col += len(w)
	}
	b = b[:n-1]
	return append(b, '\n')
}

func randomBytes(r *rand.Rand, n int) []byte {
	b := make([]byte, n)
	for i := 0; i < n; i += 8 {
		v := r.Uint64()
		for j := 0; j < 8 && i+j < n; j++ {
			b[i+j] = byte(v >> (8 * j))
		}
	}
	return b
}

func commented(prefix string, r *rand.Rand, n int) []byte {
	var b strings.Builder
	for _, line := range strings.Split(strings.TrimSuffix(string(prose(r, n)), "\n"), "\n") {
		b.WriteString(prefix)
		b.WriteString(line)
		b.WriteByte('\n')
	}
	return []byte(b.String())
}

const genScript = `#!/bin/sh
# Regenerates gen/ (ignored by git) and api/generated.json (tracked).
# Deterministic: the same files and bytes on every run.
set -eu
cd "$(dirname "$0")/.."
mkdir -p gen
i=0
while [ "$i" -lt 20 ]; do
	printf 'package gen\n\n// Code generated by scripts/gen.sh. DO NOT EDIT.\n\nconst Value%d = %d\n' "$i" "$i" >"gen/gen_$i.go"
	i=$((i + 1))
done
printf '{\n  "generator": "scripts/gen.sh",\n  "files": 20,\n  "version": 2\n}\n' >api/generated.json
`

// GeneratedJSONAfterGen is api/generated.json after scripts/gen.sh ran; the
// committed version differs ("files": 0, "version": 1).
const GeneratedJSONAfterGen = "{\n  \"generator\": \"scripts/gen.sh\",\n  \"files\": 20,\n  \"version\": 2\n}\n"

// fixtureConfig is appended to the fixture's .git/config.
const fixtureConfig = "[user]\n\tname = Spike\n\temail = spike@example.invalid\n[commit]\n\tgpgsign = false\n[core]\n\thooksPath = /dev/null\n"

// FixtureGitignore is the fixture's .gitignore.
const FixtureGitignore = "node_modules/\nbuild/\ngen/\n.env\n*.log\ndist/\n"

// trackedSpecs returns the committed files and symlinks ([path, target]),
// together exactly n paths.
func trackedSpecs(n int) ([]fileSpec, [][2]string) {
	specs := []fileSpec{
		{"Readme.md", 0o644, func(r *rand.Rand) []byte {
			return append([]byte("# Spike fixture\n\nProject readme\n\nGenerated by the workspace spike; the content is deterministic.\n\n"), prose(r, 600)...)
		}},
		{"docs/guide.md", 0o644, func(r *rand.Rand) []byte {
			b := []byte("# Guide\n\nGuide version: 1\n")
			for range 4 {
				b = append(b, '\n')
				b = append(b, prose(r, 300+r.IntN(400))...)
			}
			return b
		}},
		{"src/app/main.go", 0o644, fixed("package main\n\nimport \"fmt\"\n\n// Greeting is what main prints.\nconst Greeting = \"hello\"\n\nfunc main() {\n\tfmt.Println(Greeting, helper())\n}\n")},
		{"src/app/util.go", 0o644, fixed("package main\n\nimport \"strings\"\n\nfunc helper() string {\n\treturn strings.ToUpper(\"world\")\n}\n")},
		{"scripts/gen.sh", 0o755, fixed(genScript)},
		{"api/schema.json", 0o644, fixed("{\n  \"$schema\": \"https://json-schema.org/draft/2020-12/schema\",\n  \"title\": \"Item\",\n  \"type\": \"object\",\n  \"properties\": {\n    \"id\": {\"type\": \"string\"},\n    \"count\": {\"type\": \"integer\"}\n  },\n  \"required\": [\"id\"]\n}\n")},
		{"api/generated.json", 0o644, fixed("{\n  \"generator\": \"scripts/gen.sh\",\n  \"files\": 0,\n  \"version\": 1\n}\n")},
		{"assets/logo.bin", 0o644, func(r *rand.Rand) []byte { return randomBytes(r, 64<<10) }},
		{"Makefile", 0o644, fixed(".PHONY: gen clean\n\ngen:\n\tsh scripts/gen.sh\n\nclean:\n\trm -rf build gen dist\n")},
		{".gitignore", 0o644, fixed(FixtureGitignore)},
	}
	for i := range LibFiles {
		specs = append(specs, fileSpec{fmt.Sprintf("src/lib/lib_%03d.go", i), 0o644, func(r *rand.Rand) []byte {
			b := fmt.Appendf(nil, "package lib\n\n// Name%03d is renamed by scenarios that replace OLD_TOKEN.\nconst Name%03d = \"OLD_TOKEN-%03d\"\n\n// Value%03d returns a fixed number.\nfunc Value%03d() int {\n\treturn %d\n}\n\n",
				i, i, i, i, i, r.IntN(10_000))
			return append(b, commented("// ", r, 100+r.IntN(900))...)
		}})
	}
	links := [][2]string{{"link-to-readme", "Readme.md"}}
	for i := 0; len(specs)+len(links) < n; i++ {
		specs = append(specs, fileSpec{fmt.Sprintf("pkg/p%03d/f%03d.txt", i/100, i%100), 0o644, func(r *rand.Rand) []byte {
			return prose(r, 200+r.IntN(1801))
		}})
	}
	return specs, links
}

// ignoredSpecs returns the ignored files; with the hard link and symlink
// BuildFixture adds afterwards they are exactly n paths.
func ignoredSpecs(n int) []fileSpec {
	specs := []fileSpec{
		{".env", 0o644, fixed("API_KEY=spike-not-a-secret\n")},
		{"app.log", 0o644, func(r *rand.Rand) []byte { return commented("INFO ", r, 2000) }},
		{"build/out.bin", 0o644, func(r *rand.Rand) []byte { return randomBytes(r, 256<<10) }},
		{"node_modules/tool/bin.js", 0o755, func(r *rand.Rand) []byte {
			return append([]byte("#!/usr/bin/env node\n'use strict';\nconsole.log('tool');\n"), commented("// ", r, 400)...)
		}},
	}
	for i := 1; i < buildDirFiles; i++ {
		specs = append(specs, fileSpec{fmt.Sprintf("build/obj/obj_%02d.o", i), 0o644, func(r *rand.Rand) []byte {
			return randomBytes(r, 100+r.IntN(4000))
		}})
	}
	remaining := n - len(specs) - 2 // hard link and symlink
	names := []string{"package.json", "index.js", "README.md", "LICENSE", "lib/a.js", "lib/b.js", "lib/c.js", "lib/d.js"}
	for p := 0; remaining > 0; p++ {
		for k := 0; k < nodePkgFiles && remaining > 0; k++ {
			name := names[k]
			specs = append(specs, fileSpec{fmt.Sprintf("node_modules/pkg-%04d/%s", p, name), 0o644, func(r *rand.Rand) []byte {
				switch name {
				case "package.json":
					return fmt.Appendf(nil, "{\n  \"name\": \"pkg-%04d\",\n  \"version\": \"1.%d.%d\",\n  \"main\": \"index.js\",\n  \"license\": \"MIT\"\n}\n", p, r.IntN(20), r.IntN(20))
				case "index.js":
					return append([]byte("'use strict';\nmodule.exports = require('./lib/a.js');\n"), commented("// ", r, 50+r.IntN(300))...)
				case "README.md", "LICENSE":
					return prose(r, 200+r.IntN(1500))
				default:
					f := strings.TrimSuffix(path.Base(name), ".js")
					b := fmt.Appendf(nil, "'use strict';\n\nfunction %s%d(x) {\n  return x + %d;\n}\n\nmodule.exports = { %s%d };\n", f, p, r.IntN(1000), f, p)
					return append(b, commented("// ", r, 100+r.IntN(2500))...)
				}
			}})
			remaining--
		}
	}
	return specs
}

// ensureDepTgz writes the deterministic dependency archive unless it exists.
func ensureDepTgz(dst string) error {
	if _, err := os.Stat(dst); err == nil {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".dep.tgz.tmp*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := writeDepTgz(tmp); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), dst)
}

func writeDepTgz(w *os.File) error {
	gz := gzip.NewWriter(w) // zero header name and mtime: deterministic
	tw := tar.NewWriter(gz)
	mod := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	dir := func(name string) error {
		return tw.WriteHeader(&tar.Header{Typeflag: tar.TypeDir, Name: name, Mode: 0o755, ModTime: mod, Format: tar.FormatUSTAR})
	}
	if err := dir("dep-pkg/"); err != nil {
		return err
	}
	const dirs = 100
	for d := range dirs {
		if err := dir(fmt.Sprintf("dep-pkg/mod%02d/", d)); err != nil {
			return err
		}
		for f := range DepTgzFiles / dirs {
			name := fmt.Sprintf("dep-pkg/mod%02d/file%03d.js", d, f)
			r := rngFor(name)
			body := append(fmt.Appendf(nil, "module.exports = 'mod%02d/file%03d';\n", d, f), commented("// ", r, 20+r.IntN(300))...)
			if err := tw.WriteHeader(&tar.Header{Typeflag: tar.TypeReg, Name: name, Mode: 0o644, Size: int64(len(body)), ModTime: mod, Format: tar.FormatUSTAR}); err != nil {
				return err
			}
			if _, err := tw.Write(body); err != nil {
				return err
			}
		}
	}
	if err := tw.Close(); err != nil {
		return err
	}
	return gz.Close()
}
