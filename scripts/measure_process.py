#!/usr/bin/env python3
"""Measure exact process CPU time and RSS without changing any process or service.

Run separately from builds for an idle baseline, then repeat the same duration
while navigating/streaming. CPU is normalized to one core (100% = one busy core).
This measures the supplied PIDs, not their children or physical display latency.
"""

import argparse
import json
import math
from pathlib import Path
import statistics
import subprocess
import time


def cpu_seconds(value):
    days, clock = value.split("-", 1) if "-" in value else ("0", value)
    parts = [float(part) for part in clock.split(":")]
    if len(parts) not in (2, 3):
        raise ValueError(f"Unrecognized ps CPU time: {value}")
    return int(days) * 86400 + sum(part * 60 ** power for power, part in enumerate(reversed(parts)))


def observe(pid):
    # Do not record argv: it can contain user text or credentials.
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "lstart=,time=,rss=,comm="],
        text=True, capture_output=True, check=False, timeout=5,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise RuntimeError(f"PID {pid} is no longer available")
    fields = result.stdout.strip().split(maxsplit=7)
    if len(fields) != 8:
        raise ValueError(f"Unexpected ps field count for PID {pid}")
    return {
        "identity": " ".join(fields[:5]) + " " + fields[7],
        "cpu_seconds": cpu_seconds(fields[5]),
        "rss_kib": int(fields[6]),
        "monotonic": time.monotonic(),
    }


def measure(pids, duration, interval):
    started = time.monotonic()
    samples = {pid: [observe(pid)] for pid in pids}
    deadline = started + duration
    while time.monotonic() < deadline:
        time.sleep(max(0, min(interval, deadline - time.monotonic())))
        for pid in pids:
            current = observe(pid)
            if current["identity"] != samples[pid][0]["identity"]:
                raise RuntimeError(f"PID {pid} was replaced during measurement")
            samples[pid].append(current)
    result = []
    for pid, values in samples.items():
        elapsed = values[-1]["monotonic"] - values[0]["monotonic"]
        cpu = values[-1]["cpu_seconds"] - values[0]["cpu_seconds"]
        rss = [sample["rss_kib"] for sample in values]
        result.append({
            "pid": pid, "identity": values[0]["identity"],
            "elapsed_seconds": elapsed, "cpu_seconds": cpu,
            "cpu_percent_one_core": 100 * cpu / elapsed,
            "rss_median_mib": statistics.median(rss) / 1024,
            "rss_max_mib": max(rss) / 1024,
            "samples": [{**sample, "monotonic": sample["monotonic"] - started} for sample in values],
        })
    return {"processes": result, "sample_interval_seconds": interval}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, action="append", required=True, help="Exact PID; repeat for app and daemon.")
    parser.add_argument("--duration", type=float, default=30, help="Seconds, 5–300 (default: 30).")
    parser.add_argument("--interval", type=float, default=1, help="Seconds, 0.1–10 (default: 1).")
    parser.add_argument("--label", required=True, help="Workload, build configuration and activity during capture.")
    parser.add_argument("--output", type=Path, required=True, help="New JSON evidence file; existing files are refused.")
    args = parser.parse_args()
    if any(pid <= 0 for pid in args.pid) or not math.isfinite(args.duration) or not 5 <= args.duration <= 300:
        parser.error("Use positive PIDs and a duration between 5 and 300 seconds")
    if not math.isfinite(args.interval) or not 0.1 <= args.interval <= 10:
        parser.error("Interval must be between 0.1 and 10 seconds")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Reserve the output before measuring; never overwrite prior evidence.
    with args.output.open("x") as output:
        report = measure(list(dict.fromkeys(args.pid)), args.duration, args.interval)
        report["label"] = args.label
        json.dump(report, output, indent=2)
        output.write("\n")
    for process in report["processes"]:
        print(f"PID {process['pid']}: {process['cpu_percent_one_core']:.2f}% of one CPU core, "
              f"RSS median/max {process['rss_median_mib']:.1f}/{process['rss_max_mib']:.1f} MiB "
              f"over {process['elapsed_seconds']:.1f}s")
    print(args.output)


if __name__ == "__main__":
    main()
