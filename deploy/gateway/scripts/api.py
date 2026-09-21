#!/usr/bin/env python3
"""Fixed JSON protocol for the forced-command deployment SSH identity."""
import base64
import json
import os
import sys
from common import atomic, canonical, keys, require, run
from bundle import ARCHIVE, MANIFEST, SIGNATURE
from host import Host


def handle(host, request):
    command = request.get("command")
    if command == "probe-request":
        keys(request, ("command", "operation", "transport"), "probe")
        require(host.status(request["operation"])["state"] == "checking", "probes require an active deployment")
        transport = request["transport"]
        require(transport in {"udp", "tcp", "tls"}, "invalid probe transport")
        from common import read_json
        from render import secrets
        import hashlib
        import hmac
        import time
        s = read_json(host.operation(request["operation"]) / "input/settings.json")
        require(transport != "tls" or s["tls"] == "managed", "TURN TLS is not enabled")
        private = secrets(host.etc / "secrets.json")
        username = f"{int(time.time()) + 180}:dieter:{s['allowedUserIDs'][0]}:deployment-probe"
        password = base64.b64encode(hmac.new(private["turnSharedSecret"].encode(), username.encode(), hashlib.sha1).digest()).decode()
        return {"address": s["turnIPv4"] + (":443" if transport == "tls" else ":3478"),
                "serverName": s["turnHost"], "transport": transport, "username": username, "password": password,
                "expectedRelayIP": s["turnIPv4"]}
    if command == "admit":
        keys(request, ("command", "operation", "files"), "admission")
        operation = request["operation"]
        host.operation(operation)  # validate before constructing any path
        files = request["files"]
        required = {ARCHIVE, MANIFEST, SIGNATURE, "settings.json"}
        require(required <= set(files) <= required | {"legacy.caddy"}, "invalid admission file set")
        import tempfile
        root = host.state / "incoming"
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        with tempfile.TemporaryDirectory(prefix=operation + "-", dir=root) as temporary:
            from pathlib import Path
            for name, content in files.items():
                data = base64.b64decode(content, validate=True)
                require(len(data) <= 32*1024*1024, "admission file too large")
                atomic(Path(temporary) / name, data)
            return host.admit(operation, temporary)
    if command == "status":
        keys(request, ("command", "operation"), "status")
        return host.status(request["operation"])
    if command == "accept":
        keys(request, ("command", "operation", "report"), "readiness")
        # Root-owned scratch is distinct from the accepted report consumed by the
        # worker, so an invalid submission cannot commit a deployment.
        path = host.operation(request["operation"]) / "submitted-readiness.json"
        atomic(path, canonical(request["report"]))
        return host.accept(request["operation"], path)
    if command == "backup":
        keys(request, ("command",), "backup")
        run(["systemctl", "start", "--no-block", "dieter-backup.service"])
        return {"backupStarted": True}
    raise ValueError("unsupported deployment operation")


def main():
    require(os.geteuid() == 0, "deployment entrypoint requires its fixed sudo rule")
    raw = sys.stdin.buffer.read(48*1024*1024 + 1)
    require(len(raw) <= 48*1024*1024, "deployment request too large")
    request = json.loads(raw)
    print(json.dumps(handle(Host("/etc/dieter-deploy/host-policy.json"), request)))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # The SSH protocol returns no raw tool output, file contents or secrets.
        print(json.dumps({"error": type(error).__name__}), file=sys.stderr)
        sys.exit(1)
