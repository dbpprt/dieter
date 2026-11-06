package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"dieter.spike/workspaces/claudedrv"
	"dieter.spike/workspaces/codexdrv"
	"dieter.spike/workspaces/core"
	"dieter.spike/workspaces/scenarios"
	"dieter.spike/workspaces/shadow"
	"dieter.spike/workspaces/tree"
	"dieter.spike/workspaces/views"
)

// recorder observes a view. The first mark establishes a baseline and returns
// nil; every later mark returns what changed since the previous mark.
type recorder interface {
	name() string
	mark() (core.ChangeSet, time.Duration, error)
}

// RecResult is one recorder's view of one turn.
type RecResult struct {
	Changes  core.ChangeSet `json:"changes"`
	Duration time.Duration  `json:"duration"`
	Err      string         `json:"err,omitempty"`
	All      core.Score     `json:"all"`
	Git      core.Score     `json:"git"`
}

// Row is one turn (or the late window) of one scenario run.
type Row struct {
	Run       string               `json:"run"`
	Platform  string               `json:"platform"`
	Provider  string               `json:"provider"`
	Driver    string               `json:"driver"`
	Scenario  string               `json:"scenario"`
	Title     string               `json:"title"`
	Rep       int                  `json:"rep"`
	Turn      int                  `json:"turn"`
	Phase     string               `json:"phase"` // turn | late
	Oracle    string               `json:"oracle"`
	Truth     core.ChangeSet       `json:"truth"`
	Recorders map[string]RecResult `json:"recorders"`
	Harness   *RecResult           `json:"harness,omitempty"`
	Detail    map[string]any       `json:"detail,omitempty"`
	Escapes   map[string][]string  `json:"escapes,omitempty"`
	RefsMoved []string             `json:"refsMoved,omitempty"`
	View      views.Timing         `json:"view"`
	TurnTime  time.Duration        `json:"turnTime"`
	Error     string               `json:"error,omitempty"`
}

type runOpts struct {
	root, source, base, assets, sentinel, out, logs string
	provider, driver                                string
	scenarios                                       map[string]bool
	repeat                                          int
	keep                                            bool
	codexBin, codexHome, codexModel, codexEffort    string
	codexAuth                                       string
	claudeNodeDir, claudeConfigDir, claudeModel     string
	claudeCreds                                     string
	quiet, lateWait                                 time.Duration
}

func parseRun(args []string) (*runOpts, error) {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	o := &runOpts{}
	ids := fs.String("scenarios", "", "comma-separated scenario ids (default all)")
	fs.StringVar(&o.root, "root", "", "run root (views, sessions, shadow, logs)")
	fs.StringVar(&o.source, "source", "", "operator checkout (fixture repository)")
	fs.StringVar(&o.base, "base", "", "quiescent base copy (default <root>/base)")
	fs.StringVar(&o.assets, "assets", "", "fixture assets dir")
	fs.StringVar(&o.out, "out", "", "results JSONL (default <root>/results.jsonl)")
	fs.StringVar(&o.provider, "provider", "", "view provider")
	fs.StringVar(&o.driver, "driver", "script", "script|codex|claude")
	fs.IntVar(&o.repeat, "repeat", 1, "repetitions")
	fs.BoolVar(&o.keep, "keep", false, "keep views")
	fs.StringVar(&o.codexBin, "codex-bin", "", "codex binary")
	fs.StringVar(&o.codexHome, "codex-home", "", "CODEX_HOME shared by the run (default <root>/codex-home)")
	fs.StringVar(&o.codexModel, "codex-model", "", "codex model")
	fs.StringVar(&o.codexEffort, "codex-effort", "low", "codex effort")
	fs.StringVar(&o.codexAuth, "codex-auth", "", "auth.json to copy (default ~/.codex/auth.json)")
	fs.StringVar(&o.claudeNodeDir, "claude-node-dir", "", "node dir with the SDK")
	fs.StringVar(&o.claudeConfigDir, "claude-config-dir", "", "CLAUDE_CONFIG_DIR shared by the run (default <root>/claude-config)")
	fs.StringVar(&o.claudeModel, "claude-model", "claude-sonnet-5-5", "claude model")
	fs.StringVar(&o.claudeCreds, "claude-creds", "", "credentials file (default keychain on darwin)")
	fs.DurationVar(&o.quiet, "quiet", 2*time.Second, "settle time after a turn before the late check")
	fs.DurationVar(&o.lateWait, "late-wait", 8*time.Second, "wait for scenarios with background writers")
	if err := fs.Parse(args); err != nil {
		return nil, err
	}
	if o.root == "" || o.source == "" || o.provider == "" {
		return nil, fmt.Errorf("run needs -root, -source and -provider")
	}
	if o.base == "" {
		o.base = filepath.Join(o.root, "base")
	}
	if o.out == "" {
		o.out = filepath.Join(o.root, "results.jsonl")
	}
	if o.codexHome == "" {
		o.codexHome = filepath.Join(o.root, "codex-home")
	}
	if o.claudeConfigDir == "" {
		o.claudeConfigDir = filepath.Join(o.root, "claude-config")
	}
	o.sentinel = filepath.Join(o.root, "sentinel")
	o.logs = filepath.Join(o.root, "logs")
	if *ids != "" {
		o.scenarios = map[string]bool{}
		for _, id := range strings.Split(*ids, ",") {
			o.scenarios[strings.TrimSpace(id)] = true
		}
	}
	return o, nil
}

// runEnv is shared state for one run.
type runEnv struct {
	o        *runOpts
	env      views.Env
	prov     views.Provider
	shadow   *shadow.Repo
	baseHead string
	baseMan  *tree.Manifest
	self     string
	mu       sync.Mutex
	out      *os.File
	plat     *platformState
}

func newRunEnv(o *runOpts) (*runEnv, error) {
	for _, d := range []string{o.root, o.sentinel, o.logs, filepath.Join(o.root, "tmp")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return nil, err
		}
	}
	prov, err := views.Get(o.provider)
	if err != nil {
		return nil, err
	}
	env := views.Env{Source: o.source, Base: o.base, Root: o.root}
	if d, err := prov.PrepareBase(env); err != nil {
		return nil, fmt.Errorf("prepare base: %w", err)
	} else if d > 0 {
		fmt.Fprintf(os.Stderr, "base prepared in %s\n", d)
	}
	sh, err := shadow.Open(filepath.Join(o.root, "shadow.git"), filepath.Join(o.source, ".git"))
	if err != nil {
		return nil, err
	}
	head, err := shadow.Rev(o.source, "HEAD")
	if err != nil {
		return nil, err
	}
	self, err := os.Executable()
	if err != nil {
		return nil, err
	}
	out, err := os.OpenFile(o.out, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return nil, err
	}
	re := &runEnv{o: o, env: env, prov: prov, shadow: sh, baseHead: head, self: self, out: out}
	if re.plat, err = newPlatformState(re); err != nil {
		return nil, err
	}
	return re, nil
}

func (re *runEnv) write(r Row) {
	re.mu.Lock()
	defer re.mu.Unlock()
	b, _ := json.Marshal(r)
	re.out.Write(append(b, '\n'))
}

func (re *runEnv) newDriver(ctx context.Context, v *views.View, id string) (core.Driver, error) {
	return re.newDriverNamed(ctx, v, id, re.o.driver)
}

func (re *runEnv) newDriverNamed(ctx context.Context, v *views.View, id, name string) (core.Driver, error) {
	o := re.o
	switch name {
	case "script":
		return &scriptDriver{self: re.self, launcher: v.Launcher, tmp: filepath.Join(o.root, "tmp")}, nil
	case "codex":
		if _, err := os.Stat(filepath.Join(o.codexHome, "auth.json")); err != nil {
			var err error
			if o.codexAuth != "" {
				err = codexdrv.PrepareHomeFromFile(o.codexHome, o.codexAuth)
			} else {
				err = codexdrv.PrepareHome(o.codexHome)
			}
			if err != nil {
				return nil, err
			}
		}
		return codexdrv.New(ctx, codexdrv.Config{CodexBin: o.codexBin, CodexHome: o.codexHome,
			Model: o.codexModel, Effort: o.codexEffort, Launcher: v.Launcher, TurnTimeout: 8 * time.Minute})
	case "claude":
		if err := os.MkdirAll(o.claudeConfigDir, 0o700); err != nil {
			return nil, err
		}
		return claudedrv.New(ctx, claudedrv.Config{NodeDir: o.claudeNodeDir, ConfigDir: o.claudeConfigDir,
			Model: o.claudeModel, CredentialsFile: o.claudeCreds, Launcher: v.Launcher, TurnTimeout: 8 * time.Minute})
	}
	return nil, fmt.Errorf("unknown driver %q", name)
}

// scriptDriver performs steps itself (inside the view's launcher wrap).
type scriptDriver struct {
	self     string
	launcher core.Launcher
	tmp      string
	n        int
}

func (d *scriptDriver) Name() string { return "script" }
func (d *scriptDriver) Close() error { return nil }

func (d *scriptDriver) Turn(ctx context.Context, in core.TurnInput) (core.TurnResult, error) {
	start := time.Now()
	d.n++
	f := filepath.Join(d.tmp, fmt.Sprintf("steps-%d-%d.json", os.Getpid(), time.Now().UnixNano()))
	b, _ := json.Marshal(in.Steps)
	if err := os.WriteFile(f, b, 0o644); err != nil {
		return core.TurnResult{}, err
	}
	defer os.Remove(f)
	argv := append(append([]string{}, d.launcher.Wrap...), d.self, "exec-steps", "-steps", f)
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Dir = d.launcher.Dir
	cmd.Env = append(os.Environ(), d.launcher.Env...)
	out, err := cmd.CombinedOutput()
	res := core.TurnResult{Duration: time.Since(start)}
	if err != nil {
		res.Error = fmt.Sprintf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return res, nil
}

// hostOracle scans a host-visible view.
type hostOracle struct {
	dir  string
	prev core.Tree
}

func (h *hostOracle) name() string { return "oracle" }
func (h *hostOracle) mark() (core.ChangeSet, time.Duration, error) {
	start := time.Now()
	t, _, err := tree.Scan(h.dir, tree.ScanOptions{})
	if err != nil {
		return nil, 0, err
	}
	var cs core.ChangeSet
	if h.prev != nil {
		cs = core.DiffTrees(h.prev, t)
	}
	h.prev = t
	return cs, time.Since(start), nil
}

// shadowRec records turn snapshots of a host-visible view.
type shadowRec struct {
	re      *runEnv
	v       *views.View
	session string
	n       int
	prev    string
}

func (s *shadowRec) name() string { return "shadow" }
func (s *shadowRec) mark() (core.ChangeSet, time.Duration, error) {
	idx := filepath.Join(s.re.o.root, "idx", s.session+".index")
	parent := s.prev
	if parent == "" {
		parent = s.re.baseHead
	}
	snap, err := s.re.shadow.SnapshotWorkTree(s.v.HostDir, s.v.GitDir, idx, s.v.Index, parent,
		fmt.Sprintf("refs/sessions/%s/%d", s.session, s.n), fmt.Sprintf("%s turn %d", s.session, s.n))
	if err != nil {
		return nil, 0, err
	}
	s.n++
	var cs core.ChangeSet
	if s.prev != "" {
		cs, err = s.re.shadow.Diff(s.prev, snap.Commit)
	}
	s.prev = snap.Commit
	return cs, snap.Duration, err
}

// manifestRec is the stat-cached full-tree manifest (covers ignored paths).
type manifestRec struct {
	re   *runEnv
	dir  string
	prev *tree.Manifest
}

func (m *manifestRec) name() string { return "manifest" }
func (m *manifestRec) mark() (core.ChangeSet, time.Duration, error) {
	var cur *tree.Manifest
	var st tree.ManifestStats
	var err error
	if m.prev == nil && m.re.baseMan != nil {
		cur, st, err = tree.InheritManifest(m.re.baseMan, m.dir)
	} else {
		cur, st, err = tree.BuildManifest(m.dir, m.prev)
	}
	if err != nil {
		return nil, 0, err
	}
	var cs core.ChangeSet
	if m.prev != nil {
		cs = core.DiffTrees(m.prev.Tree(), cur.Tree())
	}
	m.prev = cur
	return cs, st.Duration, nil
}

// scanDirRec watches a directory outside the view (escape detection).
type scanDirRec struct {
	label, dir string
	prev       core.Tree
}

func (s *scanDirRec) name() string { return s.label }
func (s *scanDirRec) mark() (core.ChangeSet, time.Duration, error) {
	h := &hostOracle{dir: s.dir, prev: s.prev}
	cs, d, err := h.mark()
	s.prev = h.prev
	return cs, d, err
}

func cmdRun(args []string) error {
	o, err := parseRun(args)
	if err != nil {
		return err
	}
	re, err := newRunEnv(o)
	if err != nil {
		return err
	}
	defer re.out.Close()
	if bm, ok := re.plat.baseManifest(); ok {
		re.baseMan = bm
	}
	all := scenarios.Select(scenarios.All(scenarios.Env{Source: o.source, Sentinel: o.sentinel,
		Tmp: filepath.Join(o.root, "tmp"), Assets: o.assets}), o.scenarios)
	run := fmt.Sprintf("%s-%s-%s", o.provider, o.driver, time.Now().Format("150405"))
	for rep := 1; rep <= o.repeat; rep++ {
		for _, sc := range all {
			fmt.Fprintf(os.Stderr, "== %s %s rep %d\n", run, sc.ID, rep)
			if err := re.runScenario(run, sc, rep); err != nil {
				fmt.Fprintf(os.Stderr, "   error: %v\n", err)
				re.write(Row{Run: run, Platform: runtime.GOOS, Provider: o.provider, Driver: o.driver,
					Scenario: sc.ID, Title: sc.Title, Rep: rep, Phase: "error", Error: err.Error()})
			}
		}
	}
	return nil
}

func (re *runEnv) runScenario(run string, sc scenarios.Scenario, rep int) error {
	o := re.o
	id := fmt.Sprintf("%s-%s-%s-r%d-%d", strings.ToLower(sc.ID), o.provider, o.driver, rep, time.Now().UnixNano()%100000)
	v, timing, err := re.prov.Create(re.env, id)
	if err != nil {
		return fmt.Errorf("create view: %w", err)
	}
	defer func() {
		if !o.keep {
			if _, err := re.prov.Discard(re.env, v); err != nil {
				fmt.Fprintf(os.Stderr, "   discard: %v\n", err)
			}
		}
	}()
	oracle, oracleKind := re.plat.oracle(v, o.driver)
	recs := re.plat.recorders(v, id)
	escapes := []recorder{&scanDirRec{label: "sentinel", dir: o.sentinel}, &scanDirRec{label: "source", dir: o.source}}
	escapes = append(escapes, re.plat.escapeRecorders()...)
	mark := func(rs []recorder) (map[string]RecResult, error) {
		res := map[string]RecResult{}
		for _, r := range rs {
			cs, d, err := r.mark()
			rr := RecResult{Changes: cs, Duration: d}
			if err != nil {
				rr.Err = err.Error()
			}
			res[r.name()] = rr
		}
		return res, nil
	}
	if _, _, err := oracle.mark(); err != nil {
		return fmt.Errorf("oracle baseline: %w", err)
	}
	mark(recs)
	mark(escapes)
	var refsBefore map[string]string
	if v.HostDir != "" {
		refsBefore, _ = shadow.Refs(v.HostDir)
	}
	ctx := context.Background()
	drv, err := re.newDriver(ctx, v, id)
	if err != nil {
		return fmt.Errorf("driver: %w", err)
	}
	closed := false
	defer func() {
		if !closed {
			drv.Close()
		}
	}()
	ignoredRoot := v.HostDir
	if ignoredRoot == "" {
		ignoredRoot = re.env.Base
	}
	finish := func(r *Row, truth core.ChangeSet, rec map[string]RecResult, esc map[string]RecResult) {
		markIgnored(ignoredRoot, truth)
		r.Truth = truth
		r.Recorders = map[string]RecResult{}
		for n, rr := range rec {
			markIgnored(ignoredRoot, rr.Changes)
			rr.All = core.Compare(truth, rr.Changes, nil)
			rr.Git = core.Compare(truth, rr.Changes, notIgnored)
			r.Recorders[n] = rr
		}
		if r.Harness != nil {
			markIgnored(ignoredRoot, r.Harness.Changes)
			r.Harness.All = core.Compare(truth, r.Harness.Changes, nil)
			r.Harness.Git = core.Compare(truth, r.Harness.Changes, notIgnored)
		}
		r.Escapes = map[string][]string{}
		for n, e := range esc {
			if len(e.Changes) > 0 {
				r.Escapes[n] = e.Changes.Paths()
			}
		}
	}
	for ti, steps := range sc.Turns {
		row := Row{Run: run, Platform: runtime.GOOS, Provider: o.provider, Driver: o.driver, Scenario: sc.ID,
			Title: sc.Title, Rep: rep, Turn: ti + 1, Phase: "turn", Oracle: oracleKind, View: timing}
		res, err := drv.Turn(ctx, core.TurnInput{Prompt: core.RenderPrompt(steps), Steps: steps,
			LogPath: filepath.Join(o.logs, id+".jsonl")})
		row.TurnTime = res.Duration
		if err != nil && res.Error == "" {
			res.Error = err.Error()
		}
		row.Error = res.Error
		if o.driver != "script" {
			row.Harness = &RecResult{Changes: res.Reported, Duration: res.Duration, Err: res.Error}
			row.Detail = res.Detail
		}
		time.Sleep(o.quiet)
		truth, _, err := oracle.mark()
		if err != nil {
			return fmt.Errorf("oracle: %w", err)
		}
		rec, _ := mark(recs)
		esc, _ := mark(escapes)
		if v.HostDir != "" {
			refsAfter, _ := shadow.Refs(v.HostDir)
			row.RefsMoved = movedRefs(refsBefore, refsAfter)
			refsBefore = refsAfter
		}
		finish(&row, truth, rec, esc)
		re.write(row)
	}
	// Late window: anything written after the last turn ended.
	wait := o.quiet
	if sc.Late {
		wait = o.lateWait
	}
	time.Sleep(wait)
	row := Row{Run: run, Platform: runtime.GOOS, Provider: o.provider, Driver: o.driver, Scenario: sc.ID,
		Title: sc.Title, Rep: rep, Turn: len(sc.Turns) + 1, Phase: "late", Oracle: oracleKind, View: timing}
	truth, _, err := oracle.mark()
	if err != nil {
		return fmt.Errorf("late oracle: %w", err)
	}
	rec, _ := mark(recs)
	esc, _ := mark(escapes)
	finish(&row, truth, rec, esc)
	re.write(row)
	drv.Close()
	closed = true
	re.plat.cleanupSentinel(o)
	return nil
}

func notIgnored(c core.Change) bool { return !c.Ignored }

func markIgnored(root string, cs core.ChangeSet) {
	if len(cs) == 0 {
		return
	}
	ign, err := tree.Ignored(root, "", cs.Paths())
	if err != nil {
		return
	}
	tree.MarkIgnored(cs, ign)
}

func movedRefs(before, after map[string]string) []string {
	var out []string
	for k, v := range after {
		if before[k] != v {
			out = append(out, k)
		}
	}
	for k := range before {
		if _, ok := after[k]; !ok {
			out = append(out, k+" (deleted)")
		}
	}
	return out
}
