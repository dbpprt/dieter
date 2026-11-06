//go:build darwin || linux

package tree

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"

	"dieter.spike/workspaces/core"
)

// TestMeasure builds (if missing) and measures the fixture profiles listed in
// TREE_MEASURE (comma-separated) under TREE_MEASURE_DIR/<profile>, with the
// dependency archive in TREE_MEASURE_DIR/assets. Profiles listed in
// TREE_MEASURE_INHERIT are also cloned (cp -c -R on darwin, cp -a on linux)
// to measure InheritManifest; the clone is removed afterwards. Skipped
// unless TREE_MEASURE is set. Example:
//
//	TREE_MEASURE=small,js TREE_MEASURE_INHERIT=small,js \
//	TREE_MEASURE_DIR=/Volumes/External/dieter-spike/tree-dev \
//	go test -run TestMeasure -v -timeout 60m ./tree/
func TestMeasure(t *testing.T) {
	list := os.Getenv("TREE_MEASURE")
	if list == "" {
		t.Skip("set TREE_MEASURE to measure fixtures")
	}
	dir := os.Getenv("TREE_MEASURE_DIR")
	if dir == "" {
		t.Fatal("TREE_MEASURE_DIR is required")
	}
	inherit := map[string]bool{}
	for _, p := range strings.Split(os.Getenv("TREE_MEASURE_INHERIT"), ",") {
		inherit[p] = true
	}
	report := func(what string, v any) {
		b, _ := json.Marshal(v)
		t.Logf("%s %s", what, b)
	}
	for _, profile := range strings.Split(list, ",") {
		fix := filepath.Join(dir, profile)
		if _, err := os.Stat(fix); err != nil {
			info, err := BuildFixture(fix, profile, filepath.Join(dir, "assets"))
			must(t, err)
			report(profile+" build", info)
		} else {
			t.Logf("%s: reusing %s", profile, fix)
		}
		// The first walk may pay for cold metadata and page caches; the
		// second shows the warm cost of the same work.
		tr, st, err := Scan(fix, ScanOptions{})
		must(t, err)
		report(profile+" scan", st)
		_, st, err = Scan(fix, ScanOptions{})
		must(t, err)
		report(profile+" scan-again", st)
		cold, cst, err := BuildManifest(fix, nil)
		must(t, err)
		report(profile+" manifest-cold", cst)
		warm, wst, err := BuildManifest(fix, cold)
		must(t, err)
		report(profile+" manifest-warm", wst)
		if !reflect.DeepEqual(tr, cold.Tree()) || !reflect.DeepEqual(tr, warm.Tree()) {
			t.Fatalf("%s: manifest trees differ from Scan", profile)
		}
		if !inherit[profile] {
			continue
		}
		view := filepath.Join(dir, profile+"-view-measure")
		os.RemoveAll(view)
		start := time.Now()
		var cmd *exec.Cmd
		if runtime.GOOS == "darwin" {
			cmd = exec.Command("/bin/cp", "-c", "-R", fix, view)
		} else {
			cmd = exec.Command("cp", "-a", fix, view)
		}
		cmd.Env = gitEnv()
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%v: %v: %s", cmd.Args, err, out)
		}
		report(profile+" clone", map[string]any{"duration": time.Since(start)})
		inh, ist, err := InheritManifest(warm, view)
		must(t, err)
		report(profile+" inherit", ist)
		if d := core.DiffTrees(tr, inh.Tree()); len(d) != 0 {
			t.Errorf("%s: inherited tree differs: %v", profile, d.Paths())
		}
		_, vst, err := BuildManifest(view, inh)
		must(t, err)
		report(profile+" view-warm", vst)
		must(t, os.RemoveAll(view))
	}
}
