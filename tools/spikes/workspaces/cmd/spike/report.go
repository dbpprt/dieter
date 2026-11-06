package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"

	"dieter.spike/workspaces/core"
)

func cmdReport(args []string) error {
	fs := flag.NewFlagSet("report", flag.ExitOnError)
	out := fs.String("out", "", "markdown output (default stdout)")
	_ = fs.Parse(args)
	var rows []Row
	for _, f := range fs.Args() {
		r, err := readRows(f)
		if err != nil {
			return err
		}
		rows = append(rows, r...)
	}
	w := io.Writer(os.Stdout)
	if *out != "" {
		f, err := os.Create(*out)
		if err != nil {
			return err
		}
		defer f.Close()
		w = f
	}
	report(w, rows)
	return nil
}

func readRows(path string) ([]Row, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var rows []Row
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64<<20), 64<<20)
	for sc.Scan() {
		var r Row
		if err := json.Unmarshal(sc.Bytes(), &r); err != nil {
			return nil, err
		}
		rows = append(rows, r)
	}
	return rows, sc.Err()
}

type agg struct {
	all, git         core.Score
	kind             int
	durs             []time.Duration
	missed, extra    map[string][]string // scenario -> sample paths
	errs             int
	scenariosPerfect map[string]bool
}

func (a *agg) add(sc string, rr RecResult) {
	if a.missed == nil {
		a.missed, a.extra, a.scenariosPerfect = map[string][]string{}, map[string][]string{}, map[string]bool{}
	}
	a.all.TP += rr.All.TP
	a.all.FP += rr.All.FP
	a.all.FN += rr.All.FN
	a.git.TP += rr.Git.TP
	a.git.FP += rr.Git.FP
	a.git.FN += rr.Git.FN
	a.kind += rr.All.KindMismatch
	a.durs = append(a.durs, rr.Duration)
	if rr.Err != "" {
		a.errs++
	}
	if len(rr.All.Missed) > 0 {
		a.missed[sc] = appendSample(a.missed[sc], rr.All.Missed)
	}
	if len(rr.All.Extra) > 0 {
		a.extra[sc] = appendSample(a.extra[sc], rr.All.Extra)
	}
}

func appendSample(dst, src []string) []string {
	for _, s := range src {
		if len(dst) >= 3 {
			break
		}
		dst = append(dst, s)
	}
	return dst
}

func pct(d []time.Duration, p float64) time.Duration {
	if len(d) == 0 {
		return 0
	}
	s := append([]time.Duration{}, d...)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	i := int(float64(len(s)-1) * p)
	return s[i]
}

func ms(d time.Duration) string { return fmt.Sprintf("%.0f", float64(d)/float64(time.Millisecond)) }

func report(w io.Writer, rows []Row) {
	type key struct{ plat, prov, drv string }
	groups := map[key][]Row{}
	var keys []key
	for _, r := range rows {
		k := key{r.Platform, r.Provider, r.Driver}
		if _, ok := groups[k]; !ok {
			keys = append(keys, k)
		}
		groups[k] = append(groups[k], r)
	}
	sort.Slice(keys, func(i, j int) bool {
		a, b := keys[i], keys[j]
		return a.plat+a.drv+a.prov < b.plat+b.drv+b.prov
	})
	for _, k := range keys {
		rs := groups[k]
		scen := map[string]bool{}
		errs := 0
		var turnDur, createDur []time.Duration
		for _, r := range rs {
			scen[r.Scenario] = true
			if r.Phase == "error" || r.Error != "" {
				errs++
			}
			if r.Phase == "turn" {
				turnDur = append(turnDur, r.TurnTime)
				if r.Turn == 1 {
					createDur = append(createDur, r.View.Create)
				}
			}
		}
		fmt.Fprintf(w, "\n### %s · %s · %s\n\n", k.plat, k.prov, k.drv)
		oracle := ""
		for _, r := range rs {
			if r.Oracle != "" {
				oracle = r.Oracle
				break
			}
		}
		fmt.Fprintf(w, "%d scenarios, %d rows, %d rows with errors. Oracle: %s. View create p50 %s ms; turn p50 %s ms, p95 %s ms.\n\n",
			len(scen), len(rs), errs, oracle, ms(pct(createDur, .5)), ms(pct(turnDur, .5)), ms(pct(turnDur, .95)))
		recs := map[string]*agg{}
		var names []string
		harness := &agg{}
		hasHarness := false
		for _, r := range rs {
			if r.Phase == "error" {
				continue
			}
			for n, rr := range r.Recorders {
				if recs[n] == nil {
					recs[n] = &agg{}
					names = append(names, n)
				}
				recs[n].add(r.Scenario+phaseTag(r), rr)
			}
			if r.Harness != nil {
				hasHarness = true
				harness.add(r.Scenario+phaseTag(r), *r.Harness)
			}
		}
		sort.Strings(names)
		if hasHarness {
			recs["harness-reported"] = harness
			names = append([]string{"harness-reported"}, names...)
		}
		fmt.Fprintln(w, "| recorder | all TP/FP/FN | git-scope TP/FP/FN | kind mismatches | p50 ms | p95 ms | errors |")
		fmt.Fprintln(w, "| --- | --- | --- | --- | --- | --- | --- |")
		for _, n := range names {
			a := recs[n]
			fmt.Fprintf(w, "| %s | %d/%d/%d | %d/%d/%d | %d | %s | %s | %d |\n", n, a.all.TP, a.all.FP, a.all.FN,
				a.git.TP, a.git.FP, a.git.FN, a.kind, ms(pct(a.durs, .5)), ms(pct(a.durs, .95)), a.errs)
		}
		for _, n := range names {
			a := recs[n]
			if len(a.missed) == 0 && len(a.extra) == 0 {
				continue
			}
			fmt.Fprintf(w, "\n**%s** misses / extras by scenario:\n\n", n)
			var scs []string
			seen := map[string]bool{}
			for s := range a.missed {
				if !seen[s] {
					scs, seen[s] = append(scs, s), true
				}
			}
			for s := range a.extra {
				if !seen[s] {
					scs, seen[s] = append(scs, s), true
				}
			}
			sort.Strings(scs)
			for _, s := range scs {
				fmt.Fprintf(w, "- %s: missed %s; extra %s\n", s, list(a.missed[s]), list(a.extra[s]))
			}
		}
		// Escapes, refs and errors.
		var notes []string
		for _, r := range rs {
			if len(r.Escapes) > 0 {
				var parts []string
				for n, p := range r.Escapes {
					parts = append(parts, fmt.Sprintf("%s=%s", n, list(p)))
				}
				sort.Strings(parts)
				notes = append(notes, fmt.Sprintf("%s%s escapes: %s", r.Scenario, phaseTag(r), strings.Join(parts, "; ")))
			}
			if len(r.RefsMoved) > 0 {
				notes = append(notes, fmt.Sprintf("%s%s refs moved: %s", r.Scenario, phaseTag(r), strings.Join(r.RefsMoved, ", ")))
			}
			if r.Error != "" {
				e := r.Error
				if len(e) > 160 {
					e = e[:160] + "…"
				}
				notes = append(notes, fmt.Sprintf("%s%s error: %s", r.Scenario, phaseTag(r), e))
			}
			if r.Phase == "late" && len(r.Truth) > 0 {
				notes = append(notes, fmt.Sprintf("%s late writes after the turn: %s", r.Scenario, list(r.Truth.Paths())))
			}
		}
		if len(notes) > 0 {
			fmt.Fprintln(w, "\nNotes:")
			fmt.Fprintln(w)
			for _, n := range notes {
				fmt.Fprintln(w, "- "+n)
			}
		}
		if hasHarness {
			fmt.Fprintln(w, "\nHarness-reported vs truth (git scope) per scenario:")
			fmt.Fprintln(w)
			fmt.Fprintln(w, "| scenario | truth (git) | reported TP/FP/FN | missed | extra |")
			fmt.Fprintln(w, "| --- | --- | --- | --- | --- |")
			for _, r := range rs {
				if r.Harness == nil || r.Phase != "turn" {
					continue
				}
				n := 0
				for _, c := range r.Truth {
					if !c.Ignored {
						n++
					}
				}
				h := r.Harness.Git
				fmt.Fprintf(w, "| %s%s r%d | %d | %d/%d/%d | %s | %s |\n", r.Scenario, phaseTag(r), r.Rep, n, h.TP, h.FP, h.FN, list(h.Missed), list(h.Extra))
			}
		}
	}
}

func phaseTag(r Row) string {
	if r.Phase == "late" {
		return "/late"
	}
	if r.Turn > 1 {
		return fmt.Sprintf("/t%d", r.Turn)
	}
	return ""
}

func list(s []string) string {
	if len(s) == 0 {
		return "–"
	}
	if len(s) > 3 {
		return "`" + strings.Join(s[:3], "`, `") + fmt.Sprintf("` +%d", len(s)-3)
	}
	return "`" + strings.Join(s, "`, `") + "`"
}
