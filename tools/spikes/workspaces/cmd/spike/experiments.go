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

	"dieter.spike/workspaces/core"
	"dieter.spike/workspaces/shadow"
	"dieter.spike/workspaces/tree"
	"dieter.spike/workspaces/views"
)

func emit(path string, v any) {
	b, _ := json.Marshal(v)
	fmt.Println(string(b))
	if path == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	f.Write(append(b, '\n'))
}

// gitInView runs git inside a view (through its namespace wrap if any).
func gitInView(v *views.View, args ...string) (time.Duration, string, error) {
	argv := append(append([]string{}, v.Launcher.Wrap...), append([]string{"git"}, args...)...)
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = v.Launcher.Dir
	cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1")
	start := time.Now()
	out, err := cmd.CombinedOutput()
	return time.Since(start), string(out), err
}

func shInView(v *views.View, script string) error {
	argv := append(append([]string{}, v.Launcher.Wrap...), "sh", "-c", script)
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = v.Launcher.Dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%v: %s", err, out)
	}
	return nil
}

// cmdE1 measures view creation, first git status and discard.
func cmdE1(args []string) error {
	fs := flag.NewFlagSet("e1", flag.ExitOnError)
	root := fs.String("root", "", "run root")
	source := fs.String("source", "", "source checkout")
	fixture := fs.String("fixture", "", "fixture label for the report")
	providers := fs.String("providers", "", "comma-separated providers")
	runs := fs.Int("runs", 3, "runs per provider")
	out := fs.String("out", "", "JSONL output")
	_ = fs.Parse(args)
	env := views.Env{Source: *source, Base: filepath.Join(*root, "base"), Root: *root}
	for _, name := range strings.Split(*providers, ",") {
		p, err := views.Get(name)
		if err != nil {
			return err
		}
		baseTime, err := p.PrepareBase(env)
		if err != nil {
			return fmt.Errorf("%s base: %w", name, err)
		}
		for i := 1; i <= *runs; i++ {
			id := fmt.Sprintf("e1-%s-%d-%d", name, i, time.Now().UnixNano()%100000)
			free0 := freeBytes(*root)
			v, t, err := p.Create(env, id)
			if err != nil {
				emit(*out, map[string]any{"exp": "e1", "provider": name, "fixture": *fixture, "error": err.Error()})
				continue
			}
			free1 := freeBytes(*root)
			s1, o1, err1 := gitInView(v, "status", "--porcelain")
			s2, _, _ := gitInView(v, "status", "--porcelain")
			row := map[string]any{"exp": "e1", "platform": runtime.GOOS, "provider": name, "fixture": *fixture, "run": i,
				"baseMs": ms(baseTime), "createMs": ms(t.Create), "steps": t.Steps, "status1Ms": ms(s1), "status2Ms": ms(s2),
				"status1Lines": countLines(o1), "freeDeltaMB": float64(free0-free1) / (1 << 20)}
			if err1 != nil {
				row["statusErr"] = err1.Error()
			}
			d, err := p.Discard(env, v)
			row["discardMs"] = ms(d)
			if err != nil {
				row["discardErr"] = err.Error()
			}
			emit(*out, row)
		}
	}
	return nil
}

func countLines(s string) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	return len(strings.Split(s, "\n"))
}

// cmdSnapCost measures shadow snapshot latency with N modified files.
func cmdSnapCost(args []string) error {
	fs := flag.NewFlagSet("snapcost", flag.ExitOnError)
	root := fs.String("root", "", "run root")
	source := fs.String("source", "", "source checkout")
	fixture := fs.String("fixture", "", "fixture label")
	provider := fs.String("provider", "", "provider")
	mods := fs.String("mods", "0,10,100,1000", "modified tracked files per step")
	runs := fs.Int("runs", 3, "snapshots per step")
	out := fs.String("out", "", "JSONL output")
	_ = fs.Parse(args)
	o := &runOpts{root: *root, source: *source, base: filepath.Join(*root, "base"), provider: *provider,
		out: filepath.Join(*root, "snapcost-rows.jsonl"), sentinel: filepath.Join(*root, "sentinel"), logs: filepath.Join(*root, "logs")}
	re, err := newRunEnv(o)
	if err != nil {
		return err
	}
	if bm, ok := re.plat.baseManifest(); ok {
		re.baseMan = bm
	}
	id := fmt.Sprintf("snap-%s-%d", *provider, time.Now().UnixNano()%100000)
	v, _, err := re.prov.Create(re.env, id)
	if err != nil {
		return err
	}
	defer re.prov.Discard(re.env, v)
	recs := re.plat.recorders(v, id)
	for _, r := range recs {
		_, d, err := r.mark()
		row := map[string]any{"exp": "snapcost", "platform": runtime.GOOS, "fixture": *fixture, "provider": *provider,
			"recorder": r.name(), "mods": "baseline", "ms": ms(d)}
		if err != nil {
			row["err"] = err.Error()
		}
		emit(*out, row)
	}
	// Tracked files to touch: pkg/**/f*.txt.
	files, _ := views.Git(re.env.Base, "ls-files", "pkg")
	list := strings.Fields(files)
	for _, ns := range strings.Split(*mods, ",") {
		var n int
		fmt.Sscan(ns, &n)
		for r := 0; r < *runs; r++ {
			if n > 0 {
				if n > len(list) {
					n = len(list)
				}
				var b strings.Builder
				for i := 0; i < n; i++ {
					fmt.Fprintf(&b, "printf 'mod %d\\n' >> %s\n", r, list[(i*7+r)%len(list)])
				}
				if err := shInView(v, b.String()); err != nil {
					return err
				}
			}
			for _, rec := range recs {
				cs, d, err := rec.mark()
				row := map[string]any{"exp": "snapcost", "platform": runtime.GOOS, "fixture": *fixture, "provider": *provider,
					"recorder": rec.name(), "mods": n, "run": r, "ms": ms(d), "changes": len(cs)}
				if err != nil {
					row["err"] = err.Error()
				}
				emit(*out, row)
			}
		}
	}
	return nil
}

// cmdConcurrency runs several harness sessions in parallel views of one
// checkout, checks isolation, forks one view, publishes all sessions as
// branches and previews their merges.
func cmdConcurrency(args []string) error {
	// parseRun owns the flag set; the session drivers and the summary file
	// come from SPIKE_DRIVERS and SPIKE_SUMMARY.
	o, err := parseRun(append(args, "-scenarios", "none"))
	if err != nil {
		return err
	}
	drivers, report := "codex,codex,claude", os.Getenv("SPIKE_SUMMARY")
	if d := os.Getenv("SPIKE_DRIVERS"); d != "" {
		drivers = d
	}
	re, err := newRunEnv(o)
	if err != nil {
		return err
	}
	if bm, ok := re.plat.baseManifest(); ok {
		re.baseMan = bm
	}
	ctx := context.Background()
	names := strings.Split(drivers, ",")
	type sess struct {
		i      int
		driver string
		v      *views.View
		drv    core.Driver
		oracle recorder
		shadow recorder
		steps  [][]core.Step
		truth  []core.ChangeSet
		rep    []core.ChangeSet
		errs   []string
		snap   string
	}
	var ss []*sess
	for i, d := range names {
		id := fmt.Sprintf("conc-%d-%s-%d", i, d, time.Now().UnixNano()%100000)
		v, _, err := re.prov.Create(re.env, id)
		if err != nil {
			return err
		}
		label := fmt.Sprintf("session-%d", i)
		s := &sess{i: i, driver: d, v: v, steps: [][]core.Step{
			{
				{Tool: "edit", Path: "docs/guide.md", Old: "Guide version: 1", New: "Guide version: 1-" + label},
				{Tool: "edit", Path: label + ".md", Create: true, Content: "# " + label + "\n"},
				{Tool: "shell", Command: fmt.Sprintf(`perl -pi -e 's/const Greeting = "hello"/const Greeting = "%s"/' src/app/main.go`, label)},
			},
			{
				{Tool: "shell", Command: fmt.Sprintf("printf '%s turn two\\n' > %s-turn2.txt", label, label)},
			},
		}}
		s.oracle, _ = re.plat.oracle(v, d)
		for _, r := range re.plat.recorders(v, id) {
			if r.name() == "shadow" {
				s.shadow = r
			}
		}
		s.oracle.mark()
		s.shadow.mark()
		drv, err := re.newDriverNamed(ctx, v, id, d)
		if err != nil {
			return err
		}
		s.drv = drv
		ss = append(ss, s)
	}
	sourceBefore, _, _ := tree.Scan(o.source, tree.ScanOptions{})
	runTurn := func(turn int) {
		var wg sync.WaitGroup
		for _, s := range ss {
			wg.Add(1)
			go func(s *sess) {
				defer wg.Done()
				res, err := s.drv.Turn(ctx, core.TurnInput{Prompt: core.RenderPrompt(s.steps[turn]), Steps: s.steps[turn],
					LogPath: filepath.Join(o.logs, s.v.ID+".jsonl")})
				if err != nil {
					s.errs = append(s.errs, err.Error())
				}
				s.rep = append(s.rep, res.Reported)
			}(s)
		}
		wg.Wait()
		time.Sleep(o.quiet)
		for _, s := range ss {
			cs, _, err := s.oracle.mark()
			if err != nil {
				s.errs = append(s.errs, err.Error())
			}
			s.shadow.mark()
			s.truth = append(s.truth, cs)
		}
	}
	start := time.Now()
	runTurn(0)
	turn1 := time.Since(start)
	// Fork session 0's view after turn 1 (provider-specific copy).
	fork, forkTime, forkErr := forkView(re, ss[0].v)
	var forkTruth core.ChangeSet
	if forkErr == nil {
		fo, _ := re.plat.oracle(fork, "script")
		fo.mark()
		sd := &scriptDriver{self: re.self, launcher: fork.Launcher, tmp: filepath.Join(o.root, "tmp")}
		steps := []core.Step{{Tool: "shell", Command: "printf 'fork only\\n' > fork-only.txt && rm Makefile"}}
		sd.Turn(ctx, core.TurnInput{Steps: steps})
		forkTruth, _, _ = fo.mark()
		defer re.prov.Discard(re.env, fork)
	}
	runTurn(1)
	sourceAfter, _, _ := tree.Scan(o.source, tree.ScanOptions{})
	summary := map[string]any{"exp": "concurrency", "platform": runtime.GOOS, "provider": o.provider, "drivers": names,
		"turn1Wall": ms(turn1), "sourceChanged": core.DiffTrees(sourceBefore, sourceAfter).Paths()}
	var sessions []map[string]any
	var branches []string
	for _, s := range ss {
		s.drv.Close()
		sr := map[string]any{"session": s.i, "driver": s.driver, "errors": s.errs}
		var truths []any
		cross := []string{}
		for ti, t := range s.truth {
			markIgnored(re.env.Base, t)
			truths = append(truths, t.Paths())
			for _, p := range t.Paths() {
				if strings.Contains(p, "session-") && !strings.Contains(p, fmt.Sprintf("session-%d", s.i)) {
					cross = append(cross, p)
				}
			}
			if ti < len(s.rep) && s.rep[ti] != nil {
				sr[fmt.Sprintf("reportedTurn%d", ti+1)] = s.rep[ti].Paths()
			}
		}
		sr["truth"] = truths
		sr["crossSessionPaths"] = cross
		// Publish this session's last snapshot as a branch in the source.
		if sh, ok := s.shadow.(interface{ last() string }); ok {
			s.snap = sh.last()
		}
		branch := fmt.Sprintf("dieter/spike-%d-%d", s.i, time.Now().UnixNano()%100000)
		if s.snap != "" {
			c, err := re.shadow.Publish(o.source, re.baseHead, s.snap, branch, fmt.Sprintf("session %d (%s)", s.i, s.driver))
			if err != nil {
				sr["publishErr"] = err.Error()
			} else {
				sr["published"] = branch + "@" + c[:12]
				branches = append(branches, branch)
				files, _ := views.Git(o.source, "diff", "--name-status", re.baseHead, branch)
				sr["branchDiff"] = strings.Split(strings.TrimSpace(files), "\n")
			}
		}
		sessions = append(sessions, sr)
		if !o.keep {
			re.prov.Discard(re.env, s.v)
		}
	}
	summary["sessions"] = sessions
	var merges []map[string]any
	for i := 0; i < len(branches); i++ {
		for j := i + 1; j < len(branches); j++ {
			clean, conflicts, err := shadow.MergePreview(o.source, branches[i], branches[j])
			m := map[string]any{"a": branches[i], "b": branches[j], "clean": clean, "conflicts": conflicts}
			if err != nil {
				m["err"] = err.Error()
			}
			merges = append(merges, m)
		}
	}
	summary["mergePreview"] = merges
	if forkErr != nil {
		summary["forkErr"] = forkErr.Error()
	} else {
		summary["forkMs"] = ms(forkTime)
		summary["forkTruth"] = forkTruth.Paths()
		summary["parentTurn2Truth"] = ss[0].truth[len(ss[0].truth)-1].Paths()
	}
	status, _ := views.Git(o.source, "status", "--porcelain")
	summary["sourceStatus"] = status
	emit(report, summary)
	return nil
}

func (s *shadowRec) last() string { return s.prev }
