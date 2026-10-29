#!/usr/bin/env python3
"""Compact summary of spike results JSONL files (stdlib only).

summarize.py results.jsonl [...] > summary.md
Later files win over earlier ones for the same scenario row (reruns).
"""

import json
import sys
from collections import defaultdict, OrderedDict


def load(paths):
    """Later files and later passes win per (platform, provider, driver,
    scenario, rep, turn, phase), so reruns replace earlier rows."""
    rows = OrderedDict()
    for p in paths:
        with open(p) as f:
            for line in f:
                r = json.loads(line)
                k = (
                    r["platform"],
                    r["provider"],
                    r["driver"],
                    r["scenario"],
                    r["rep"],
                    r["turn"],
                    r["phase"],
                )
                rows.pop(k, None)
                rows[k] = r
    return list(rows.values())


def pct(vals, q):
    if not vals:
        return 0
    s = sorted(vals)
    return s[int((len(s) - 1) * q)]


def ms(ns):
    return round(ns / 1e6)


def main():
    rows = load(sys.argv[1:])
    groups = OrderedDict()
    for r in rows:
        groups.setdefault((r["platform"], r["provider"], r["driver"]), []).append(r)
    print("## Recorder accuracy (sum over all turns and late windows)\n")
    print(
        "| platform | provider | driver | recorder | all TP/FP/FN | git-scope TP/FP/FN | p50 ms | p95 ms |"
    )
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for (plat, prov, drv), rs in groups.items():
        acc = defaultdict(lambda: [0] * 6)
        durs = defaultdict(list)
        for r in rs:
            if r["phase"] == "error":
                continue
            recs = dict(r.get("recorders") or {})
            if r.get("harness"):
                recs["harness-reported"] = r["harness"]
            for n, rr in recs.items():
                a = acc[n]
                for i, k in enumerate(("TP", "FP", "FN")):
                    a[i] += rr["all"][k]
                    a[i + 3] += rr["git"][k]
                if n != "harness-reported":
                    durs[n].append(rr["duration"])
        for n in sorted(acc, key=lambda x: (x != "harness-reported", x)):
            a = acc[n]
            p50 = ms(pct(durs[n], 0.5)) if durs[n] else "–"
            p95 = ms(pct(durs[n], 0.95)) if durs[n] else "–"
            print(
                f"| {plat} | {prov} | {drv} | {n} | {a[0]}/{a[1]}/{a[2]} | {a[3]}/{a[4]}/{a[5]} | {p50} | {p95} |"
            )

    # Harness coverage per scenario (git scope), aggregated over reps.
    print(
        "\n## Harness-reported coverage per scenario (git scope, reported/true paths summed over reps)\n"
    )
    cov = defaultdict(lambda: defaultdict(lambda: [0, 0, 0]))
    titles = {}
    for r in rows:
        if r["phase"] != "turn" or not r.get("harness"):
            continue
        key = r["scenario"] + (f"/t{r['turn']}" if r["turn"] > 1 else "")
        titles[r["scenario"]] = r["title"]
        col = f"{r['platform']}/{r['provider']}/{r['driver']}"
        g = r["harness"]["git"]
        c = cov[key][col]
        c[0] += g["TP"]
        c[1] += g["TP"] + g["FN"]
        c[2] += g["FP"]
    cols = sorted({c for v in cov.values() for c in v})
    print("| scenario | " + " | ".join(cols) + " |")
    print("| --- | " + " | ".join("---" for _ in cols) + " |")
    for key in sorted(cov):
        cells = []
        for c in cols:
            v = cov[key].get(c)
            if not v:
                cells.append("–")
            elif v[1] == 0:
                cells.append("0/0" + (f" (+{v[2]} FP)" if v[2] else ""))
            else:
                mark = "✓" if v[0] == v[1] else ("✗" if v[0] == 0 else "partial")
                cells.append(f"{mark} {v[0]}/{v[1]}" + (f" (+{v[2]} FP)" if v[2] else ""))
        sid = key.split("/")[0]
        print(f"| {key} {titles.get(sid, '')} | " + " | ".join(cells) + " |")

    # Late writers and escapes.
    print("\n## Late writes, escapes, git ops\n")
    for (plat, prov, drv), rs in groups.items():
        notes = []
        for r in rs:
            if r["phase"] == "late" and r.get("truth"):
                caught = [
                    n
                    for n, rr in (r.get("recorders") or {}).items()
                    if rr["all"]["TP"] == len(r["truth"])
                ]
                notes.append(
                    f"{r['scenario']} r{r['rep']}: late {sorted(r['truth'])[:2]} caught by {sorted(caught)}"
                )
            if r.get("escapes"):
                notes.append(f"{r['scenario']} r{r['rep']}: escapes {r['escapes']}")
            if r["phase"] == "error" or (r.get("error") and r["phase"] == "turn"):
                notes.append(f"{r['scenario']} r{r['rep']}: error {str(r.get('error'))[:140]}")
        late_turn = [r for r in rs if r["scenario"] in ("S20",) and r["phase"] == "turn"]
        for r in late_turn:
            t = r.get("truth") or {}
            if "late.txt" in t:
                notes.append(
                    f"S20 r{r['rep']}: late.txt landed INSIDE the turn (harness waited for the background job)"
                )
        print(f"- **{plat}/{prov}/{drv}**: " + ("; ".join(notes) if notes else "none"))

    # Shadow misses in git scope.
    print("\n## Git-scope misses of the shadow snapshot\n")
    for (plat, prov, drv), rs in groups.items():
        misses = defaultdict(set)
        for r in rs:
            sh = (r.get("recorders") or {}).get("shadow")
            if sh:
                for p in sh["git"].get("Missed") or []:
                    misses[r["scenario"]].add(p)
                for p in sh["git"].get("Extra") or []:
                    misses[r["scenario"] + " (extra)"].add(p)
        if misses:
            print(
                f"- **{plat}/{prov}/{drv}**: "
                + "; ".join(f"{k}: {sorted(v)[:3]}" for k, v in sorted(misses.items()))
            )
        else:
            print(f"- **{plat}/{prov}/{drv}**: none")

    # View creation.
    print("\n## View creation inside scenario runs (small fixture)\n")
    print("| platform | provider | driver | create p50 ms | p95 ms |")
    print("| --- | --- | --- | --- | --- |")
    for (plat, prov, drv), rs in groups.items():
        c = [r["view"]["create"] for r in rs if r["phase"] == "turn" and r["turn"] == 1]
        print(f"| {plat} | {prov} | {drv} | {ms(pct(c, 0.5))} | {ms(pct(c, 0.95))} |")


if __name__ == "__main__":
    main()
