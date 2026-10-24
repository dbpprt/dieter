#!/usr/bin/env python3
"""Summarize E1 (view cost) and E6 (snapshot cost) JSONL: costs.py e1.jsonl snapcost.jsonl"""

import json
import sys
from collections import defaultdict


def med(v):
    s = sorted(v)
    return s[len(s) // 2] if s else None


def load(p):
    try:
        return [json.loads(l) for l in open(p)]
    except FileNotFoundError:
        return []


e1, snap = load(sys.argv[1]), load(sys.argv[2])
print("## E1 view cost (median of runs, ms)\n")
print(
    "| platform | fixture | provider | create | first git status | second status | discard | free-space delta MB |"
)
print("| --- | --- | --- | --- | --- | --- | --- | --- |")
g = defaultdict(list)
for r in e1:
    if "error" in r:
        print(
            f"| {r.get('platform', '')} | {r['fixture']} | {r['provider']} | error: {r['error'][:80]} | | | | |"
        )
        continue
    g[(r["platform"], r["fixture"], r["provider"])].append(r)
order = {"small": 0, "js": 1, "huge": 2}
for k in sorted(g, key=lambda k: (k[0], order.get(k[1], 9), k[2])):
    rs = g[k]
    f = lambda n: med([float(x[n]) for x in rs])
    print(
        f"| {k[0]} | {k[1]} | {k[2]} | {f('createMs'):.0f} | {f('status1Ms'):.0f} | {f('status2Ms'):.0f} | {f('discardMs'):.0f} | {f('freeDeltaMB'):.1f} |"
    )
print("\n## E6 recorder cost per mark (median ms) by modified tracked files\n")
s = defaultdict(list)
for r in snap:
    if r.get("mods") == "baseline":
        continue
    s[(r["platform"], r["fixture"], r["provider"], r["recorder"], r["mods"])].append(float(r["ms"]))
mods = sorted({k[4] for k in s})
print(
    "| platform | fixture | provider | recorder | " + " | ".join(f"{m} files" for m in mods) + " |"
)
print("| --- | --- | --- | --- | " + " | ".join("---" for _ in mods) + " |")
rows = sorted({k[:4] for k in s}, key=lambda k: (k[0], order.get(k[1], 9), k[2], k[3]))
for k in rows:
    cells = []
    for m in mods:
        v = med(s.get(k + (m,), []))
        cells.append("–" if v is None else f"{v:.0f}")
    print(f"| {k[0]} | {k[1]} | {k[2]} | {k[3]} | " + " | ".join(cells) + " |")
