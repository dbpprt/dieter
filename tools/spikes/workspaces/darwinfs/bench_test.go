//go:build darwin

package darwinfs

// Heavy measurements. Run with:
//
//	DARWINFS_BENCH=1 go test -count=1 -v -timeout 60m -run 'Bench' ./darwinfs/
//
// Trees live under DARWINFS_SCRATCH (default /Volumes/External/dieter-spike/
// darwinfs-dev) in bench.noindex/bench-trees/ and are reused across runs;
// delete that directory to rebuild or reclaim them.

import (
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func benchOnly(t *testing.T) string {
	t.Helper()
	if os.Getenv("DARWINFS_BENCH") != "1" {
		t.Skip("set DARWINFS_BENCH=1")
	}
	base := os.Getenv("DARWINFS_SCRATCH")
	if base == "" {
		base = externalBase
	}
	if _, err := os.Stat(base); err != nil {
		t.Skipf("scratch base %s: %v", base, err)
	}
	// ".noindex" keeps Spotlight from indexing the synthetic trees.
	base = filepath.Join(base, "bench.noindex")
	must(t, os.MkdirAll(base, 0o755))
	return base
}

// benchTree returns a tree of dirs*files files of 1-4 KiB below base,
// creating it when missing. Layout: d%03d/s%03d/f%03d (top level split into
// groups of 100 sub directories) or d%03d/f%03d when dirs <= 200.
func benchTree(t *testing.T, base, name string, dirs, files int) string {
	t.Helper()
	root := filepath.Join(base, "bench-trees", name)
	marker := filepath.Join(base, "bench-trees", name+".done")
	if _, err := os.Stat(marker); err == nil {
		return root
	}
	os.RemoveAll(root)
	start := time.Now()
	noise := make([]byte, 8192)
	r := rand.New(rand.NewPCG(1, 2))
	for i := range noise {
		noise[i] = byte(r.IntN(256))
	}
	dirPath := func(d int) string {
		if dirs <= 200 {
			return filepath.Join(root, fmt.Sprintf("d%03d", d))
		}
		return filepath.Join(root, fmt.Sprintf("d%03d", d/100), fmt.Sprintf("s%03d", d%100))
	}
	work := make(chan int)
	var wg sync.WaitGroup
	var firstErr atomic.Value
	for w := 0; w < 8; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			rr := rand.New(rand.NewPCG(uint64(w), 7))
			for d := range work {
				dp := dirPath(d)
				if err := os.MkdirAll(dp, 0o755); err != nil {
					firstErr.CompareAndSwap(nil, err)
					continue
				}
				for f := 0; f < files; f++ {
					size := 1024 + rr.IntN(3073)
					off := rr.IntN(len(noise) - size)
					if err := os.WriteFile(filepath.Join(dp, fmt.Sprintf("f%03d", f)), noise[off:off+size], 0o644); err != nil {
						firstErr.CompareAndSwap(nil, err)
					}
				}
			}
		}(w)
	}
	for d := 0; d < dirs; d++ {
		work <- d
	}
	close(work)
	wg.Wait()
	if v := firstErr.Load(); v != nil {
		t.Fatal(v)
	}
	must(t, os.WriteFile(marker, nil, 0o644))
	t.Logf("built %s (%d dirs x %d files) in %v", name, dirs, files, time.Since(start).Round(time.Millisecond))
	return root
}

func freeBytes(t *testing.T, path string) int64 {
	t.Helper()
	unix.Sync()
	time.Sleep(time.Second)
	var s unix.Statfs_t
	must(t, unix.Statfs(path, &s))
	return int64(s.Bavail) * int64(s.Bsize)
}

func rmrf(t *testing.T, path string) time.Duration {
	t.Helper()
	start := time.Now()
	cmd := exec.Command("/bin/rm", "-rf", path)
	cmd.Env = childEnv()
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("rm -rf %s: %v %s", path, err, out)
	}
	return time.Since(start)
}

func ms(d time.Duration) string { return fmt.Sprintf("%.1f ms", float64(d.Microseconds())/1000) }

func TestBenchClone(t *testing.T) {
	base := benchOnly(t)
	t20 := benchTree(t, base, "t20k", 200, 100)
	t150 := benchTree(t, base, "t150k", 1500, 100)
	work := filepath.Join(base, "bench-work")
	os.RemoveAll(work)
	must(t, os.MkdirAll(work, 0o755))
	defer os.RemoveAll(work)

	for i := 0; i < 3; i++ {
		d, err := CloneTree(t20, filepath.Join(work, fmt.Sprintf("c20-%d", i)))
		must(t, err)
		t.Logf("CloneTree 20k run %d: %s", i, ms(d))
	}
	for i := 0; i < 2; i++ {
		d, err := ClonePerFile(t20, filepath.Join(work, fmt.Sprintf("p20-%d", i)))
		must(t, err)
		t.Logf("ClonePerFile (cp -c -R) 20k run %d: %s", i, ms(d))
	}
	for i := 0; i < 4; i++ {
		before := freeBytes(t, work)
		dst := filepath.Join(work, fmt.Sprintf("c150-%d", i))
		d, err := CloneTree(t150, dst)
		must(t, err)
		after := freeBytes(t, work)
		t.Logf("CloneTree 150k run %d: %s; free-space delta %.1f MiB", i, ms(d), float64(before-after)/(1<<20))
		var rm time.Duration
		how := "rm -rf"
		if i%2 == 0 {
			rm = rmrf(t, dst)
		} else {
			how = "parallel unlink (8 goroutines)"
			rm = parallelRemove(t, dst, 8)
		}
		t.Logf("%s of 150k clone run %d: %s; free after delete vs before clone %.1f MiB", how, i, ms(rm), float64(before-freeBytes(t, work))/(1<<20))
	}
	var src unix.Statfs_t
	must(t, unix.Statfs(t150, &src))
	t.Logf("source 150k tree: du says %s", strings.TrimSpace(run(t, "/usr/bin/du", "-sh", t150)))
}

// parallelRemove deletes a tree by unlinking files from several goroutines,
// then removing directories deepest first.
func parallelRemove(t *testing.T, root string, workers int) time.Duration {
	t.Helper()
	start := time.Now()
	m, _, err := ScanClone(root, ScanOptions{Workers: workers, SkipBlockStats: true})
	must(t, err)
	var files, dirs []string
	for p, e := range m {
		if e.Type == "dir" {
			dirs = append(dirs, p)
		} else {
			files = append(files, p)
		}
	}
	ch := make(chan string, 1024)
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for p := range ch {
				unix.Unlink(filepath.Join(root, p))
			}
		}()
	}
	for _, f := range files {
		ch <- f
	}
	close(ch)
	wg.Wait()
	slices.SortFunc(dirs, func(a, b string) int { return strings.Count(b, "/") - strings.Count(a, "/") })
	for _, d := range dirs {
		must(t, unix.Rmdir(filepath.Join(root, d)))
	}
	must(t, unix.Rmdir(root))
	return time.Since(start)
}

func run(t *testing.T, name string, args ...string) string {
	t.Helper()
	cmd := exec.Command(name, args...)
	cmd.Env = childEnv()
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%s %v: %v %s", name, args, err, out)
	}
	return string(out)
}

func TestBenchScan(t *testing.T) {
	base := benchOnly(t)
	trees := []struct{ name, root string }{
		{"20k", benchTree(t, base, "t20k", 200, 100)},
		{"150k", benchTree(t, base, "t150k", 1500, 100)},
	}
	masks := []struct {
		name string
		ext  uint32
	}{
		{"full (clone id+private size+ext flags)", attrExtPrivateSize | attrExtCloneID | attrExtExtFlags},
		{"clone id+ext flags", attrExtCloneID | attrExtExtFlags},
		{"clone id only", attrExtCloneID},
		{"no CMNEXT attrs", 0},
	}
	defer func() { scanExtAttrs = attrExtPrivateSize | attrExtCloneID | attrExtExtFlags }()
	for _, tr := range trees {
		for _, w := range []int{1, 8} {
			ds := make([][]time.Duration, len(masks))
			var st ScanStats
			for round := 0; round < 5; round++ { // interleave masks to spread background load
				for i, mk := range masks {
					scanExtAttrs = mk.ext
					m, s, err := ScanClone(tr.root, ScanOptions{Workers: w})
					must(t, err)
					if len(m) != s.Entries {
						t.Fatalf("entries %d != %d", len(m), s.Entries)
					}
					st = s
					ds[i] = append(ds[i], s.Duration)
				}
			}
			for i, mk := range masks {
				slices.Sort(ds[i])
				t.Logf("ScanClone %s workers=%d %s: min %s median %s (entries %d dirs %d calls %d)",
					tr.name, w, mk.name, ms(ds[i][0]), ms(ds[i][len(ds[i])/2]), st.Entries, st.Dirs, st.Calls)
			}
		}
		var walk []time.Duration
		for i := 0; i < 3; i++ {
			start := time.Now()
			must(t, filepath.Walk(tr.root, func(p string, fi os.FileInfo, err error) error { return err }))
			walk = append(walk, time.Since(start))
		}
		slices.Sort(walk)
		t.Logf("reference filepath.Walk (readdir+lstat, 1 goroutine) %s: min %s median %s", tr.name, ms(walk[0]), ms(walk[1]))
	}
}

type cstate struct {
	clone     uint64
	priv      int64
	shares    bool
	ino       uint64
	gen       uint32
	mtime     int64
	ctime     int64
	size      int64
	linkCount uint32
}

func cstat(t *testing.T, path string) cstate {
	t.Helper()
	m, _, err := ScanClone(filepath.Dir(path), ScanOptions{})
	must(t, err)
	e, ok := m[filepath.Base(path)]
	if !ok {
		t.Fatalf("scan: %s missing", path)
	}
	gc, err := genCount(path)
	must(t, err)
	return cstate{e.CloneID, e.PrivateSize, e.SharesAllBlocks, e.Ino, gc, e.MtimeNs, e.CtimeNs, e.Size, e.LinkCount}
}

func pwrite(t *testing.T, path string, off int64, b []byte, flag int) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_WRONLY|flag, 0)
	must(t, err)
	if flag&os.O_APPEND != 0 {
		_, err = f.Write(b)
	} else {
		_, err = f.WriteAt(b, off)
	}
	must(t, err)
	must(t, f.Close())
}

func TestBenchCloneIDSemantics(t *testing.T) {
	base := benchOnly(t)
	dir := filepath.Join(base, "bench-cloneid")
	os.RemoveAll(dir)
	defer os.RemoveAll(dir)
	content := make([]byte, 64<<10)
	r := rand.New(rand.NewPCG(3, 4))
	for i := range content {
		content[i] = byte(r.IntN(256))
	}
	type op struct {
		name string
		fn   func(p string)
	}
	ops := []op{
		{"untouched", func(string) {}},
		{"1-byte overwrite", func(p string) { pwrite(t, p, 100, []byte{'X'}, 0) }},
		{"2nd write, same block", nil}, // handled inline below
		{"2nd write, other block", nil},
		{"rewrite identical bytes", func(p string) { pwrite(t, p, 0, content, 0) }},
		{"O_TRUNC + same content", func(p string) { must(t, os.WriteFile(p, content, 0o644)) }},
		{"append 1 byte", func(p string) { pwrite(t, p, 0, []byte{'A'}, os.O_APPEND) }},
		{"touch", func(p string) { run(t, "/usr/bin/touch", p) }},
		{"atomic replace (same bytes)", func(p string) {
			must(t, os.WriteFile(p+".tmp", content, 0o644))
			must(t, os.Rename(p+".tmp", p))
		}},
		{"chmod 600", func(p string) { must(t, os.Chmod(p, 0o600)) }},
		{"xattr -w", func(p string) { run(t, "/usr/bin/xattr", "-w", "user.spike", "v", p) }},
	}
	var rows []string
	rows = append(rows, "| op in clone | src id == clone id | clone id changed by op | src priv/shares | clone priv/shares | ino same | gen count before→after | 2nd-write id change |")
	rows = append(rows, "|---|---|---|---|---|---|---|---|")
	for i, o := range ops {
		src := filepath.Join(dir, fmt.Sprintf("s%02d", i), "src")
		dst := filepath.Join(dir, fmt.Sprintf("s%02d", i), "dst")
		must(t, os.MkdirAll(src, 0o755))
		must(t, os.WriteFile(filepath.Join(src, "f"), content, 0o644))
		_, err := CloneTree(src, dst)
		must(t, err)
		p := filepath.Join(dst, "f")
		before := cstat(t, p)
		srcBefore := cstat(t, filepath.Join(src, "f"))
		// For the "2nd write" ops, capture the id after the first write too.
		secondInfo := "n/a"
		if strings.HasPrefix(o.name, "2nd write") {
			pwrite(t, p, 100, []byte{'X'}, 0)
			first := cstat(t, p)
			time.Sleep(10 * time.Millisecond)
			if strings.HasSuffix(o.name, "same block") {
				pwrite(t, p, 101, []byte{'Y'}, 0)
			} else {
				pwrite(t, p, 40000, []byte{'Y'}, 0)
			}
			second := cstat(t, p)
			secondInfo = fmt.Sprintf("1st→2nd id changed=%v (priv %d→%d, gen %d→%d, mtime changed=%v)",
				first.clone != second.clone, first.priv, second.priv, first.gen, second.gen, first.mtime != second.mtime)
		} else {
			o.fn(p)
		}
		after := cstat(t, p)
		srcAfter := cstat(t, filepath.Join(src, "f"))
		rows = append(rows, fmt.Sprintf("| %s | %v | %v | %d/%v | %d/%v | %v | %d→%d | %s |",
			o.name, srcAfter.clone == after.clone, before.clone != after.clone,
			srcAfter.priv, srcAfter.shares, after.priv, after.shares,
			before.ino == after.ino, before.gen, after.gen, secondInfo))
		if srcBefore.clone != srcAfter.clone {
			rows = append(rows, fmt.Sprintf("|   (source clone id changed %d→%d) |||||||", srcBefore.clone, srcAfter.clone))
		}
		t.Logf("%s: before %+v after %+v src %+v", o.name, before, after, srcAfter)
	}
	// A -> B -> C chain.
	chain := filepath.Join(dir, "chain")
	must(t, os.MkdirAll(filepath.Join(chain, "A"), 0o755))
	must(t, os.WriteFile(filepath.Join(chain, "A", "f"), content, 0o644))
	_, err := CloneTree(filepath.Join(chain, "A"), filepath.Join(chain, "B"))
	must(t, err)
	_, err = CloneTree(filepath.Join(chain, "B"), filepath.Join(chain, "C"))
	must(t, err)
	a, b, c := cstat(t, filepath.Join(chain, "A", "f")), cstat(t, filepath.Join(chain, "B", "f")), cstat(t, filepath.Join(chain, "C", "f"))
	rows = append(rows, fmt.Sprintf("| chain A→B→C untouched | A==B %v, B==C %v | | A %d/%v | B %d/%v C %d/%v | | | |",
		a.clone == b.clone, b.clone == c.clone, a.priv, a.shares, b.priv, b.shares, c.priv, c.shares))
	pwrite(t, filepath.Join(chain, "B", "f"), 100, []byte{'X'}, 0)
	a, b, c = cstat(t, filepath.Join(chain, "A", "f")), cstat(t, filepath.Join(chain, "B", "f")), cstat(t, filepath.Join(chain, "C", "f"))
	rows = append(rows, fmt.Sprintf("| chain, then write B | A==B %v, A==C %v | | A %d/%v | B %d/%v C %d/%v | | | |",
		a.clone == b.clone, a.clone == c.clone, a.priv, a.shares, b.priv, b.shares, c.priv, c.shares))
	t.Logf("chain ids A=%d B=%d C=%d", a.clone, b.clone, c.clone)
	// A file that was never cloned.
	lone := filepath.Join(chain, "lone")
	must(t, os.WriteFile(lone, content, 0o644))
	l := cstat(t, lone)
	rows = append(rows, fmt.Sprintf("| never-cloned file | id=%d ino=%d (id==ino %v) | | %d/%v | | | | |", l.clone, l.ino, l.clone == l.ino, l.priv, l.shares))
	t.Log("\n" + strings.Join(rows, "\n"))
}

func TestBenchHardLinks(t *testing.T) {
	base := benchOnly(t)
	dir := filepath.Join(base, "bench-hardlinks")
	os.RemoveAll(dir)
	defer os.RemoveAll(dir)
	src := filepath.Join(dir, "src")
	write(t, filepath.Join(src, "a"), "hello")
	must(t, os.MkdirAll(filepath.Join(src, "sub"), 0o755))
	must(t, os.Link(filepath.Join(src, "a"), filepath.Join(src, "sub", "b")))
	_, err := CloneTree(src, filepath.Join(dir, "tree"))
	must(t, err)
	_, err = ClonePerFile(src, filepath.Join(dir, "cp"))
	must(t, err)
	for _, name := range []string{"src", "tree", "cp"} {
		m, _, err := ScanClone(filepath.Join(dir, name), ScanOptions{})
		must(t, err)
		a, b := m["a"], m["sub/b"]
		t.Logf("%-4s a: ino %d links %d clone %d | sub/b: ino %d links %d clone %d | linked=%v",
			name, a.Ino, a.LinkCount, a.CloneID, b.Ino, b.LinkCount, b.CloneID, a.Ino == b.Ino)
	}
	pwrite(t, filepath.Join(dir, "tree", "a"), 0, []byte("J"), 0)
	got, _ := os.ReadFile(filepath.Join(dir, "tree", "sub", "b"))
	srcGot, _ := os.ReadFile(filepath.Join(src, "a"))
	t.Logf("after writing tree/a: tree/sub/b=%q src/a=%q", got, srcGot)
}

type latencies []time.Duration

func (l latencies) summary() string {
	if len(l) == 0 {
		return "no ops"
	}
	s := slices.Clone(l)
	slices.Sort(s)
	q := func(f float64) time.Duration { return s[min(len(s)-1, int(f*float64(len(s))))] }
	return fmt.Sprintf("ops %d p50 %s p99 %s max %s", len(s), ms(q(0.5)), ms(q(0.99)), ms(s[len(s)-1]))
}

// writer creates and writes 1 KiB files in dir until stop closes, recording
// each create+write+close latency together with its start time.
func writer(dir string, stop <-chan struct{}) (func() ([]time.Time, latencies), error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	var starts []time.Time
	var lats latencies
	done := make(chan struct{})
	buf := make([]byte, 1024)
	go func() {
		defer close(done)
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			s := time.Now()
			f, err := os.OpenFile(filepath.Join(dir, fmt.Sprintf("w%06d", i)), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
			if err == nil {
				f.Write(buf)
				f.Close()
			}
			starts = append(starts, s)
			lats = append(lats, time.Since(s))
		}
	}()
	return func() ([]time.Time, latencies) { <-done; return starts, lats }, nil
}

func TestBenchStall(t *testing.T) {
	base := benchOnly(t)
	t150 := benchTree(t, base, "t150k", 1500, 100)
	t150b := benchTree(t, base, "t150k-b", 1500, 100) // an unrelated tree for the "other tree" case
	work := filepath.Join(base, "bench-stall")
	os.RemoveAll(work)
	must(t, os.MkdirAll(work, 0o755))
	defer func() {
		os.RemoveAll(work)
		os.RemoveAll(filepath.Join(t150, "stall-writer"))
	}()

	// Rounds interleave the three cases so that background load on the
	// shared machine hits them alike. Clones are kept until the end so that
	// deleting them does not overlap a measurement.
	measure := func(label, writeDir, cloneSrc string, r int) {
		os.RemoveAll(writeDir)
		stop := make(chan struct{})
		wait, err := writer(writeDir, stop)
		must(t, err)
		time.Sleep(300 * time.Millisecond)
		var cloneDur time.Duration
		dst := filepath.Join(work, fmt.Sprintf("clone-%d-%s", r, strings.Fields(label)[0]))
		from := time.Now()
		if cloneSrc == "" {
			time.Sleep(5 * time.Second)
		} else {
			cloneDur, err = CloneTree(cloneSrc, dst)
			must(t, err)
		}
		to := time.Now()
		time.Sleep(100 * time.Millisecond)
		close(stop)
		starts, lats := wait()
		var in latencies
		before := 0
		for i, s := range starts {
			if e := s.Add(lats[i]); e.After(from) && s.Before(to) {
				in = append(in, lats[i])
			} else if !e.After(from) {
				before++
			}
		}
		extra := ""
		if cloneSrc != "" && strings.HasPrefix(writeDir, cloneSrc) {
			// Files the writer finished before the clone started vs files in
			// the clone: more means the clone is not a point-in-time copy.
			m, _, err := ScanClone(filepath.Join(dst, "stall-writer"), ScanOptions{SkipBlockStats: true})
			must(t, err)
			torn := 0
			for _, e := range m {
				if e.Size != 1024 {
					torn++
				}
			}
			extra = fmt.Sprintf("; writer files done before clone start %d, in clone %d (size!=1KiB: %d)", before, len(m), torn)
		}
		t.Logf("round %d %s: clone %s; writes during window: %s%s", r, label, ms(cloneDur), in.summary(), extra)
	}
	wdir := filepath.Join(t150, "stall-writer")
	for r := 0; r < 3; r++ {
		measure("baseline (no clone, 5 s window), writer in t150k", wdir, "", r)
		measure("same-tree: clone t150k, writer in t150k", wdir, t150, r)
		measure("other-tree: clone t150k-b, writer in t150k", wdir, t150b, r)
	}
}

func TestBenchFSEvents(t *testing.T) {
	base := benchOnly(t)
	fi, err := os.Stat("/Volumes/External/.fseventsd")
	t.Logf(".fseventsd present: %v (err %v)", err == nil && fi.IsDir(), err)
	if _, err := os.Stat("/Volumes/External/.fseventsd/no_log"); err == nil {
		t.Log(".fseventsd/no_log present: history disabled")
	}
	dir := filepath.Join(base, "bench-fsevents")
	os.RemoveAll(dir)
	must(t, os.MkdirAll(dir, 0o755))
	defer os.RemoveAll(dir)
	rdir, _ := filepath.EvalSymlinks(dir)

	summarize := func(evs []FSEvent) (map[string]uint32, int) {
		agg := map[string]uint32{}
		n := 0
		for _, e := range evs {
			if e.HistoryDone() {
				continue
			}
			n++
			agg[e.Path] |= e.Flags
		}
		return agg, n
	}

	id0 := CurrentEventID()
	start := time.Now()
	for i := 0; i < 100; i++ {
		must(t, os.WriteFile(filepath.Join(dir, fmt.Sprintf("f%03d", i)), []byte("data"), 0o644))
	}
	writeDur := time.Since(start)
	q := time.Now()
	evs, err := EventsSince([]string{dir}, id0, 30*time.Second)
	must(t, err)
	agg, n := summarize(evs)
	missing := 0
	flagSet := map[string]int{}
	for i := 0; i < 100; i++ {
		f, ok := agg[filepath.Join(rdir, fmt.Sprintf("f%03d", i))]
		if !ok {
			missing++
			continue
		}
		flagSet[FlagString(f)]++
	}
	lossy := 0
	for _, e := range evs {
		if e.Lossy() {
			lossy++
		}
	}
	t.Logf("100 creates (%s): EventsSince %s, %d events, %d paths, missing %d, lossy %d, flags %v",
		ms(writeDur), ms(time.Since(q)), n, len(agg), missing, lossy, flagSet)

	id1 := CurrentEventID()
	p := filepath.Join(dir, "f000")
	must(t, os.Remove(p))
	must(t, os.WriteFile(p, []byte("again"), 0o644))
	evs, err = EventsSince([]string{dir}, id1, 30*time.Second)
	must(t, err)
	for _, e := range evs {
		t.Logf("delete+recreate: id %d %s %s", e.ID, strings.TrimPrefix(e.Path, rdir), FlagString(e.Flags))
	}

	id2 := CurrentEventID()
	must(t, os.Rename(filepath.Join(dir, "f001"), filepath.Join(dir, "g001")))
	evs, err = EventsSince([]string{dir}, id2, 30*time.Second)
	must(t, err)
	for _, e := range evs {
		t.Logf("rename: id %d %s %s", e.ID, strings.TrimPrefix(e.Path, rdir), FlagString(e.Flags))
	}

	id3 := CurrentEventID()
	pwrite(t, filepath.Join(dir, "f002"), 0, []byte("X"), 0)
	must(t, os.Chmod(filepath.Join(dir, "f003"), 0o600))
	run(t, "/usr/bin/xattr", "-w", "user.spike", "v", filepath.Join(dir, "f004"))
	run(t, "/usr/bin/touch", filepath.Join(dir, "f005"))
	must(t, os.WriteFile(filepath.Join(dir, "f006.tmp"), []byte("new"), 0o644))
	must(t, os.Rename(filepath.Join(dir, "f006.tmp"), filepath.Join(dir, "f006")))
	evs, err = EventsSince([]string{dir}, id3, 30*time.Second)
	must(t, err)
	for _, e := range evs {
		t.Logf("write/chmod/xattr/touch/atomic-replace: id %d %s %s", e.ID, strings.TrimPrefix(e.Path, rdir), FlagString(e.Flags))
	}

	// Cloning a 20k tree into the watched directory.
	t20 := benchTree(t, base, "t20k", 200, 100)
	id4 := CurrentEventID()
	_, err = CloneTree(t20, filepath.Join(dir, "clone20k"))
	must(t, err)
	evs, err = EventsSince([]string{dir}, id4, 30*time.Second)
	must(t, err)
	_, n = summarize(evs)
	for i, e := range evs {
		if i < 5 {
			t.Logf("CloneTree 20k into watched dir: id %d %s %s", e.ID, strings.TrimPrefix(e.Path, rdir), FlagString(e.Flags))
		}
	}
	t.Logf("CloneTree 20k into watched dir: %d events total", n)
	// Edits inside the clone are reported per file.
	id5 := CurrentEventID()
	for i := 0; i < 10; i++ {
		pwrite(t, filepath.Join(dir, "clone20k", fmt.Sprintf("d%03d", i), "f000"), 0, []byte("Z"), 0)
	}
	evs, err = EventsSince([]string{filepath.Join(dir, "clone20k")}, id5, 30*time.Second)
	must(t, err)
	agg, n = summarize(evs)
	t.Logf("10 writes inside clone: %d events, %d paths", n, len(agg))

	// Replay of an older window: everything since id0 (several seconds and
	// many unrelated events ago) for the whole directory.
	q = time.Now()
	evs, err = EventsSince([]string{dir}, id0, 60*time.Second)
	must(t, err)
	_, n = summarize(evs)
	t.Logf("replay since id0 for the whole bench dir: %d events in %s", n, ms(time.Since(q)))

	// Replay of a large burst: 20k file creates in one directory tree.
	burst := filepath.Join(dir, "burst")
	id6 := CurrentEventID()
	must(t, os.MkdirAll(burst, 0o755))
	for d := 0; d < 20; d++ {
		dd := filepath.Join(burst, fmt.Sprintf("d%02d", d))
		must(t, os.Mkdir(dd, 0o755))
		for f := 0; f < 1000; f++ {
			must(t, os.WriteFile(filepath.Join(dd, fmt.Sprintf("f%04d", f)), []byte("b"), 0o644))
		}
	}
	q = time.Now()
	evs, err = EventsSince([]string{burst}, id6, 60*time.Second)
	must(t, err)
	agg, n = summarize(evs)
	lossy = 0
	for _, e := range evs {
		if e.Lossy() {
			lossy++
		}
	}
	t.Logf("20k-create burst: %d events, %d unique paths, lossy %d, replay %s", n, len(agg), lossy, ms(time.Since(q)))

	// A timeout on an id far in the past still returns what was seen.
	_, err = EventsSince([]string{dir}, id0, time.Nanosecond)
	t.Logf("1ns timeout: err=%v (ErrTimeout=%v)", err, errors.Is(err, ErrTimeout))
}

func TestBenchCrossVolume(t *testing.T) {
	base := benchOnly(t)
	src := filepath.Join(base, "bench-xdev")
	os.RemoveAll(src)
	defer os.RemoveAll(src)
	write(t, filepath.Join(src, "f"), "x")
	dst := filepath.Join(os.TempDir(), fmt.Sprintf("darwinfs-xdev-%d", os.Getpid()))
	defer os.RemoveAll(dst)
	_, err := CloneTree(src, dst)
	t.Logf("CloneTree %s -> %s: %v (EXDEV=%v)", src, dst, err, errors.Is(err, unix.EXDEV))
	dst2 := "/tmp/darwinfs-xdev"
	os.RemoveAll(dst2)
	defer os.RemoveAll(dst2)
	_, err = CloneTree(src, dst2)
	t.Logf("CloneTree -> /tmp: %v (EXDEV=%v)", err, errors.Is(err, unix.EXDEV))
	if !errors.Is(err, ErrCrossVolume) {
		t.Errorf("want ErrCrossVolume, got %v", err)
	}
}
