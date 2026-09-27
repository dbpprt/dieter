#!/usr/bin/env python3
"""Own the packaged Mac app lifecycle without replacing a running bundle."""

import argparse
from dataclasses import dataclass
from pathlib import Path
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent.parent
BUNDLE = ROOT / "apps/mac/build/Dieter.app"
EXECUTABLE = BUNDLE / "Contents/MacOS/DieterMac"


@dataclass(frozen=True)
class AppProcess:
    pid: int
    executable: Path


def app_processes():
    result = subprocess.run(["pgrep", "-x", "DieterMac"], capture_output=True, text=True)
    if result.returncode == 1:
        return []
    if result.returncode != 0:
        raise RuntimeError("Could not inventory DieterMac processes: " + result.stderr.strip())
    processes = []
    for value in result.stdout.split():
        pid = int(value)
        # On macOS comm is the executable path, without argv. Do not prefix
        # match command: a sibling bundle or a path containing spaces can match.
        command = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True)
        if command.returncode == 1 and not command.stdout.strip():
            continue  # The inventoried process exited before ps.
        path = Path(command.stdout.strip())
        if command.returncode != 0 or not path.is_absolute():
            raise RuntimeError(f"Could not identify DieterMac PID {pid}; preserving the process.")
        processes.append(AppProcess(pid, path.resolve()))
    if not result.stdout.strip():
        raise RuntimeError("DieterMac process inventory returned no identities.")
    return processes


def describe(processes):
    return ", ".join(f"{process.pid} ({process.executable})" for process in processes)


def assert_stopped():
    processes = app_processes()
    if processes:
        raise RuntimeError("DieterMac is running: " + describe(processes)
                           + ". Quit the app before building; its bundle was not changed.")


def owned_processes():
    processes = app_processes()
    if any(process.executable != EXECUTABLE.resolve() for process in processes):
        raise RuntimeError("Another DieterMac bundle is running: " + describe(processes)
                           + ". Preserving every app process.")
    return processes


def wait_for_count(count):
    deadline = time.monotonic() + 10
    while True:
        processes = owned_processes()
        if len(processes) == count:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError(f"Expected {count} packaged DieterMac process(es); found "
                               + describe(processes) + ". Preserving processes for diagnosis.")
        time.sleep(0.25)


def run_app():
    processes = owned_processes()
    if len(processes) > 1:
        raise RuntimeError("Multiple packaged DieterMac processes are running: " + describe(processes))
    if not processes:
        subprocess.run(["just", "mac", "build"], cwd=ROOT, check=True)
        assert_stopped()
    # Activating an existing app must not rebuild, re-sign, or replace it.
    subprocess.run(["open", str(BUNDLE)], check=True)
    wait_for_count(1)
    print(EXECUTABLE)


def quit_app():
    if not owned_processes():
        print("The packaged Dieter app is not running.")
        return
    subprocess.run([
        "osascript", "-e", "on run argv\ntell application (item 1 of argv) to quit\nend run", str(BUNDLE),
    ], check=True)
    wait_for_count(0)
    print("Dieter exited cleanly.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("assert-stopped", "run", "quit"))
    args = parser.parse_args()
    try:
        {"assert-stopped": assert_stopped, "run": run_app, "quit": quit_app}[args.action]()
    except (RuntimeError, ValueError, OSError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
