#!/usr/bin/env python3
"""Exec a device harness under the shared host Android flock protocol."""
import fcntl
import hashlib
import json
import os
import pathlib
import sys
import time


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: with-android-device-lease.py SERIAL COMMAND [ARGS...]")
    serial = sys.argv[1]
    root = pathlib.Path("/tmp") / f"android-device-leases-{os.getuid()}"
    root.mkdir(mode=0o700, exist_ok=True)
    path = root / (hashlib.sha256(serial.encode()).hexdigest() + ".lock")
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit(f"Device {serial} is leased by another process ({path}); no test started")
    # Never unlink: another owner may already be waiting on this inode.
    os.ftruncate(fd, 0)
    os.write(fd, json.dumps(dict(pid=os.getpid(), serial=serial, owner="dieter-screens-test", started_at=time.time())).encode())
    os.set_inheritable(fd, True)
    os.environ["DIETER_SCREEN_DEVICE_LEASE_V2"] = serial
    os.execvp(sys.argv[2], sys.argv[2:])


if __name__ == "__main__":
    main()
