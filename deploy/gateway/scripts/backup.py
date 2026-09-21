#!/usr/bin/env python3
"""Push an encrypted snapshot to an authenticated off-host restic repository."""
import argparse
import json
import os
from pathlib import Path
from common import read_json, require, run


def command(config_root, *arguments):
    config_root = Path(config_root)
    cfg = read_json(config_root / "backup/config.json")
    require(cfg["repository"].startswith(("rest:http://127.0.0.1:", "rest:https://", "sftp:", "s3:", "b2:", "azure:")), "backup repository must be off-host")
    # Loopback REST is permitted only for the pinned SSH reverse tunnel. The
    # off-host server is append-only; pruning runs on the backup machine.
    require(cfg.get("offHost") is True, "off-host backup has not been configured")
    return ["docker", "run", "--rm", "--network", "host", "--read-only", "--cap-drop", "ALL",
            "--security-opt", "no-new-privileges:true", "--memory", "192m", "--cpus", "0.4", "--pids-limit", "64",
            "--env-file", str(config_root / "backup/environment"), "-e", "RESTIC_REPOSITORY=" + cfg["repository"], "-e", "RESTIC_PASSWORD_FILE=/credentials/password",
            # Default 16 MiB packs and five concurrent REST uploads can exhaust
            # a small tmpfs even when the source and repository have free space.
            "-e", "RESTIC_PACK_SIZE=4", "-e", "GOMEMLIMIT=128MiB",
            "-v", str(config_root / "backup") + ":/credentials:ro", "--tmpfs", "/tmp:size=64m",
            *arguments]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--config-root", default="/etc/dbpprt-vpc")
    p.add_argument("snapshot", help="Protected, consistent snapshot directory prepared by host.py")
    a = p.parse_args()
    snapshot = Path(a.snapshot).resolve()
    require((snapshot / "metadata.json").is_file() and (snapshot / "gateway/gateway.db").is_file(), "incomplete backup snapshot")
    cfg = read_json(Path(a.config_root) / "backup/config.json")
    dep = cfg["image"]
    require(dep.startswith("restic/restic@sha256:") and len(dep.rsplit(":", 1)[1]) == 64, "restic image must be pinned")
    output = run(command(a.config_root, "-v", str(snapshot) + ":/snapshot:ro", dep,
                        "--no-cache", "-o", "rest.connections=2", "backup", "/snapshot", "--read-concurrency", "2",
                        "--host", cfg["host"], "--tag", "gateway", "--json"), timeout=900)
    reports = [json.loads(line) for line in output.splitlines()]
    summary = next((r for r in reports if r.get("message_type") == "summary"), None)
    require(summary and summary.get("snapshot_id"), "backup did not produce a durable snapshot")
    print(json.dumps({"snapshotID": summary["snapshot_id"], "offHost": True}))


if __name__ == "__main__":
    main()
