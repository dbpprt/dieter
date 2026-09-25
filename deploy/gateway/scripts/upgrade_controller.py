#!/usr/bin/env python3
"""Upgrade deployment controls from a verified bundle without activating services."""
import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile
from bundle import ARCHIVE, MANIFEST, SIGNATURE, extract, verify
from common import atomic, canonical, pointer, read_json, require
from host import Host, TERMINAL, now


def upgrade(distribution, policy):
    distribution = Path(distribution).resolve()
    manifest = verify(distribution)
    host = Host(policy)
    host.initialize()
    with host.lock():
        require(all(read_json(path)["state"] in TERMINAL for path in host.ops.glob("*/status.json")),
                "deployment operations are still pending")
        link = Path(host.config["controllerLink"])
        require(link.is_absolute() and link.is_symlink(), "existing controller link is required")
        previous = link.resolve(strict=True)
        parent = link.with_name(link.name + "-releases")
        parent.mkdir(mode=0o755, exist_ok=True)
        target = parent / manifest["bundle"]["sha256"]
        receipt_path = host.state / "controller-upgrades" / (target.name + ".json")
        if previous == target:
            return read_json(receipt_path)
        require(not target.exists(), "controller target already exists; inspect the previous upgrade")
        with tempfile.TemporaryDirectory(prefix=".controller-", dir=parent) as temporary:
            staged = Path(temporary) / "bundle"
            extract(distribution / ARCHIVE, staged)
            for name in (ARCHIVE, MANIFEST, SIGNATURE):
                shutil.copyfile(distribution / name, staged / name)
            os.rename(staged, target)
        receipt = {"previousController": str(previous), "controller": str(target),
                   "sourceRevision": manifest["sourceRevision"], "upgradedAt": now(),
                   "serviceActivation": False}
        atomic(receipt_path, canonical(receipt))
        pointer(link, target)
        return receipt


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("distribution")
    parser.add_argument("--policy", default="/etc/dieter-deploy/host-policy.json")
    args = parser.parse_args()
    require(os.geteuid() == 0, "controller upgrade requires independent administrative access")
    print(json.dumps(upgrade(args.distribution, args.policy)))
