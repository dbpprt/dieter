#!/usr/bin/env python3
"""Start a restored gateway with no external network and verify its identity."""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import sqlite3
import tempfile
import time
from common import digest, read_json, require, run
from host import Host


def test_restore(snapshot, policy):
    host = Host(policy)
    snapshot = Path(snapshot).resolve()
    require((snapshot / "gateway/gateway.db").is_file(), "restore snapshot is incomplete")
    metadata = read_json(snapshot / "metadata.json")
    gateway_ca = snapshot / "gateway/signing/daemon-ca.pem"
    require(digest(gateway_ca) == metadata["gatewayCAFingerprint"], "restored gateway CA differs from snapshot metadata")
    for name in ("gateway-ed25519.pem", "daemon-ca-ed25519.pem"):
        require((gateway_ca.parent / name).is_file(), "restored private identity is missing")
    with sqlite3.connect("file:" + str(snapshot / "gateway/gateway.db") + "?mode=ro", uri=True) as database:
        require(database.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "restored database is corrupt")
        require(database.execute("PRAGMA user_version").fetchone()[0] == 1, "restored schema is incompatible")
    compose = read_json(snapshot / "release/public/compose.json")
    service = compose["services"]["dieter-gateway"]
    image = next(item["imageID"] for item in read_json(snapshot / "images.json") if item["reference"] == service["image"])
    require(re.fullmatch(r"sha256:[a-f0-9]{64}", image), "invalid archived image identity")
    stored_policy = read_json(snapshot / "host-policy.json")
    relative_env = Path(service["env_file"][0]["path"]).relative_to(stored_policy["configRoot"])
    environment = snapshot / "configuration" / relative_env
    require(environment.is_file() and environment.resolve().is_relative_to(snapshot), "restored environment is missing or escapes snapshot")
    started = time.monotonic()
    # Loading by immutable image ID makes this independent of lost registry tags
    # and RepoDigests (which docker load does not necessarily reconstruct).
    run(["docker", "image", "load", "--input", snapshot / "images.tar"], timeout=300)
    run(["docker", "image", "inspect", image])
    with host.lock(), tempfile.TemporaryDirectory(prefix="restore-test-", dir=host.state) as temporary:
        store = Path(temporary) / "gateway"
        shutil.copytree(snapshot / "gateway", store)
        for path in [store, *store.rglob("*")]:
            require(not path.is_symlink(), "restored store may not contain symlinks")
            os.chown(path, 100, 101)
        name = "dieter-restore-test-" + secrets.token_hex(8)
        try:
            run(["docker", "run", "-d", "--name", name, "--network", "none", "--read-only", "--user", "100:101",
                 "--cap-drop", "ALL", "--security-opt", "no-new-privileges:true", "--memory", "192m", "--cpus", "0.5",
                 "--pids-limit", "64", "--log-opt", "max-size=1m", "--log-opt", "max-file=1",
                 "--env-file", environment, "-v", str(store) + ":/var/lib/dieter-gateway", image])
            for attempt in range(30):
                try:
                    health = json.loads(run(["docker", "exec", name, "wget", "-qO-", "http://127.0.0.1:4243/healthz"], timeout=5))
                    require(str(health.get("apiVersion")) == "1", "restored gateway contract mismatch")
                    break
                except ValueError:
                    time.sleep(0.5)
            else:
                raise ValueError("restored gateway did not become live")
            require(digest(store / "signing/daemon-ca.pem") == metadata["gatewayCAFingerprint"], "restore generated a different identity")
            inspected = json.loads(run(["docker", "inspect", name]))[0]
            require(inspected["HostConfig"]["NetworkMode"] == "none", "restore fixture has external network access")
            return {"restored": True, "schema": 1, "gatewayCAFingerprint": metadata["gatewayCAFingerprint"],
                    "network": "none", "durationSeconds": round(time.monotonic() - started, 2)}
        finally:
            run(["docker", "rm", "-f", name])


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("snapshot")
    p.add_argument("--policy", default="/etc/dieter-deploy/host-policy.json")
    a = p.parse_args()
    print(json.dumps(test_restore(a.snapshot, a.policy)))
